"""
Thin PostgreSQL access helpers.

Deliberately thin. There is no ORM and no query builder, because every query
that matters in this project lives in the sql/ directory where an interviewer
can read it. Python's job is to open a connection, hand SQL to the server and
collect rows.
"""

from __future__ import annotations

import time
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from pathlib import Path
from typing import Any

import psycopg
from psycopg.rows import dict_row

from python.config import DB


@contextmanager
def connect(autocommit: bool = False) -> Iterator[psycopg.Connection]:
    """Open a connection with dict rows. Commits on clean exit."""
    conn = psycopg.connect(DB.dsn, autocommit=autocommit, row_factory=dict_row)
    try:
        yield conn
        if not autocommit:
            conn.commit()
    except Exception:
        if not autocommit:
            conn.rollback()
        raise
    finally:
        conn.close()


def fetch_all(sql: str, params: Sequence[Any] | None = None) -> list[dict[str, Any]]:
    with connect() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchall()


def fetch_one(sql: str, params: Sequence[Any] | None = None) -> dict[str, Any] | None:
    with connect() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchone()


def execute(sql: str, params: Sequence[Any] | None = None) -> None:
    with connect() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)


def run_sql_file(path: Path, label: str | None = None) -> float:
    """
    Execute a .sql file as a single script and return the elapsed seconds.

    psycopg sends the whole file in one round trip, which keeps the transaction
    semantics written into the file (its own BEGIN and COMMIT) intact instead of
    letting a naive statement splitter break them apart.
    """
    sql = path.read_text(encoding="utf-8")
    started = time.perf_counter()
    with connect(autocommit=True) as conn:
        conn.execute(sql)
    elapsed = time.perf_counter() - started
    print(f"  {label or path.name:<32} {elapsed:7.2f}s")
    return elapsed


def table_counts(tables: Sequence[str]) -> dict[str, int]:
    counts: dict[str, int] = {}
    with connect() as conn:
        with conn.cursor() as cur:
            for table in tables:
                cur.execute(f"SELECT COUNT(*) AS n FROM {table}")
                row = cur.fetchone()
                counts[table] = int(row["n"]) if row else 0
    return counts
