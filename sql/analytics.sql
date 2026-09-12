/*
===============================================================================
 analytics.sql
===============================================================================
 Twenty five analytical queries over the same schema the recommender runs on.

 This file is a query library, not a migration. Nothing here creates an object;
 every statement is a SELECT you can paste into psql and run. python/pipeline.py
 deliberately does not execute it, and tests/test_analytics.py runs every query
 to prove none of them has rotted.

 The queries are ordered roughly from commercial reporting toward behavioural
 analysis. Each carries a header naming the SQL technique it exists to
 demonstrate, because several of them could be written more simply and are not:
 where a window function replaces a self join or a correlated subquery, the
 header says so.

 Every query is bounded by `rec_as_of()` wherever it touches the event log, so
 running these during an evaluation replay reports the same world the
 recommender sees.
===============================================================================
*/


/*
===============================================================================
 QUERY 01 | Top products by revenue
 Technique: aggregation with FILTER, plus a window total for share of revenue
===============================================================================
 FILTER is the readable alternative to SUM(CASE WHEN ... THEN ... END) and lets
 several conditional aggregates share one pass over the table.
*/
SELECT
    p.product_id,
    p.name                                          AS product_name,
    c.category_name,
    p.brand,
    COUNT(DISTINCT oi.order_id)                     AS orders,
    SUM(oi.quantity)                                AS units_sold,
    ROUND(SUM(oi.quantity * oi.unit_price), 2)      AS revenue,
    ROUND(AVG(oi.unit_price), 2)                    AS average_selling_price,
    ROUND(
        100.0 * SUM(oi.quantity * oi.unit_price)
        / SUM(SUM(oi.quantity * oi.unit_price)) OVER (),
        3
    )                                               AS pct_of_total_revenue
FROM order_items AS oi
JOIN orders     AS o ON o.order_id    = oi.order_id
JOIN products   AS p ON p.product_id  = oi.product_id
JOIN categories AS c ON c.category_id = p.category_id
WHERE o.order_date < rec_as_of()
GROUP BY p.product_id, p.name, c.category_name, p.brand
ORDER BY revenue DESC
LIMIT 25;


/*
===============================================================================
 QUERY 02 | Revenue by category, with share and rank
 Technique: SUM() OVER () for a grand total without a second pass
===============================================================================
 The naive version computes the grand total in a scalar subquery, which scans
 the fact table twice. The window aggregate reuses the rows already in hand.
*/
SELECT
    c.category_name,
    COUNT(DISTINCT o.order_id)                      AS orders,
    COUNT(DISTINCT o.user_id)                       AS customers,
    ROUND(SUM(oi.quantity * oi.unit_price), 2)      AS revenue,
    ROUND(
        100.0 * SUM(oi.quantity * oi.unit_price)
        / SUM(SUM(oi.quantity * oi.unit_price)) OVER (),
        2
    )                                               AS pct_of_revenue,
    RANK() OVER (ORDER BY SUM(oi.quantity * oi.unit_price) DESC) AS revenue_rank
FROM order_items AS oi
JOIN orders     AS o ON o.order_id    = oi.order_id
JOIN products   AS p ON p.product_id  = oi.product_id
JOIN categories AS c ON c.category_id = p.category_id
WHERE o.order_date < rec_as_of()
GROUP BY c.category_name
ORDER BY revenue DESC;


/*
===============================================================================
 QUERY 03 | Monthly revenue with month over month growth
 Technique: LAG() for the previous period, SUM() OVER for a running total
===============================================================================
 LAG is the reason this is one pass instead of a self join on month minus one,
 and it handles the first month correctly for free rather than needing an outer
 join.
*/
WITH monthly AS (
    SELECT
        DATE_TRUNC('month', o.order_date)::DATE      AS month,
        COUNT(DISTINCT o.order_id)                   AS orders,
        COUNT(DISTINCT o.user_id)                    AS active_customers,
        ROUND(SUM(o.total_amount), 2)                AS revenue
    FROM orders AS o
    WHERE o.order_date < rec_as_of()
    GROUP BY DATE_TRUNC('month', o.order_date)
)
SELECT
    month,
    orders,
    active_customers,
    revenue,
    LAG(revenue) OVER (ORDER BY month)              AS previous_month_revenue,
    ROUND(
        100.0 * (revenue - LAG(revenue) OVER (ORDER BY month))
        / NULLIF(LAG(revenue) OVER (ORDER BY month), 0),
        2
    )                                               AS mom_growth_pct,
    LEAD(revenue) OVER (ORDER BY month)             AS next_month_revenue,
    ROUND(SUM(revenue) OVER (ORDER BY month ROWS UNBOUNDED PRECEDING), 2)
                                                    AS cumulative_revenue,
    ROUND(AVG(revenue) OVER (ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)
                                                    AS revenue_3month_average
FROM monthly
ORDER BY month;


/*
===============================================================================
 QUERY 04 | Average order value, overall and by month
 Technique: aggregate over an aggregate via a CTE, plus a window average
===============================================================================
*/
WITH order_values AS (
    SELECT
        o.order_id,
        DATE_TRUNC('month', o.order_date)::DATE AS month,
        o.total_amount,
        (SELECT SUM(oi.quantity) FROM order_items AS oi WHERE oi.order_id = o.order_id)
                                                AS units
    FROM orders AS o
    WHERE o.order_date < rec_as_of()
)
SELECT
    month,
    COUNT(*)                                        AS orders,
    ROUND(AVG(total_amount), 2)                     AS average_order_value,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total_amount)::NUMERIC, 2)
                                                    AS median_order_value,
    ROUND(AVG(units), 2)                            AS average_basket_size,
    ROUND(AVG(AVG(total_amount)) OVER (), 2)        AS average_across_all_months
