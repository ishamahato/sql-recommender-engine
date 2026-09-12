"""
Streamlit dashboard for the SQL recommendation engine.

Like the API, this renders what PostgreSQL computed and computes nothing of its
own. Every panel is one query or one function call. The point of the dashboard
is to make the SQL inspectable: pick a user, see their history, see the taste
model the SQL built from it, see the recommendations and the reason attached to
each, and see the similarity matrix that produced them.

Run with:  streamlit run dashboard/app.py
"""

from __future__ import annotations

import json
import sys
from decimal import Decimal
from pathlib import Path

import altair as alt
import pandas as pd
import streamlit as st

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from python.config import DATA_DIR  # noqa: E402
from python.db import connect  # noqa: E402

st.set_page_config(
    page_title="SQL Recommendation Engine",
    page_icon="::",
    layout="wide",
)


@st.cache_data(ttl=120)
def run(sql: str, params: tuple = ()) -> pd.DataFrame:
    with connect() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            return to_frame(cur.fetchall())


def to_frame(rows: list[dict]) -> pd.DataFrame:
    """
    Rows to a DataFrame, with NUMERIC columns converted to float.

    psycopg maps PostgreSQL NUMERIC to Python Decimal, which is the right call
    for money and the wrong one for charting: Altair cannot infer a Vega Lite
    type from Decimal and silently falls back to nominal, which turns a
    continuous axis into a category axis. The conversion happens here, at the
    display boundary, so the database layer keeps exact arithmetic.
    """
    frame = pd.DataFrame(rows)
    for column in frame.columns:
        values = frame[column].dropna()
        if not values.empty and values.map(lambda v: isinstance(v, Decimal)).all():
            frame[column] = frame[column].astype(float)
    return frame


@st.cache_data(ttl=120)
def pipeline_state() -> dict:
    return run(
        """
        SELECT
            ps.mode,
            ps.as_of_timestamp,
            ps.last_refreshed_at,
            (SELECT COUNT(*) FROM mv_product_similarity)        AS similarity_pairs,
            (SELECT COUNT(*) FROM mv_user_product_features)     AS feature_rows,
            (SELECT COUNT(*) FROM products WHERE is_active)     AS active_products,
            (SELECT COUNT(*) FROM users)                        AS users
        FROM pipeline_state AS ps
        """
    ).iloc[0].to_dict()


def load_evaluation() -> dict | None:
    path = DATA_DIR / "evaluation_results.json"
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


state = pipeline_state()

st.title("SQL Recommendation Engine")
st.caption(
    "PostgreSQL performs feature engineering, similarity, candidate generation, "
    "scoring and ranking. This page only displays the results."
)

top = st.columns(5)
top[0].metric("Users", f"{state['users']:,}")
top[1].metric("Active products", f"{state['active_products']:,}")
top[2].metric("Feature rows", f"{state['feature_rows']:,}")
top[3].metric("Similarity pairs", f"{state['similarity_pairs']:,}")
top[4].metric("Pipeline mode", state["mode"])
st.caption(
    f"Pipeline cutoff {state['as_of_timestamp']}  |  "
    f"offline layer last refreshed {state['last_refreshed_at']}"
)

tab_user, tab_product, tab_catalogue, tab_eval = st.tabs(
    ["User recommendations", "Product similarity", "Catalogue", "Model evaluation"]
)


# ===========================================================================
# User tab
# ===========================================================================

