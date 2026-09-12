"""
FastAPI service over the SQL recommendation engine.

ARCHITECTURAL RULE, AND IT IS THE POINT OF THIS FILE

    FastAPI -> PostgreSQL function -> SQL pipeline -> PostgreSQL

No endpoint below scores, ranks, filters, sorts or merges anything. Each one
calls a single PostgreSQL function and serialises the rows it gets back. If you
find yourself wanting to sort a list here, the sort belongs in the SQL.

That constraint is worth defending. The moment ranking logic starts leaking into
the service layer, the dashboard, the batch jobs and the API each grow their own
slightly different version of it, and the database stops being the source of
truth for what a good recommendation is. Keeping the boundary sharp means the
evaluation harness measures exactly what the API serves.

Connections come from a pool opened at startup. A recommendation request is a
few milliseconds of query time, so paying for a TCP handshake and authentication
per request would dominate the response.

Run with:  python -m api.main
"""

from __future__ import annotations

import json
import os
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, HTTPException, Query
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool
from pydantic import BaseModel, Field

from python.config import DATA_DIR, DB

pool: ConnectionPool | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global pool
    pool = ConnectionPool(
        DB.dsn,
        min_size=2,
        max_size=10,
        kwargs={"row_factory": dict_row},
        open=True,
    )
    try:
        yield
    finally:
        pool.close()


app = FastAPI(
    title="SQL Recommendation Engine",
    version="1.0.0",
    summary="Recommendations computed entirely in PostgreSQL",
    description=(
        "Every endpoint is a thin wrapper over a PostgreSQL function. Candidate "
        "generation, similarity, filtering, scoring and ranking all happen in "
        "SQL; this service adds HTTP and nothing else."
    ),
    lifespan=lifespan,
)


