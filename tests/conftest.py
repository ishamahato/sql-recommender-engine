"""
Shared fixtures.

Every test here runs against a real PostgreSQL instance with the pipeline
built. That is deliberate. The thing under test is SQL, and SQL mocked out is
not SQL: a test double for `mv_product_similarity` would assert that the fake
behaves like the fake. If the database is unreachable or the pipeline has not
been built, the suite skips with a message saying what to run rather than
failing with a connection error.
"""

from __future__ import annotations

import pytest

from python.db import connect


@pytest.fixture(scope="session")
def conn():
    try:
        with connect() as connection:
            yield connection
    except Exception as exc:
        pytest.skip(
            f"PostgreSQL is not reachable ({exc}). "
            "Start it with `docker compose up -d` and build the pipeline with "
            "`python -m python.pipeline`."
        )


@pytest.fixture(scope="session", autouse=True)
def pipeline_is_built(conn):
    row = conn.execute(
        "SELECT COUNT(*) AS n FROM pg_matviews WHERE matviewname = 'mv_product_similarity'"
    ).fetchone()
    if not row or row["n"] == 0:
        pytest.skip("Pipeline not built. Run: python -m python.pipeline")

    row = conn.execute("SELECT COUNT(*) AS n FROM mv_product_similarity").fetchone()
    if row["n"] == 0:
        pytest.skip("Similarity matrix is empty. Run: python -m python.pipeline")


@pytest.fixture(scope="session")
def warm_user(conn) -> int:
    return conn.execute(
        """
        SELECT user_id FROM user_recommendation_profile
        WHERE user_tier = 'warm'
        ORDER BY distinct_products DESC
        LIMIT 1
        """
    ).fetchone()["user_id"]


@pytest.fixture(scope="session")
def cold_user(conn) -> int:
    return conn.execute(
        """
        SELECT user_id FROM user_recommendation_profile
        WHERE user_tier = 'cold'
        ORDER BY user_id
        LIMIT 1
        """
    ).fetchone()["user_id"]


@pytest.fixture(scope="session")
def popular_product(conn) -> int:
    return conn.execute(
        """
        SELECT product_id FROM mv_product_popularity
        WHERE is_active ORDER BY popularity_global_rank LIMIT 1
        """
    ).fetchone()["product_id"]