with tab_user:
    tiers = run(
        """
        SELECT user_tier, COUNT(*) AS users
        FROM user_recommendation_profile
        GROUP BY user_tier ORDER BY user_tier
        """
    )

    left, right = st.columns([1, 2])
    with left:
        tier_choice = st.selectbox(
            "User tier",
            options=["any"] + tiers["user_tier"].tolist(),
            help="Cold, light and warm are decided in SQL by user_recommendation_profile.",
        )
        tier_filter = "" if tier_choice == "any" else "WHERE user_tier = %s"
        params = () if tier_choice == "any" else (tier_choice,)
        sample = run(
            f"""
            SELECT prof.user_id, u.persona, prof.user_tier, prof.distinct_products
            FROM user_recommendation_profile AS prof
            JOIN users AS u ON u.user_id = prof.user_id
            {tier_filter}
            ORDER BY prof.user_id
            LIMIT 400
            """,
            params,
        )
        user_id = st.selectbox(
            "User",
            options=sample["user_id"].tolist(),
            format_func=lambda uid: (
                f"{uid} ({sample.loc[sample.user_id == uid, 'persona'].iloc[0]})"
            ),
        )
        limit = st.slider("Recommendations", 5, 25, 10)

    with right:
        profile = run(
            """
            SELECT prof.*, u.persona, u.city, u.age
            FROM user_recommendation_profile AS prof
            JOIN users AS u ON u.user_id = prof.user_id
            WHERE prof.user_id = %s
            """,
            (user_id,),
        )
        if not profile.empty:
            row = profile.iloc[0]
            cols = st.columns(4)
            cols[0].metric("Tier", row["user_tier"])
            cols[1].metric("Products touched", f"{row['distinct_products']:,}")
            cols[2].metric("Purchased", f"{row['purchased_products']:,}")
            cols[3].metric("Interactions", f"{row['total_interactions']:,}")
            st.caption(
                f"Generated persona: {row['persona']}. The recommender never "
                "reads this field; it is here so you can judge whether the "
                "recommendations make sense."
            )

    st.subheader("Category preferences")
    prefs = run(
        """
        SELECT category_name, interaction_score, decayed_score, purchase_count,
               category_affinity, preference_rank
        FROM mv_user_category_preferences
        WHERE user_id = %s
        ORDER BY preference_rank
        """,
        (user_id,),
    )
    if prefs.empty:
        st.info("No category history yet. This user is served by the cold start path.")
    else:
        chart_col, table_col = st.columns([2, 3])
        with chart_col:
            st.altair_chart(
                alt.Chart(prefs)
                .mark_bar()
                .encode(
                    x=alt.X("category_affinity:Q", title="Share of engagement"),
                    y=alt.Y("category_name:N", sort="-x", title=None),
                    tooltip=["category_name", "category_affinity", "purchase_count"],
                )
                .properties(height=min(40 * len(prefs) + 40, 340)),
                width="stretch",
            )
        table_col.dataframe(prefs, hide_index=True, width="stretch")

    st.subheader("Purchase history")
    history = run(
        """
        SELECT o.order_date::DATE AS order_date, p.name AS product, c.category_name AS category,
               oi.quantity, oi.unit_price,
               ROUND(oi.quantity * oi.unit_price, 2) AS line_total
        FROM orders AS o
        JOIN order_items AS oi ON oi.order_id   = o.order_id
        JOIN products    AS p  ON p.product_id  = oi.product_id
        JOIN categories  AS c  ON c.category_id = p.category_id
        WHERE o.user_id = %s
        ORDER BY o.order_date DESC
        LIMIT 40
        """,
        (user_id,),
    )
    if history.empty:
        st.info("This user has not ordered yet.")
    else:
        st.dataframe(history, hide_index=True, width="stretch")

    st.subheader("Recommendations")
    recs = run(
        """
        SELECT recommendation_rank AS rank, product_name, category, price,
               recommendation_score, strategy, recommendation_reason
        FROM get_recommendations(%s, %s)
        """,
        (user_id, limit),
    )
    st.dataframe(
        recs,
        hide_index=True,
        width="stretch",
        column_config={
            "recommendation_score": st.column_config.ProgressColumn(
                "Score", min_value=0.0, max_value=1.0, format="%.3f"
            ),
            "recommendation_reason": st.column_config.TextColumn("Why", width="large"),
        },
    )
    st.caption(
        "Scores are normalised within one response, so they rank the candidates "
        "against each other and are not comparable between users."
    )


# ===========================================================================
# Product tab
# ===========================================================================

with tab_product:
    search_term = st.text_input("Find a product", value="wireless headphones")
    found = run(
        "SELECT product_id, product_name, category, brand, price FROM search_products(%s, 25)",
        (search_term,),
    )
    if found.empty:
        st.warning("Nothing matched that search.")
    else:
        product_id = st.selectbox(
            "Product",
            options=found["product_id"].tolist(),
            format_func=lambda pid: (
                f"{found.loc[found.product_id == pid, 'product_name'].iloc[0]} "
                f"({found.loc[found.product_id == pid, 'brand'].iloc[0]})"
            ),
        )

        popularity = run(
            """
            SELECT product_name, category_name, subcategory, brand, price,
                   view_count, cart_count, purchase_count, unique_users,
                   smoothed_rating, popularity_score, popularity_global_rank,
                   popularity_category_rank, demand_tier, view_to_purchase_rate
            FROM mv_product_popularity WHERE product_id = %s
            """,
            (product_id,),
        )
        if not popularity.empty:
            row = popularity.iloc[0]
            cols = st.columns(6)
            cols[0].metric("Views", f"{row['view_count']:,}")
            cols[1].metric("Carts", f"{row['cart_count']:,}")
            cols[2].metric("Purchases", f"{row['purchase_count']:,}")
            cols[3].metric("Rating", f"{row['smoothed_rating']:.2f}")
            cols[4].metric("Popularity", f"{row['popularity_score']:.3f}")
            cols[5].metric("Demand tier", row["demand_tier"])
            st.caption(
                f"Rank {row['popularity_global_rank']} overall, "
                f"rank {row['popularity_category_rank']} in {row['category_name']}."
            )

        st.subheader("Similar products")
        similar = run(
            """
            SELECT product_name, category, brand, price, similarity_score,
                   common_users, similarity_basis, relationship
            FROM get_similar_products(%s, 12)
            """,
            (product_id,),
        )
        st.dataframe(similar, hide_index=True, width="stretch")
        st.caption(
            "Similarity is cosine over user engagement vectors, computed in SQL "
            "by mv_product_similarity. No product attributes are used, which is "
            "why cross category pairs appear."
        )