FROM order_values
GROUP BY month
ORDER BY month;


/*
===============================================================================
 QUERY 05 | Customer lifetime value with deciles
 Technique: NTILE() and PERCENT_RANK() for distribution placement
===============================================================================
 NTILE answers "which tenth of the customer base is this", which is what a
 retention team acts on. PERCENT_RANK answers "what fraction of customers spend
 less than this one", which is the continuous version and does not lump
 everyone in a decile together.
*/
WITH customer_value AS (
    SELECT
        u.user_id,
        u.city,
        u.signup_date,
        COUNT(DISTINCT o.order_id)                  AS orders,
        ROUND(SUM(o.total_amount), 2)               AS lifetime_value,
        ROUND(AVG(o.total_amount), 2)               AS average_order_value,
        MIN(o.order_date)::DATE                     AS first_order,
        MAX(o.order_date)::DATE                     AS last_order
    FROM users  AS u
    JOIN orders AS o ON o.user_id = u.user_id
    WHERE o.order_date < rec_as_of()
    GROUP BY u.user_id, u.city, u.signup_date
)
SELECT
    user_id,
    city,
    orders,
    lifetime_value,
    average_order_value,
    first_order,
    last_order,
    (last_order - first_order)                      AS customer_lifespan_days,
    NTILE(10) OVER (ORDER BY lifetime_value DESC)   AS value_decile,
    ROUND(PERCENT_RANK() OVER (ORDER BY lifetime_value)::NUMERIC, 4)
                                                    AS value_percentile
FROM customer_value
ORDER BY lifetime_value DESC
LIMIT 50;


/*
===============================================================================
 QUERY 06 | Repeat purchase rate
 Technique: conditional aggregation over a per customer summary
===============================================================================
 One of the few numbers that predicts whether a storefront survives. Reported
 overall and split by the category of the customer's first order, which is the
 question a merchandising team actually asks: which aisle acquires customers who
 come back.
*/
WITH customer_orders AS (
    SELECT
        o.user_id,
        o.order_id,
        o.order_date,
        ROW_NUMBER() OVER (PARTITION BY o.user_id ORDER BY o.order_date) AS order_sequence
    FROM orders AS o
    WHERE o.order_date < rec_as_of()
),
first_order_category AS (
    SELECT DISTINCT ON (co.user_id)
        co.user_id,
        c.category_name AS acquisition_category
    FROM customer_orders AS co
    JOIN order_items AS oi ON oi.order_id   = co.order_id
    JOIN products    AS p  ON p.product_id  = oi.product_id
    JOIN categories  AS c  ON c.category_id = p.category_id
    WHERE co.order_sequence = 1
    ORDER BY co.user_id, oi.quantity * oi.unit_price DESC
),
customer_totals AS (
    SELECT user_id, MAX(order_sequence) AS total_orders
    FROM customer_orders
    GROUP BY user_id
)
SELECT
    foc.acquisition_category,
    COUNT(*)                                                        AS customers,
    COUNT(*) FILTER (WHERE ct.total_orders >= 2)                    AS repeat_customers,
    ROUND(100.0 * COUNT(*) FILTER (WHERE ct.total_orders >= 2) / COUNT(*), 2)
                                                                    AS repeat_rate_pct,
    ROUND(AVG(ct.total_orders), 2)                                  AS average_orders_per_customer
FROM customer_totals AS ct
JOIN first_order_category AS foc ON foc.user_id = ct.user_id
GROUP BY foc.acquisition_category
ORDER BY repeat_rate_pct DESC;


/*
===============================================================================
 QUERY 07 | Purchase frequency distribution
 Technique: histogram by bucketing, with a cumulative window share
===============================================================================
*/
WITH per_customer AS (
    SELECT o.user_id, COUNT(*) AS orders
    FROM orders AS o
    WHERE o.order_date < rec_as_of()
    GROUP BY o.user_id
),
bucketed AS (
    SELECT
        CASE
            WHEN orders = 1          THEN '01 order'
            WHEN orders = 2          THEN '02 orders'
            WHEN orders BETWEEN 3 AND 5   THEN '03 to 05 orders'
            WHEN orders BETWEEN 6 AND 10  THEN '06 to 10 orders'
            WHEN orders BETWEEN 11 AND 20 THEN '11 to 20 orders'
            ELSE '21 or more orders'
        END             AS frequency_band,
        user_id,
        orders
    FROM per_customer
)
SELECT
    frequency_band,
    COUNT(*)                                                AS customers,
    SUM(orders)                                             AS total_orders,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)      AS pct_of_customers,
    ROUND(100.0 * SUM(orders) / SUM(SUM(orders)) OVER (), 2) AS pct_of_orders,
    ROUND(
        100.0 * SUM(COUNT(*)) OVER (ORDER BY frequency_band ROWS UNBOUNDED PRECEDING)
        / SUM(COUNT(*)) OVER (),
        2
    )                                                       AS cumulative_pct_customers
FROM bucketed
GROUP BY frequency_band
ORDER BY frequency_band;


