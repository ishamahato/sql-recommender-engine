"""
Behavioural contract of the recommendation functions.

These are the assertions a reviewer should care about most: that the ranker
never recommends something already owned, never recommends something withdrawn
from sale, always returns something, and gives genuinely different answers to
genuinely different people.
"""

from __future__ import annotations

import pytest

RECOMMENDATION_SQL = """
    SELECT user_id, product_id, product_name, category, price,
           recommendation_score, recommendation_reason, strategy,
           recommendation_rank
    FROM get_recommendations(%s, %s)
"""


def recommend(conn, user_id: int, limit: int = 10) -> list[dict]:
    return conn.execute(RECOMMENDATION_SQL, (user_id, limit)).fetchall()


def test_returns_the_requested_number(conn, warm_user):
    for limit in (1, 5, 10, 25):
        assert len(recommend(conn, warm_user, limit)) == limit


def test_never_recommends_an_already_purchased_product(conn):
    """
    The single rule that is never negotiable. Checked across many users rather
    than one, because an exclusion bug tends to be user specific.
    """
    users = conn.execute(
        """
        SELECT user_id FROM user_recommendation_profile
        WHERE purchased_products >= 5
        ORDER BY user_id LIMIT 40
        """
    ).fetchall()
    assert users, "no users with purchase history to test against"

    for row in users:
        user_id = row["user_id"]
        leaked = conn.execute(
            """
            WITH recs AS (SELECT product_id FROM get_recommendations(%s, 20)),
            owned AS (
                SELECT oi.product_id
                FROM orders AS o
                JOIN order_items AS oi ON oi.order_id = o.order_id
                WHERE o.user_id = %s AND o.order_date < rec_as_of()
            )
            SELECT COUNT(*) AS n FROM recs JOIN owned USING (product_id)
            """,
            (user_id, user_id),
        ).fetchone()
        assert leaked["n"] == 0, f"user {user_id} was shown a product they own"


def test_never_recommends_an_inactive_product(conn, warm_user):
    row = conn.execute(
        """
        SELECT COUNT(*) AS n
        FROM get_recommendations(%s, 25) AS r
        JOIN products AS p ON p.product_id = r.product_id
        WHERE NOT p.is_active
        """,
        (warm_user,),
    ).fetchone()
    assert row["n"] == 0


def test_no_duplicate_products_in_one_response(conn, warm_user):
    products = [row["product_id"] for row in recommend(conn, warm_user, 25)]
    assert len(products) == len(set(products))


def test_scores_are_normalised_and_ordered(conn, warm_user):
    recs = recommend(conn, warm_user, 20)
    scores = [float(row["recommendation_score"]) for row in recs]
    assert all(0.0 <= score <= 1.0 for score in scores)
    assert scores == sorted(scores, reverse=True)
    assert [row["recommendation_rank"] for row in recs] == list(range(1, len(recs) + 1))


def test_every_recommendation_carries_a_reason(conn, warm_user):
    for row in recommend(conn, warm_user, 20):
        assert row["recommendation_reason"]
        assert len(row["recommendation_reason"]) > 10


def test_different_users_receive_different_recommendations(conn):
    """
    A recommender that returns the same shelf to everyone will pass every test
    above. This is the one that catches it.

    Ten warm users from different generated personas are compared pairwise, and
    the average overlap in their top 10 must be low. An exact zero is not
    required: two gamers legitimately share recommendations, and demanding
    disjoint results would be testing for a worse recommender.
    """
    users = conn.execute(
        """
        SELECT DISTINCT ON (u.persona) prof.user_id, u.persona
        FROM user_recommendation_profile AS prof
        JOIN users AS u ON u.user_id = prof.user_id
        WHERE prof.user_tier = 'warm' AND prof.distinct_products >= 20
        ORDER BY u.persona, prof.distinct_products DESC
        """
    ).fetchall()
    assert len(users) >= 8, "not enough personas represented to compare"

    shelves = {
        row["user_id"]: {r["product_id"] for r in recommend(conn, row["user_id"], 10)}
        for row in users
    }

    overlaps = []
    ids = list(shelves)
    for i, a in enumerate(ids):
        for b in ids[i + 1:]:
            overlaps.append(len(shelves[a] & shelves[b]) / 10)

    average_overlap = sum(overlaps) / len(overlaps)
    assert average_overlap < 0.25, (
        f"users across personas share {average_overlap:.0%} of their shelf, "
        "which suggests the ranker is not personalising"
    )


