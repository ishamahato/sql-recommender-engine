"""
Bulk load the generated CSVs into PostgreSQL.

Uses COPY, not INSERT. A million row INSERT loop spends its time on round trips
and per statement parsing; COPY streams the file into the server in one
operation and is roughly two orders of magnitude faster. This is one of the
places where the right answer is to let the database do the work.

Load order follows the foreign keys. Indexes are deliberately NOT in place
during the load: they are created afterwards by indexes.sql, because building
an index once over a finished table beats maintaining it across a million
inserts.

The last step sets the pipeline cutoff to just past the newest interaction,
which puts the system in production mode with the full history visible.
"""

from __future__ import annotations

import time
from pathlib import Path

from python.config import DATA_DIR
from python.db import connect

LOAD_ORDER: list[tuple[str, str, list[str]]] = [
    ("categories", "categories.csv", ["category_id", "category_name"]),
    ("users", "users.csv",
     ["user_id", "age", "gender", "city", "signup_date", "persona"]),
    ("products", "products.csv",
     ["product_id", "category_id", "subcategory", "brand", "name",
      "description", "price", "rating", "is_active", "created_at"]),
    ("orders", "orders.csv", ["order_id", "user_id", "order_date", "total_amount"]),
    ("order_items", "order_items.csv",
     ["order_item_id", "order_id", "product_id", "quantity", "unit_price"]),
    ("user_interactions", "user_interactions.csv",
     ["interaction_id", "user_id", "product_id", "interaction_type",
      "interaction_timestamp"]),
    ("ratings", "ratings.csv",
     ["rating_id", "user_id", "product_id", "rating", "created_at"]),
]

CHUNK_BYTES = 1 << 20


def copy_table(conn, table: str, path: Path, columns: list[str]) -> int:
    column_list = ", ".join(columns)
    statement = (
        f"COPY {table} ({column_list}) FROM STDIN WITH (FORMAT csv, HEADER true)"
    )
    with conn.cursor() as cur:
        with cur.copy(statement) as copy:
            with open(path, "rb") as handle:
                while chunk := handle.read(CHUNK_BYTES):
                    copy.write(chunk)
        cur.execute(f"SELECT COUNT(*) AS n FROM {table}")
        row = cur.fetchone()
        return int(row["n"])


def main() -> None:
    missing = [name for _, name, _ in LOAD_ORDER if not (DATA_DIR / name).exists()]
    if missing:
        raise SystemExit(
            "Missing generated files: "
            + ", ".join(missing)
            + "\nRun: python -m python.generate_data"
        )

    started = time.perf_counter()
    print("Loading CSVs into PostgreSQL")

    with connect() as conn:
        # The tables were just recreated by schema.sql, but truncating makes the
        # loader safe to rerun on its own.
        with conn.cursor() as cur:
            cur.execute(
                "TRUNCATE ratings, user_interactions, order_items, orders, "
                "products, categories, users RESTART IDENTITY CASCADE"
            )

        for table, filename, columns in LOAD_ORDER:
            step = time.perf_counter()
            rows = copy_table(conn, table, DATA_DIR / filename, columns)
            print(f"  {table:<20} {rows:>10,} rows  {time.perf_counter() - step:6.2f}s")

        # Production mode: the cutoff sits just past the newest event, so the
        # whole history is visible to the pipeline.
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE pipeline_state
                   SET as_of_timestamp = (
                           SELECT MAX(interaction_timestamp) + INTERVAL '1 second'
                           FROM user_interactions
                       ),
                       mode = 'production'
                RETURNING as_of_timestamp
                """
            )
            cutoff = cur.fetchone()["as_of_timestamp"]

    print(f"  pipeline cutoff set to {cutoff}")
    print(f"Done in {time.perf_counter() - started:.1f}s")


if __name__ == "__main__":
    main()