/*
===============================================================================
 QUERY 08 | Most viewed products, and what the views were worth
 Technique: FILTER aggregates over the interaction log
===============================================================================
*/
SELECT
    p.product_id,
    p.name                                                  AS product_name,
    c.category_name,
    COUNT(*) FILTER (WHERE i.interaction_type = 'view')     AS views,
    COUNT(DISTINCT i.user_id) FILTER (WHERE i.interaction_type = 'view')
                                                            AS unique_viewers,
    COUNT(*) FILTER (WHERE i.interaction_type = 'cart')     AS carts,
    COUNT(*) FILTER (WHERE i.interaction_type = 'purchase') AS purchases,
    ROUND(
        COUNT(*) FILTER (WHERE i.interaction_type = 'view')::NUMERIC
        / NULLIF(COUNT(DISTINCT i.user_id) FILTER (WHERE i.interaction_type = 'view'), 0),
        2
    )                                                       AS views_per_viewer
FROM user_interactions AS i
JOIN products   AS p ON p.product_id  = i.product_id
JOIN categories AS c ON c.category_id = p.category_id
WHERE i.interaction_timestamp < rec_as_of()
GROUP BY p.product_id, p.name, c.category_name
ORDER BY views DESC
LIMIT 25;


/*
===============================================================================
 QUERY 09 | Highest converting products
 Technique: funnel ratios with a volume floor to keep the result meaningful
===============================================================================
 Without the HAVING floor this returns whatever was viewed twice and bought
 once, at a 50 percent conversion rate and no commercial significance. A
 minimum denominator is the difference between a conversion report and a noise
 report.
*/
SELECT
    p.product_id,
    p.name                                                  AS product_name,
    c.category_name,
    p.price,
    COUNT(*) FILTER (WHERE i.interaction_type = 'view')     AS views,
    COUNT(*) FILTER (WHERE i.interaction_type = 'cart')     AS carts,
    COUNT(*) FILTER (WHERE i.interaction_type = 'purchase') AS purchases,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE i.interaction_type = 'cart')
        / NULLIF(COUNT(*) FILTER (WHERE i.interaction_type = 'view'), 0), 2
    )                                                       AS view_to_cart_pct,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE i.interaction_type = 'purchase')
        / NULLIF(COUNT(*) FILTER (WHERE i.interaction_type = 'cart'), 0), 2
    )                                                       AS cart_to_purchase_pct,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE i.interaction_type = 'purchase')
        / NULLIF(COUNT(*) FILTER (WHERE i.interaction_type = 'view'), 0), 2
    )                                                       AS view_to_purchase_pct
FROM user_interactions AS i
JOIN products   AS p ON p.product_id  = i.product_id
JOIN categories AS c ON c.category_id = p.category_id
WHERE i.interaction_timestamp < rec_as_of()
GROUP BY p.product_id, p.name, c.category_name, p.price
HAVING COUNT(*) FILTER (WHERE i.interaction_type = 'view') >= 200
ORDER BY view_to_purchase_pct DESC
LIMIT 25;


/*
===============================================================================
 QUERY 10 | Trending products, four weeks against the four before
 Technique: conditional aggregation over two windows in a single pass
===============================================================================
 Two date ranges compared without joining the table to itself. The CASE picks
 which bucket each row lands in and the aggregate does the rest.
*/
WITH windowed AS (
    SELECT
        i.product_id,
        COUNT(*) FILTER (
            WHERE i.interaction_timestamp >= rec_as_of() - INTERVAL '4 weeks'
        )                                                       AS recent_events,
        COUNT(*) FILTER (
            WHERE i.interaction_timestamp >= rec_as_of() - INTERVAL '8 weeks'
              AND i.interaction_timestamp <  rec_as_of() - INTERVAL '4 weeks'
        )                                                       AS prior_events,
        COUNT(*) FILTER (
            WHERE i.interaction_type = 'purchase'
              AND i.interaction_timestamp >= rec_as_of() - INTERVAL '4 weeks'
        )                                                       AS recent_purchases
    FROM user_interactions AS i
    WHERE i.interaction_timestamp >= rec_as_of() - INTERVAL '8 weeks'
      AND i.interaction_timestamp <  rec_as_of()
    GROUP BY i.product_id
)
SELECT
    p.product_id,
    p.name                              AS product_name,
    c.category_name,
    w.prior_events,
    w.recent_events,
    w.recent_purchases,
    ROUND(w.recent_events::NUMERIC / NULLIF(w.prior_events, 0), 3) AS growth_multiple,
    CASE
        WHEN w.prior_events = 0                             THEN 'newly discovered'
        WHEN w.recent_events > w.prior_events * 1.5         THEN 'surging'
        WHEN w.recent_events > w.prior_events * 1.1         THEN 'rising'
        WHEN w.recent_events < w.prior_events * 0.7         THEN 'cooling'
        ELSE 'steady'
    END                                 AS trend_label
FROM windowed AS w
JOIN products   AS p ON p.product_id  = w.product_id
JOIN categories AS c ON c.category_id = p.category_id
WHERE w.recent_events >= 50
ORDER BY growth_multiple DESC NULLS LAST, w.recent_events DESC
LIMIT 25;