def test_users_of_the_same_persona_agree_more_than_users_of_different_personas(conn):
    """
    The positive half of the personalisation test. Personalising is not just
    producing different output; it is producing output that tracks taste.
    Users drawn from the same persona should overlap MORE than users drawn from
    different ones.
    """
    def shelf(user_id: int) -> set[int]:
        return {row["product_id"] for row in recommend(conn, user_id, 10)}

    pairs = conn.execute(
        """
        SELECT u.persona, ARRAY_AGG(prof.user_id ORDER BY prof.distinct_products DESC) AS users
        FROM user_recommendation_profile AS prof
        JOIN users AS u ON u.user_id = prof.user_id
        WHERE prof.user_tier = 'warm' AND prof.distinct_products >= 25
        GROUP BY u.persona
        HAVING COUNT(*) >= 2
        """
    ).fetchall()
    assert len(pairs) >= 4

    same, different = [], []
    for row in pairs:
        a, b = row["users"][0], row["users"][1]
        same.append(len(shelf(a) & shelf(b)) / 10)

    for i, row in enumerate(pairs):
        other = pairs[(i + 1) % len(pairs)]
        different.append(len(shelf(row["users"][0]) & shelf(other["users"][0])) / 10)

    assert sum(same) / len(same) > sum(different) / len(different)


def test_cold_user_is_served_by_the_cold_start_path(conn, cold_user):
    recs = recommend(conn, cold_user, 10)
    assert len(recs) == 10
    assert {row["strategy"] for row in recs} <= {
        "trending_cold_start", "category_affinity", "collaborative_filtering"
    }


def test_unknown_user_degrades_to_trending_rather_than_failing(conn):
    recs = recommend(conn, 10_000_000, 10)
    assert len(recs) == 10
    assert all(row["strategy"] == "trending_cold_start" for row in recs)


def test_recommendations_are_deterministic(conn, warm_user):
    """Same input, same shelf. Ties are broken on product_id for this reason."""
    first = [row["product_id"] for row in recommend(conn, warm_user, 15)]
    second = [row["product_id"] for row in recommend(conn, warm_user, 15)]
    assert first == second


def test_similar_products_excludes_the_source_and_is_ordered(conn, popular_product):
    rows = conn.execute(
        "SELECT * FROM get_similar_products(%s, 12)", (popular_product,)
    ).fetchall()
    assert rows
    assert all(row["product_id"] != popular_product for row in rows)
    scores = [float(row["similarity_score"]) for row in rows]
    assert scores == sorted(scores, reverse=True)


def test_similarity_is_symmetric(conn):
    """
    Cosine similarity is symmetric by definition, and the matrix mirrors each
    pair explicitly. Asymmetric scores would mean the mirroring step is wrong.
    """
    row = conn.execute(
        """
        SELECT COUNT(*) AS asymmetric
        FROM mv_product_similarity AS a
        JOIN mv_product_similarity AS b
          ON b.product_a = a.product_b AND b.product_b = a.product_a
        WHERE ABS(a.cosine_similarity - b.cosine_similarity) > 1e-9
        """
    ).fetchone()
    assert row["asymmetric"] == 0


def test_similarity_scores_are_in_range(conn):
    row = conn.execute(
        """
        SELECT COUNT(*) AS out_of_range
        FROM mv_product_similarity
        WHERE cosine_similarity < 0 OR cosine_similarity > 1.0000001
           OR jaccard_similarity < 0 OR jaccard_similarity > 1.0000001
        """
    ).fetchone()
    assert row["out_of_range"] == 0


def test_no_product_is_its_own_neighbour(conn):
    row = conn.execute(
        "SELECT COUNT(*) AS n FROM mv_product_similarity WHERE product_a = product_b"
    ).fetchone()
    assert row["n"] == 0


def test_similarity_pairs_clear_the_support_floor(conn):
    floor = conn.execute(
        "SELECT rec_setting('min_common_users') AS v"
    ).fetchone()["v"]
    row = conn.execute(
        "SELECT MIN(common_users) AS smallest FROM mv_product_similarity"
    ).fetchone()
    assert row["smallest"] >= floor


def test_category_affinity_sums_to_one_per_user(conn):
    row = conn.execute(
        """
        SELECT COUNT(*) AS broken FROM (
            SELECT user_id, SUM(category_affinity) AS total
            FROM mv_user_category_preferences
            GROUP BY user_id
        ) AS s
        WHERE ABS(total - 1) > 0.001
        """
    ).fetchone()
    assert row["broken"] == 0


def test_full_text_search_finds_an_exact_product_name(conn):
    target = conn.execute(
        "SELECT product_id, name FROM products WHERE is_active ORDER BY product_id LIMIT 1"
    ).fetchone()
    found = conn.execute(
        "SELECT product_id FROM search_products(%s, 20)", (target["name"],)
    ).fetchall()
    assert target["product_id"] in {row["product_id"] for row in found}


@pytest.mark.parametrize("limit", [1, 5, 10])
def test_trending_respects_its_limit(conn, limit):
    rows = conn.execute(
        "SELECT * FROM get_trending_products(%s)", (limit,)
    ).fetchall()
    assert len(rows) == limit