# ===========================================================================
# Catalogue tab
# ===========================================================================

with tab_catalogue:
    st.subheader("Most popular products")
    popular = run(
        """
        SELECT product_name, category_name, brand, price, purchase_count,
               view_count, smoothed_rating, popularity_score, demand_tier
        FROM mv_product_popularity
        WHERE is_active
        ORDER BY popularity_global_rank
        LIMIT 25
        """
    )
    st.dataframe(popular, hide_index=True, width="stretch")

    st.subheader("Revenue by category")
    revenue = run(
        """
        SELECT c.category_name,
               ROUND(SUM(oi.quantity * oi.unit_price), 2) AS revenue,
               COUNT(DISTINCT o.order_id) AS orders
        FROM order_items AS oi
        JOIN orders     AS o ON o.order_id    = oi.order_id
        JOIN products   AS p ON p.product_id  = oi.product_id
        JOIN categories AS c ON c.category_id = p.category_id
        WHERE o.order_date < rec_as_of()
        GROUP BY c.category_name
        ORDER BY revenue DESC
        """
    )
    st.altair_chart(
        alt.Chart(revenue)
        .mark_bar()
        .encode(
            x=alt.X("revenue:Q", title="Revenue"),
            y=alt.Y("category_name:N", sort="-x", title=None),
            tooltip=["category_name", "revenue", "orders"],
        )
        .properties(height=300),
        width="stretch",
    )

    st.subheader("Monthly revenue")
    monthly = run(
        """
        SELECT DATE_TRUNC('month', order_date)::DATE AS month,
               ROUND(SUM(total_amount), 2) AS revenue,
               COUNT(*) AS orders
        FROM orders
        WHERE order_date < rec_as_of()
        GROUP BY 1 ORDER BY 1
        """
    )
    st.altair_chart(
        alt.Chart(monthly)
        .mark_line(point=True)
        .encode(
            x=alt.X("month:T", title=None),
            y=alt.Y("revenue:Q", title="Revenue"),
            tooltip=["month", "revenue", "orders"],
        )
        .properties(height=280),
        width="stretch",
    )


# ===========================================================================
# Evaluation tab
# ===========================================================================

with tab_eval:
    results = load_evaluation()
    if results is None:
        st.warning("No evaluation on disk yet. Run: python -m python.evaluate")
    else:
        st.caption(
            f"Temporal split at {results['cutoff']}. "
            f"{results['train_events']:,} events before the cutoff were visible to "
            f"the recommender; {results['test_events']:,} after it were held out. "
            f"{results['n_users']:,} users scored against "
            f"{results['held_out_purchases']:,} held out purchases."
        )

        metric_keys = [
            ("precision_at_5", "Precision@5"),
            ("precision_at_10", "Precision@10"),
            ("recall_at_5", "Recall@5"),
            ("recall_at_10", "Recall@10"),
            ("hit_rate_at_10", "Hit Rate@10"),
            ("ndcg_at_10", "NDCG@10"),
            ("served_rate", "Users served"),
        ]
        labels = {
            "popularity": "Popularity",
            "collaborative": "Collaborative filtering",
            "hybrid": "Hybrid SQL recommender",
        }

        rows = []
        for key, label in metric_keys:
            for strategy, strategy_label in labels.items():
                rows.append(
                    {
                        "metric": label,
                        "strategy": strategy_label,
                        "value": results["strategies"][strategy][key],
                    }
                )
        frame = pd.DataFrame(rows)

        st.altair_chart(
            alt.Chart(frame)
            .mark_bar()
            .encode(
                x=alt.X("strategy:N", title=None, axis=alt.Axis(labels=False)),
                y=alt.Y("value:Q", title=None),
                color=alt.Color("strategy:N", title="Strategy"),
                column=alt.Column("metric:N", title=None),
                tooltip=["strategy", "metric", "value"],
            )
            .properties(height=240, width=110),
            width="content",
        )

        st.dataframe(
            frame.pivot(index="metric", columns="strategy", values="value"),
            width="stretch",
        )

        st.subheader("Catalogue behaviour")
        coverage = pd.DataFrame(
            [
                {
                    "strategy": labels[s],
                    "distinct products": results["strategies"][s]["distinct_products"],
                    "catalogue coverage": results["strategies"][s]["catalogue_coverage"],
                    "head share": results["strategies"][s]["head_share"],
                    "latency ms per user": results["strategies"][s]["mean_latency_ms"],
                }
                for s in labels
            ]
        )
        st.dataframe(coverage, hide_index=True, width="stretch")
        st.caption(
            "Coverage matters as much as precision. A recommender that shows the "
            "same handful of bestsellers to everybody can post a decent hit rate "
            "while being useless for discovery."
        )

        st.subheader("Hybrid recommender by user tier")
        tier_rows = [
            {"tier": tier, **{k: v for k, v in values.items() if k != "users"},
             "users": values["users"]}
            for tier, values in results["strategies"]["hybrid"]["by_tier"].items()
        ]
        st.dataframe(pd.DataFrame(tier_rows), hide_index=True, width="stretch")