/*
===============================================================================
 QUERY 11 | Each customer's favourite and second favourite category
 Technique: ROW_NUMBER() with conditional aggregation to pivot ranks to columns
===============================================================================
 The alternative is two correlated subqueries or a self join on rank, both of
 which read the same data twice. Ranking once and pivoting with FILTER reads it
 once.
*/
WITH ranked AS (
    SELECT
        ucp.user_id,
        ucp.category_name,
        ucp.interaction_score,
        ucp.purchase_count,
        ROW_NUMBER() OVER (
            PARTITION BY ucp.user_id ORDER BY ucp.interaction_score DESC, ucp.category_id
        ) AS preference_rank
    FROM user_category_preferences AS ucp
)
SELECT
    u.user_id,
    u.persona                                                           AS generated_persona,
    MAX(r.category_name)     FILTER (WHERE r.preference_rank = 1)       AS favourite_category,
    MAX(r.interaction_score) FILTER (WHERE r.preference_rank = 1)       AS favourite_score,
    MAX(r.category_name)     FILTER (WHERE r.preference_rank = 2)       AS second_category,
    MAX(r.interaction_score) FILTER (WHERE r.preference_rank = 2)       AS second_score,
    MAX(r.category_name)     FILTER (WHERE r.preference_rank = 3)       AS third_category,
    ROUND(
        MAX(r.interaction_score) FILTER (WHERE r.preference_rank = 1)::NUMERIC
        / NULLIF(SUM(r.interaction_score), 0),
        3
    )                                                                   AS favourite_concentration
FROM ranked AS r
JOIN users AS u ON u.user_id = r.user_id
GROUP BY u.user_id, u.persona
ORDER BY u.user_id
LIMIT 50;


/*
===============================================================================
 QUERY 12 | Products frequently purchased together
 Technique: SELF JOIN on the basket, deduplicated with a triangular predicate
===============================================================================
 Market basket analysis at the order level, which is a different question from
 the similarity matrix: this asks what goes in the same basket, the matrix asks
 what appeals to the same person over time.

 `a.product_id < b.product_id` does two jobs. It stops each pair being counted
 twice in mirror image, and it stops a product pairing with itself, without
 needing a separate inequality and a DISTINCT.

 `support` and `confidence` are the association rule measures. Confidence is
 directional and is the number a cross sell widget actually needs: given this
 product in the basket, how often does the other one join it.
*/
WITH basket AS (
    SELECT oi.order_id, oi.product_id
    FROM order_items AS oi
    JOIN orders AS o ON o.order_id = oi.order_id
    WHERE o.order_date < rec_as_of()
),
product_frequency AS (
    SELECT product_id, COUNT(*) AS baskets
    FROM basket
    GROUP BY product_id
),
pairs AS (
    SELECT
        a.product_id AS product_a,
        b.product_id AS product_b,
        COUNT(*)     AS baskets_together
    FROM basket AS a
    JOIN basket AS b
        ON  a.order_id    = b.order_id
        AND a.product_id  < b.product_id
    GROUP BY a.product_id, b.product_id
    HAVING COUNT(*) >= 10
)
SELECT
    pa.name                                     AS product_a,
    pb.name                                     AS product_b,
    ca.category_name                            AS category_a,
    cb.category_name                            AS category_b,
    pr.baskets_together,
    ROUND(100.0 * pr.baskets_together / (SELECT COUNT(DISTINCT order_id) FROM basket), 4)
                                                AS support_pct,
    ROUND(100.0 * pr.baskets_together / fa.baskets, 2)  AS confidence_a_to_b_pct,
    ROUND(100.0 * pr.baskets_together / fb.baskets, 2)  AS confidence_b_to_a_pct,
    ROUND(
        (pr.baskets_together::NUMERIC / (SELECT COUNT(DISTINCT order_id) FROM basket))
        / NULLIF(
            (fa.baskets::NUMERIC / (SELECT COUNT(DISTINCT order_id) FROM basket))
            * (fb.baskets::NUMERIC / (SELECT COUNT(DISTINCT order_id) FROM basket)),
        0),
        2
    )                                           AS lift
FROM pairs AS pr
JOIN product_frequency AS fa ON fa.product_id = pr.product_a
JOIN product_frequency AS fb ON fb.product_id = pr.product_b
JOIN products   AS pa ON pa.product_id  = pr.product_a
JOIN products   AS pb ON pb.product_id  = pr.product_b
JOIN categories AS ca ON ca.category_id = pa.category_id
JOIN categories AS cb ON cb.category_id = pb.category_id
ORDER BY lift DESC, pr.baskets_together DESC
LIMIT 25;


/*
===============================================================================
 QUERY 13 | Nearest neighbours for the best selling product
 Technique: reading the SQL built similarity matrix
===============================================================================
 The same data `get_similar_products` serves, queried directly so the matrix can
 be inspected rather than taken on trust.
*/
WITH top_seller AS (
    SELECT oi.product_id
    FROM order_items AS oi
    JOIN orders AS o ON o.order_id = oi.order_id
    WHERE o.order_date < rec_as_of()
    GROUP BY oi.product_id
    ORDER BY SUM(oi.quantity * oi.unit_price) DESC
    LIMIT 1
)
SELECT
    src.name                    AS source_product,
    p.name                      AS neighbour,
    c.category_name,
    p.subcategory,
    sim.common_users,
    sim.cosine_similarity,
    sim.jaccard_similarity,
    sim.neighbour_rank,
    CASE
        WHEN sim.same_subcategory THEN 'substitute'
        WHEN sim.same_category    THEN 'complement in the same aisle'
        ELSE                           'cross category affinity'
    END                         AS relationship