def query(sql: str, params: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
    if pool is None:
        raise HTTPException(status_code=503, detail="Connection pool is not ready")
    with pool.connection() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchall()


# ===========================================================================
# Response models
# ===========================================================================

class Health(BaseModel):
    status: str
    database: str
    pipeline_mode: str
    pipeline_as_of: str
    last_refreshed_at: str | None
    similarity_pairs: int
    products: int


class Recommendation(BaseModel):
    product_id: int
    product_name: str
    category: str
    price: float
    recommendation_score: float
    recommendation_reason: str
    strategy: str
    recommendation_rank: int


class RecommendationResponse(BaseModel):
    user_id: int
    user_tier: str = Field(description="cold, light or warm, decided in SQL")
    count: int
    recommendations: list[Recommendation]


class SimilarProduct(BaseModel):
    product_id: int
    product_name: str
    category: str
    brand: str
    price: float
    similarity_score: float
    common_users: int
    similarity_basis: str
    relationship: str


class SimilarProductsResponse(BaseModel):
    source_product_id: int
    source_product_name: str
    count: int
    similar_products: list[SimilarProduct]


class SearchResult(BaseModel):
    product_id: int
    product_name: str
    category: str
    brand: str
    price: float
    blended_score: float


class TrendingProduct(BaseModel):
    product_id: int
    product_name: str
    category: str
    price: float
    trending_score: float
    trend_direction: str


# ===========================================================================
# Endpoints
# ===========================================================================

@app.get("/health", response_model=Health, tags=["operations"])
def health() -> Health:
    """
    Liveness plus the two facts that actually matter operationally: which cutoff
    the pipeline is serving from, and whether the offline layer has been built.
    A recommender with an empty similarity matrix answers every request
    successfully and uselessly, so the matrix size is part of the health check.
    """
    row = query(
        """
        SELECT
            current_database()                              AS database,
            ps.mode                                         AS pipeline_mode,
            ps.as_of_timestamp::TEXT                        AS pipeline_as_of,
            ps.last_refreshed_at::TEXT                      AS last_refreshed_at,
            (SELECT COUNT(*) FROM mv_product_similarity)    AS similarity_pairs,
            (SELECT COUNT(*) FROM products WHERE is_active) AS products
        FROM pipeline_state AS ps
        """
    )[0]
    return Health(status="ok", **row)


@app.get(
    "/recommendations/{user_id}",
    response_model=RecommendationResponse,
    tags=["recommendations"],
)
def recommendations(
    user_id: int,
    limit: int = Query(default=10, ge=1, le=100),
) -> RecommendationResponse:
    """
    Personalised recommendations.

    One call to `get_recommendations(user_id, limit)`. The function handles cold
    start, the already purchased exclusion, the live catalogue filter, the five
    signal blend, ranking and the explanation. This endpoint reshapes rows.

    An unknown user id is not an error: the function falls back to trending,
    which is the correct product behaviour for an anonymous visitor.
    """
    tier_rows = query(
        "SELECT user_tier FROM user_recommendation_profile WHERE user_id = %s",
        (user_id,),
    )
    rows = query(
        """
        SELECT product_id, product_name, category, price, recommendation_score,
               recommendation_reason, strategy, recommendation_rank
        FROM get_recommendations(%s, %s)
        """,
        (user_id, limit),
    )
    return RecommendationResponse(
        user_id=user_id,
        user_tier=tier_rows[0]["user_tier"] if tier_rows else "unknown",
        count=len(rows),
        recommendations=[Recommendation(**row) for row in rows],
    )


@app.get(
    "/products/{product_id}/similar",
    response_model=SimilarProductsResponse,
    tags=["recommendations"],
)
def similar_products(
    product_id: int,
    limit: int = Query(default=10, ge=1, le=100),
) -> SimilarProductsResponse:
    """
    Product to product recommendations from the SQL similarity matrix, with a
    full text content fallback for products that have no behavioural history.
    """
    source = query("SELECT name FROM products WHERE product_id = %s", (product_id,))
    if not source:
        raise HTTPException(status_code=404, detail=f"No product {product_id}")

    rows = query(
        """
        SELECT product_id, product_name, category, brand, price,
               similarity_score, common_users, similarity_basis, relationship
        FROM get_similar_products(%s, %s)
        """,
        (product_id, limit),
    )
    return SimilarProductsResponse(
        source_product_id=product_id,
        source_product_name=source[0]["name"],
        count=len(rows),
        similar_products=[SimilarProduct(**row) for row in rows],
    )


@app.get("/products/search", response_model=list[SearchResult], tags=["catalogue"])
def search(
    q: str = Query(min_length=2, description="Free text query"),
    limit: int = Query(default=20, ge=1, le=100),
) -> list[SearchResult]:
    """Full text catalogue search, relevance blended with demand in SQL."""
    rows = query(
        """
        SELECT product_id, product_name, category, brand, price, blended_score
        FROM search_products(%s, %s)
        """,
        (q, limit),
    )
    return [SearchResult(**row) for row in rows]


@app.get("/trending", response_model=list[TrendingProduct], tags=["catalogue"])
def trending(limit: int = Query(default=10, ge=1, le=100)) -> list[TrendingProduct]:
    """What a visitor with no history sees: popularity multiplied by momentum."""
    rows = query(
        """
        SELECT product_id, product_name, category, price,
               trending_score, trend_direction
        FROM get_trending_products(%s)
        """,
        (limit,),
    )
    return [TrendingProduct(**row) for row in rows]


@app.get("/evaluation", tags=["operations"])
def evaluation() -> dict:
    """
    The most recent offline evaluation, as written by python/evaluate.py.

    Served from the file rather than recomputed: a temporal evaluation rewinds
    the pipeline and rebuilds every materialized view, which is a two minute
    batch job and has no business happening inside an HTTP request.
    """
    path = DATA_DIR / "evaluation_results.json"
    if not path.exists():
        raise HTTPException(
            status_code=404,
            detail="No evaluation on disk. Run: python -m python.evaluate",
        )
    return json.loads(path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "api.main:app",
        host=os.getenv("API_HOST", "127.0.0.1"),
        port=int(os.getenv("API_PORT", "8000")),
        reload=os.getenv("API_RELOAD", "false").lower() == "true",
    )
