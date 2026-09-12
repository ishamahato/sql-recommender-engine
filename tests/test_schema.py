"""Structural guarantees the rest of the system depends on."""

from __future__ import annotations

import pytest

EXPECTED_TABLES = {
    "users", "categories", "products", "orders", "order_items",
    "user_interactions", "ratings", "interaction_weights",
    "rec_config", "pipeline_state",
}

EXPECTED_MATVIEWS = {
    "mv_user_product_features", "mv_user_category_preferences",
    "mv_product_popularity", "mv_product_trend", "mv_product_similarity",
}


def test_all_tables_exist(conn):
    rows = conn.execute(
        "SELECT tablename FROM pg_tables WHERE schemaname = 'public'"
    ).fetchall()
    assert EXPECTED_TABLES <= {row["tablename"] for row in rows}


def test_all_materialized_views_exist(conn):
    rows = conn.execute(
        "SELECT matviewname FROM pg_matviews WHERE schemaname = 'public'"
    ).fetchall()
    assert EXPECTED_MATVIEWS <= {row["matviewname"] for row in rows}


def test_every_matview_has_a_unique_index(conn):
    """Without one, REFRESH MATERIALIZED VIEW CONCURRENTLY is impossible."""
    for name in sorted(EXPECTED_MATVIEWS):
        row = conn.execute(
            """
            SELECT COUNT(*) AS n
            FROM pg_indexes AS i
            JOIN pg_class   AS c ON c.relname = i.indexname
            JOIN pg_index   AS x ON x.indexrelid = c.oid
            WHERE i.tablename = %s AND x.indisunique
            """,
            (name,),
        ).fetchone()
        assert row["n"] >= 1, f"{name} has no unique index"


def test_pipeline_state_is_a_singleton(conn):
    row = conn.execute("SELECT COUNT(*) AS n FROM pipeline_state").fetchone()
    assert row["n"] == 1
    with pytest.raises(Exception):
        conn.execute("INSERT INTO pipeline_state (as_of_timestamp) VALUES (now())")
    conn.rollback()


def test_order_totals_match_their_line_items(conn):
    """
    The order ledger and the line items are written by the generator and must
    agree, otherwise every revenue query in analytics.sql reports fiction.
    """
    row = conn.execute(
        """
        SELECT COUNT(*) AS mismatches
        FROM orders AS o
        JOIN (
            SELECT order_id, ROUND(SUM(quantity * unit_price), 2) AS line_total
            FROM order_items GROUP BY order_id
        ) AS li ON li.order_id = o.order_id
        WHERE ABS(o.total_amount - li.line_total) > 0.01
        """
    ).fetchone()
    assert row["mismatches"] == 0


def test_every_purchase_interaction_has_an_order_line(conn):
    """The behavioural log and the financial ledger describe the same events."""
    row = conn.execute(
        """
        SELECT COUNT(*) AS orphans
        FROM user_interactions AS i
        WHERE i.interaction_type = 'purchase'
          AND NOT EXISTS (
              SELECT 1
              FROM orders AS o
              JOIN order_items AS oi ON oi.order_id = o.order_id
              WHERE o.user_id = i.user_id AND oi.product_id = i.product_id
          )
        """
    ).fetchone()
    assert row["orphans"] == 0


def test_no_interaction_predates_its_user_signup(conn):
    row = conn.execute(
        """
        SELECT COUNT(*) AS impossible
        FROM user_interactions AS i
        JOIN users AS u ON u.user_id = i.user_id
        WHERE i.interaction_timestamp::DATE < u.signup_date
        """
    ).fetchone()
    assert row["impossible"] == 0


def test_scoring_weights_sum_to_one(conn):
    """
    The blend is documented as a weighted average. If the weights stop summing
    to 1 the scores silently leave the 0 to 1 range and the reason thresholds
    stop meaning what they say.
    """
    row = conn.execute(
        """
        SELECT SUM(config_value) AS total
        FROM rec_config
        WHERE config_key LIKE 'weight_%'
        """
    ).fetchone()
    assert abs(float(row["total"]) - 1.0) < 1e-9