FROM top_seller AS t
JOIN mv_product_similarity AS sim ON sim.product_a = t.product_id
JOIN products   AS src ON src.product_id  = sim.product_a
JOIN products   AS p   ON p.product_id    = sim.product_b
JOIN categories AS c   ON c.category_id   = p.category_id
ORDER BY sim.cosine_similarity DESC
LIMIT 15;


/*
===============================================================================
 QUERY 14 | Customers who bought X but not Y
 Technique: ANTI JOIN with NOT EXISTS
===============================================================================
 The cross sell target list. X is the best selling product in Electronics and Y
 is its strongest neighbour, both chosen by the query rather than hard coded, so
 it runs as written on any regenerated dataset.

 NOT EXISTS rather than NOT IN: NOT IN returns nothing at all if the subquery
 yields a single NULL, which is the classic way this query silently breaks.
*/
WITH anchor AS (
    SELECT oi.product_id
    FROM order_items AS oi
    JOIN orders   AS o ON o.order_id   = oi.order_id
    JOIN products AS p ON p.product_id = oi.product_id
    JOIN categories AS c ON c.category_id = p.category_id
    WHERE c.category_name = 'Electronics'
      AND o.order_date < rec_as_of()
    GROUP BY oi.product_id
    ORDER BY SUM(oi.quantity * oi.unit_price) DESC
    LIMIT 1
),
target AS (
    SELECT sim.product_b AS product_id
    FROM anchor AS a
    JOIN mv_product_similarity AS sim ON sim.product_a = a.product_id
    ORDER BY sim.similarity_score DESC
    LIMIT 1
)
SELECT
    (SELECT name FROM products WHERE product_id = (SELECT product_id FROM anchor)) AS bought_this,
    (SELECT name FROM products WHERE product_id = (SELECT product_id FROM target)) AS but_not_this,
    u.user_id,
    u.city,
    COUNT(DISTINCT o.order_id)                  AS orders_with_anchor,
    ROUND(SUM(oi.quantity * oi.unit_price), 2)  AS spend_on_anchor
FROM users AS u
JOIN orders      AS o  ON o.user_id     = u.user_id
JOIN order_items AS oi ON oi.order_id   = o.order_id
WHERE oi.product_id = (SELECT product_id FROM anchor)
  AND o.order_date < rec_as_of()
  AND NOT EXISTS (
        SELECT 1
        FROM orders      AS o2
        JOIN order_items AS oi2 ON oi2.order_id = o2.order_id
        WHERE o2.user_id     = u.user_id
          AND oi2.product_id = (SELECT product_id FROM target)
          AND o2.order_date  < rec_as_of()
  )
GROUP BY u.user_id, u.city
ORDER BY spend_on_anchor DESC
LIMIT 25;


/*
===============================================================================
 QUERY 15 | Customers who purchased in consecutive months
 Technique: LAG() over a gapless month sequence, then a streak grouping
===============================================================================
 The gaps and islands problem. Subtracting a dense row number from the month
 index gives a constant for every run of consecutive months, which collapses
 the streak detection into a single GROUP BY. Without it this needs a recursive
 CTE or a procedural loop.
*/
WITH customer_months AS (
    SELECT DISTINCT
        o.user_id,
        DATE_TRUNC('month', o.order_date)::DATE AS month
    FROM orders AS o
    WHERE o.order_date < rec_as_of()
),
sequenced AS (
    SELECT
        user_id,
        month,
        LAG(month) OVER (PARTITION BY user_id ORDER BY month) AS previous_month,
        (
            EXTRACT(YEAR FROM month)::INTEGER * 12 + EXTRACT(MONTH FROM month)::INTEGER
        )
        - ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY month)::INTEGER AS streak_key
    FROM customer_months
),
streaks AS (
    SELECT
        user_id,
        streak_key,
        COUNT(*)    AS consecutive_months,
        MIN(month)  AS streak_start,
        MAX(month)  AS streak_end
    FROM sequenced
    GROUP BY user_id, streak_key
)
SELECT
    s.user_id,
    u.city,
    s.consecutive_months,
    s.streak_start,
    s.streak_end,
    ROUND(SUM(o.total_amount), 2) AS revenue_during_streak
FROM streaks AS s
JOIN users  AS u ON u.user_id = s.user_id
JOIN orders AS o
    ON  o.user_id = s.user_id
    AND o.order_date >= s.streak_start
    AND o.order_date <  s.streak_end + INTERVAL '1 month'
    AND o.order_date <  rec_as_of()
WHERE s.consecutive_months >= 3
GROUP BY s.user_id, u.city, s.consecutive_months, s.streak_start, s.streak_end
ORDER BY s.consecutive_months DESC, revenue_during_streak DESC
LIMIT 25;


