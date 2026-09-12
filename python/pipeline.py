"""
Pipeline orchestration.

This module is the closest thing the project has to a control plane, and it is
intentionally small. It decides WHEN SQL runs and in WHAT ORDER. It never
decides WHAT the SQL computes.

Two entry points:

    build()    full rebuild from an empty database: schema, load, indexes,
               feature views, materialized views, ranker, evaluation objects.

    refresh()  the operation a scheduler would run every few hours in
               production. Uses REFRESH MATERIALIZED VIEW CONCURRENTLY in
               autocommit mode, outside any transaction, so serving traffic
               keeps reading the previous snapshot while the next one builds.
               CONCURRENTLY is impossible inside a function body, which is why
               this lives in Python rather than in refresh_recommendation_layer().
"""

from __future__ import annotations

import time

from python import load_data
from python.config import SQL_DIR
from python.db import connect, run_sql_file, table_counts

# Dependency order. Each file assumes everything above it already exists.
DDL_STEPS: list[tuple[str, str]] = [
    ("schema.sql", "base tables and accessors"),
    ("indexes.sql", "indexes and statistics"),
    ("views.sql", "feature layer"),
    ("materialized_views.sql", "materialized layer and similarity"),
    ("recommendations.sql", "ranker and product to product"),
    ("evaluation.sql", "evaluation harness and baselines"),
]

# Refresh order mirrors the dependency graph: features feed everything else.
REFRESH_ORDER = [
    "mv_user_product_features",
    "mv_user_category_preferences",
    "mv_product_popularity",
    "mv_product_trend",
    "mv_product_similarity",
]

REPORT_TABLES = [
    "users", "categories", "products", "orders", "order_items",
    "user_interactions", "ratings",
]


def build() -> None:
    """Full rebuild. Destroys and recreates every object."""
    started = time.perf_counter()

    print("1. Schema")
    run_sql_file(SQL_DIR / "schema.sql", "schema.sql")

    print("2. Load")
    load_data.main()

    print("3. Derived objects")
    for filename, label in DDL_STEPS[1:]:
        run_sql_file(SQL_DIR / filename, f"{filename} ({label})")

    print("4. Row counts")
    for table, count in table_counts(REPORT_TABLES).items():
        print(f"  {table:<20} {count:>10,}")

    with connect() as conn:
        with conn.cursor() as cur:
            for view in REFRESH_ORDER:
                cur.execute(f"SELECT COUNT(*) AS n FROM {view}")
                print(f"  {view:<32} {cur.fetchone()['n']:>10,}")

    print(f"Build complete in {time.perf_counter() - started:.1f}s")


def refresh() -> None:
    """
    Non blocking refresh of the offline layer.

    Autocommit is required: PostgreSQL rejects REFRESH MATERIALIZED VIEW
    CONCURRENTLY inside a transaction block.
    """
    started = time.perf_counter()
    print("Refreshing recommendation layer")

    with connect(autocommit=True) as conn:
        for view in REFRESH_ORDER:
            step = time.perf_counter()
            conn.execute(f"REFRESH MATERIALIZED VIEW CONCURRENTLY {view}")
            conn.execute(f"ANALYZE {view}")
            print(f"  {view:<32} {time.perf_counter() - step:7.2f}s")
        conn.execute("UPDATE pipeline_state SET last_refreshed_at = clock_timestamp()")

    print(f"Refresh complete in {time.perf_counter() - started:.1f}s")


if __name__ == "__main__":
    build()
