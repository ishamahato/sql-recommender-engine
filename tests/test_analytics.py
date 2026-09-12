"""
Every query in sql/analytics.sql is executed.

A query library that nobody runs rots quietly: a column gets renamed, a view
changes shape, and the file still looks fine in a diff. Running all of them on
every test pass is the cheapest possible guard against that.

The queries are read from the file and split on statement terminators, so
adding a query to analytics.sql automatically adds a test.
"""

from __future__ import annotations

import re

import pytest

from python.config import SQL_DIR

COMMENT_BLOCK = re.compile(r"/\*.*?\*/", re.DOTALL)
QUERY_TITLE = re.compile(r"QUERY (\d+) \| (.+)")


def load_queries() -> list[tuple[str, str]]:
    text = (SQL_DIR / "analytics.sql").read_text(encoding="utf-8")

    titles = QUERY_TITLE.findall(text)
    statements = [
        stripped
        for chunk in COMMENT_BLOCK.sub("", text).split(";")
        if (stripped := chunk.strip())
    ]

    labels = [f"{number} {title.strip()}" for number, title in titles]
    while len(labels) < len(statements):
        labels.append(f"statement {len(labels) + 1}")

    return list(zip(labels, statements))


QUERIES = load_queries()


def test_every_query_was_discovered():
    assert len(QUERIES) >= 25, f"only found {len(QUERIES)} analytical queries"


@pytest.mark.parametrize("label,sql", QUERIES, ids=[label for label, _ in QUERIES])
def test_query_runs(conn, label, sql):
    rows = conn.execute(sql).fetchall()
    assert isinstance(rows, list)