/*
===============================================================================
 QUERY 16 | Cohort retention by signup month
 Technique: GENERATE_SERIES against a cohort base for a dense retention grid
===============================================================================
 Grouping orders by month offset alone produces a sparse grid: a cohort with no
 orders in month 3 simply has no row, and the chart silently skips it. Joining
 against a generated series of offsets makes the zero explicit, which is the
 difference between a retention curve and a misleading one.
*/
WITH cohorts AS (
    SELECT
        u.user_id,
        DATE_TRUNC('month', u.signup_date)::DATE AS cohort_month
    FROM users AS u
),
cohort_size AS (
    SELECT cohort_month, COUNT(*) AS cohort_users
    FROM cohorts
    GROUP BY cohort_month
),
activity AS (
    SELECT
        c.cohort_month,
        (
            (EXTRACT(YEAR FROM o.order_date)::INTEGER * 12
             + EXTRACT(MONTH FROM o.order_date)::INTEGER)
            - (EXTRACT(YEAR FROM c.cohort_month)::INTEGER * 12
               + EXTRACT(MONTH FROM c.cohort_month)::INTEGER)
        )                       AS month_offset,
        o.user_id
    FROM cohorts AS c
    JOIN orders  AS o ON o.user_id = c.user_id
    WHERE o.order_date < rec_as_of()
),
grid AS (
    SELECT cs.cohort_month, cs.cohort_users, offsets.month_offset
    FROM cohort_size AS cs
    CROSS JOIN LATERAL GENERATE_SERIES(0, 11) AS offsets(month_offset)
)
SELECT
    g.cohort_month,
    g.cohort_users,
    g.month_offset,
    COUNT(DISTINCT a.user_id)                                       AS active_users,
    ROUND(100.0 * COUNT(DISTINCT a.user_id) / g.cohort_users, 2)    AS retention_pct
FROM grid AS g
LEFT JOIN activity AS a
       ON  a.cohort_month = g.cohort_month
       AND a.month_offset = g.month_offset
GROUP BY g.cohort_month, g.cohort_users, g.month_offset
ORDER BY g.cohort_month, g.month_offset
LIMIT 100;


/*
===============================================================================
 QUERY 17 | Product ranking within its category
 Technique: RANK(), DENSE_RANK() and ROW_NUMBER() side by side
===============================================================================
 The three are shown together because the difference between them is the most
 commonly misunderstood thing in window functions, and the contrast is visible
 directly in the output when two products tie on revenue.

   ROW_NUMBER  unique, arbitrary among ties
   RANK        ties share, then a gap
   DENSE_RANK  ties share, no gap
*/
WITH product_revenue AS (
    SELECT
        p.product_id,
        p.name AS product_name,
        p.category_id,
        c.category_name,
        p.brand,
        ROUND(SUM(oi.quantity * oi.unit_price), 2) AS revenue,
        SUM(oi.quantity)                           AS units
    FROM order_items AS oi
    JOIN orders     AS o ON o.order_id    = oi.order_id
    JOIN products   AS p ON p.product_id  = oi.product_id
    JOIN categories AS c ON c.category_id = p.category_id
    WHERE o.order_date < rec_as_of()
    GROUP BY p.product_id, p.name, p.category_id, c.category_name, p.brand
)
SELECT
    category_name,
    product_name,
    brand,
    revenue,
    units,
    ROW_NUMBER() OVER (PARTITION BY category_id ORDER BY revenue DESC)  AS row_number_in_category,
    RANK()       OVER (PARTITION BY category_id ORDER BY units DESC)    AS rank_by_units,
    DENSE_RANK() OVER (PARTITION BY category_id ORDER BY units DESC)    AS dense_rank_by_units,
    ROUND(
        100.0 * revenue / SUM(revenue) OVER (PARTITION BY category_id), 2
    )                                                                   AS pct_of_category_revenue
FROM product_revenue
ORDER BY category_name, revenue DESC
LIMIT 200;


/*
===============================================================================
 QUERY 18 | Revenue concentration, the Pareto curve
 Technique: running total with SUM() OVER (ORDER BY ...)
===============================================================================
 Answers how few products carry the business. The running share is what turns a
 revenue list into a decision about which lines to keep.
*/
WITH product_revenue AS (
    SELECT
        p.product_id,
        p.name AS product_name,
        c.category_name,
        SUM(oi.quantity * oi.unit_price) AS revenue
    FROM order_items AS oi
    JOIN orders     AS o ON o.order_id    = oi.order_id
    JOIN products   AS p ON p.product_id  = oi.product_id
    JOIN categories AS c ON c.category_id = p.category_id
    WHERE o.order_date < rec_as_of()
    GROUP BY p.product_id, p.name, c.category_name
)
SELECT
    ROW_NUMBER() OVER (ORDER BY revenue DESC)               AS revenue_rank,
    product_name,
    category_name,
    ROUND(revenue, 2)                                       AS revenue,
    ROUND(100.0 * revenue / SUM(revenue) OVER (), 4)        AS pct_of_revenue,
    ROUND(
        100.0 * SUM(revenue) OVER (ORDER BY revenue DESC ROWS UNBOUNDED PRECEDING)
        / SUM(revenue) OVER (),
        2
    )                                                       AS cumulative_pct_of_revenue,
    ROUND(
        100.0 * ROW_NUMBER() OVER (ORDER BY revenue DESC) / COUNT(*) OVER (),
        2
    )                                                       AS cumulative_pct_of_catalogue
FROM product_revenue
ORDER BY revenue DESC
LIMIT 100;


/*
===============================================================================
 QUERY 19 | The top ten percent of customers
 Technique: PERCENT_RANK() in a CTE, filtered in the outer query
===============================================================================
 Window functions cannot appear in WHERE, because WHERE is evaluated before the
 window. Computing the percentile in a CTE and filtering outside it is the
 standard way around that, and the reason so many of these queries are layered.
*/
WITH customer_revenue AS (
    SELECT
        o.user_id,
        COUNT(DISTINCT o.order_id)  AS orders,
        SUM(o.total_amount)         AS revenue
    FROM orders AS o
    WHERE o.order_date < rec_as_of()
    GROUP BY o.user_id
),
ranked AS (
    SELECT
        cr.*,
        PERCENT_RANK() OVER (ORDER BY revenue) AS revenue_percentile,
        SUM(revenue)   OVER ()                 AS total_revenue
    FROM customer_revenue AS cr
)
SELECT
    COUNT(*)                                                AS top_decile_customers,
    ROUND(SUM(revenue), 2)                                  AS top_decile_revenue,
    ROUND(100.0 * SUM(revenue) / MAX(total_revenue), 2)     AS pct_of_all_revenue,
    ROUND(AVG(revenue), 2)                                  AS average_revenue_per_customer,
    ROUND(AVG(orders), 2)                                   AS average_orders_per_customer
FROM ranked
WHERE revenue_percentile >= 0.90;


/*
===============================================================================
 QUERY 20 | The conversion funnel, stage by stage
 Technique: a reference table join, with LAG() for stage over stage drop off
===============================================================================
 `interaction_weights.funnel_stage` supplies the ordering, so the stages sort
 correctly without a CASE expression repeating what the schema already knows.
*/
WITH stage_totals AS (
    SELECT
        iw.funnel_stage,
        i.interaction_type,
        COUNT(*)                    AS events,
        COUNT(DISTINCT i.user_id)   AS users,
        COUNT(DISTINCT i.product_id) AS products
    FROM user_interactions AS i
    JOIN interaction_weights AS iw ON iw.interaction_type = i.interaction_type
    WHERE i.interaction_timestamp < rec_as_of()
    GROUP BY iw.funnel_stage, i.interaction_type
)
SELECT
    funnel_stage,
    interaction_type,
    events,
    users,
    products,
    LAG(events) OVER (ORDER BY funnel_stage)                    AS previous_stage_events,
    ROUND(
        100.0 * events / NULLIF(LAG(events) OVER (ORDER BY funnel_stage), 0), 2
    )                                                           AS stage_conversion_pct,
    ROUND(
        100.0 * events / FIRST_VALUE(events) OVER (ORDER BY funnel_stage), 2
    )                                                           AS pct_of_top_of_funnel
FROM stage_totals
ORDER BY funnel_stage;


/*
===============================================================================
 QUERY 21 | Category crossover
 Technique: SELF JOIN on a per customer category summary
===============================================================================
 Which aisles share customers. This is the category level view of the same
 co occurrence idea the similarity matrix applies to products, and it is what
 merchandising uses to decide what to place next to what.
*/
WITH customer_categories AS (
    SELECT DISTINCT
        o.user_id,
        p.category_id,
        c.category_name
    FROM orders      AS o
    JOIN order_items AS oi ON oi.order_id   = o.order_id
    JOIN products    AS p  ON p.product_id  = oi.product_id
    JOIN categories  AS c  ON c.category_id = p.category_id
    WHERE o.order_date < rec_as_of()
),
category_customers AS (
    SELECT category_id, category_name, COUNT(*) AS customers
    FROM customer_categories
    GROUP BY category_id, category_name
)
SELECT
    a.category_name                                         AS category_a,
    b.category_name                                         AS category_b,
    COUNT(*)                                                AS shared_customers,
    ROUND(100.0 * COUNT(*) / ca.customers, 2)               AS pct_of_a_who_also_buy_b,
    ROUND(100.0 * COUNT(*) / cb.customers, 2)               AS pct_of_b_who_also_buy_a,
    ROUND(
        COUNT(*)::NUMERIC / NULLIF(ca.customers + cb.customers - COUNT(*), 0), 4
    )                                                       AS jaccard_overlap
FROM customer_categories AS a
JOIN customer_categories AS b
    ON  a.user_id     = b.user_id
    AND a.category_id < b.category_id
JOIN category_customers AS ca ON ca.category_id = a.category_id
JOIN category_customers AS cb ON cb.category_id = b.category_id
GROUP BY a.category_name, b.category_name, ca.customers, cb.customers
ORDER BY jaccard_overlap DESC;


/*
===============================================================================
 QUERY 22 | Price band performance
 Technique: WIDTH_BUCKET() over a log scale for even bucketing of skewed prices
===============================================================================
 Prices span three orders of magnitude, so linear buckets put almost everything
 in the first one. Bucketing the logarithm gives bands that each contain a
 useful number of products.
*/
WITH banded AS (
    SELECT
        p.product_id,
        p.name,
        c.category_name,
        p.price,
        WIDTH_BUCKET(LN(p.price), LN(5), LN(2600), 6) AS price_band
    FROM products AS p
    JOIN categories AS c ON c.category_id = p.category_id
)
SELECT
    b.price_band,
    ROUND(MIN(b.price), 2)                              AS band_min_price,
    ROUND(MAX(b.price), 2)                              AS band_max_price,
    COUNT(DISTINCT b.product_id)                        AS products,
    COALESCE(SUM(oi.quantity), 0)                       AS units_sold,
    ROUND(COALESCE(SUM(oi.quantity * oi.unit_price), 0), 2) AS revenue,
    ROUND(
        100.0 * COALESCE(SUM(oi.quantity * oi.unit_price), 0)
        / SUM(COALESCE(SUM(oi.quantity * oi.unit_price), 0)) OVER (),
        2
    )                                                   AS pct_of_revenue
FROM banded AS b
LEFT JOIN order_items AS oi ON oi.product_id = b.product_id
LEFT JOIN orders      AS o  ON o.order_id    = oi.order_id
                           AND o.order_date  < rec_as_of()
GROUP BY b.price_band
ORDER BY b.price_band;


/*
===============================================================================
 QUERY 23 | Brand performance inside each category
 Technique: two levels of window partitioning in one pass
===============================================================================
 Share within the category and rank within the category, computed over the same
 result set with different PARTITION BY clauses.
*/
WITH brand_revenue AS (
    SELECT
        c.category_name,
        p.brand,
        COUNT(DISTINCT p.product_id)                AS products,
        COUNT(DISTINCT o.user_id)                   AS customers,
        ROUND(SUM(oi.quantity * oi.unit_price), 2)  AS revenue,
        ROUND(AVG(p.rating), 2)                     AS average_rating
    FROM order_items AS oi
    JOIN orders     AS o ON o.order_id    = oi.order_id
    JOIN products   AS p ON p.product_id  = oi.product_id
    JOIN categories AS c ON c.category_id = p.category_id
    WHERE o.order_date < rec_as_of()
    GROUP BY c.category_name, p.brand
)
SELECT
    category_name,
    brand,
    products,
    customers,
    revenue,
    average_rating,
    RANK() OVER (PARTITION BY category_name ORDER BY revenue DESC) AS rank_in_category,
    ROUND(
        100.0 * revenue / SUM(revenue) OVER (PARTITION BY category_name), 2
    )                                                              AS share_of_category_pct,
    ROUND(
        revenue - AVG(revenue) OVER (PARTITION BY category_name), 2
    )                                                              AS revenue_vs_category_average
FROM brand_revenue
ORDER BY category_name, revenue DESC;


/*
===============================================================================
 QUERY 24 | New against returning revenue, by month
 Technique: FIRST_VALUE() to label each order relative to the customer's first
===============================================================================
 Splitting revenue into acquisition and retention is the single most useful cut
 of a monthly revenue line, and it needs no join: the first order date is
 already available as a window over the customer's own orders.
*/
WITH ordered AS (
    SELECT
        o.order_id,
        o.user_id,
        o.order_date,
        o.total_amount,
        FIRST_VALUE(o.order_date) OVER (
            PARTITION BY o.user_id ORDER BY o.order_date
        ) AS first_order_date
    FROM orders AS o
    WHERE o.order_date < rec_as_of()
)
SELECT
    DATE_TRUNC('month', order_date)::DATE                       AS month,
    COUNT(*) FILTER (WHERE order_date = first_order_date)       AS acquisition_orders,
    COUNT(*) FILTER (WHERE order_date > first_order_date)       AS returning_orders,
    ROUND(SUM(total_amount) FILTER (WHERE order_date = first_order_date), 2)
                                                                AS acquisition_revenue,
    ROUND(SUM(total_amount) FILTER (WHERE order_date > first_order_date), 2)
                                                                AS returning_revenue,
    ROUND(
        100.0 * SUM(total_amount) FILTER (WHERE order_date > first_order_date)
        / NULLIF(SUM(total_amount), 0),
        2
    )                                                           AS pct_revenue_from_returning
FROM ordered
GROUP BY DATE_TRUNC('month', order_date)
ORDER BY month;


/*
===============================================================================
 QUERY 25 | Days between orders, and who is overdue
 Technique: LAG() for the gap, then a comparison against the customer's own mean
===============================================================================
 A churn signal that needs no model: a customer who normally orders every three
 weeks and has not ordered in nine is behaving differently, and the threshold is
 personal rather than global.
*/
WITH gaps AS (
    SELECT
        o.user_id,
        o.order_date,
        LAG(o.order_date) OVER (PARTITION BY o.user_id ORDER BY o.order_date)
                                                            AS previous_order_date,
        EXTRACT(
            DAY FROM o.order_date
            - LAG(o.order_date) OVER (PARTITION BY o.user_id ORDER BY o.order_date)
        )::INTEGER                                          AS days_since_previous
    FROM orders AS o
    WHERE o.order_date < rec_as_of()
),
customer_cadence AS (
    SELECT
        user_id,
        COUNT(*) FILTER (WHERE days_since_previous IS NOT NULL) AS gaps_observed,
        ROUND(AVG(days_since_previous), 1)                      AS average_gap_days,
        ROUND(STDDEV_SAMP(days_since_previous), 1)              AS gap_stddev,
        MAX(order_date)                                         AS last_order_date
    FROM gaps
    GROUP BY user_id
)
SELECT
    cc.user_id,
    u.city,
    cc.gaps_observed + 1                                        AS orders,
    cc.average_gap_days,
    cc.gap_stddev,
    cc.last_order_date::DATE                                    AS last_order,
    EXTRACT(DAY FROM rec_as_of() - cc.last_order_date)::INTEGER AS days_since_last_order,
    ROUND(
        EXTRACT(DAY FROM rec_as_of() - cc.last_order_date)::NUMERIC
        / NULLIF(cc.average_gap_days, 0),
        2
    )                                                           AS cadence_multiple,
    CASE
        WHEN EXTRACT(DAY FROM rec_as_of() - cc.last_order_date)
             > cc.average_gap_days * 3 THEN 'at risk'
        WHEN EXTRACT(DAY FROM rec_as_of() - cc.last_order_date)
             > cc.average_gap_days * 2 THEN 'slipping'
        ELSE 'on cadence'
    END                                                         AS churn_signal
FROM customer_cadence AS cc
JOIN users AS u ON u.user_id = cc.user_id
WHERE cc.gaps_observed >= 4
ORDER BY cadence_multiple DESC
LIMIT 25;
