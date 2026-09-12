/*
===============================================================================
 views.sql
===============================================================================
 The feature layer. Three views turn the raw interaction log into the three
 things a ranker needs: what each user thinks of each product, what each user
 thinks of each category, and what the crowd thinks of each product.

 These are plain views on purpose. They are the readable definition of the
 feature semantics, they are always correct with respect to the current cutoff,
 and materialized_views.sql caches each one under an `mv_` name for the serving
 path. Read the logic here; query the `mv_` copies at runtime.

 Every view is bounded by `rec_as_of()`. No view calls `now()`. Recency is
 always measured against the cutoff, never against the wall clock, so a refresh
 today and a replay of last quarter produce the same numbers.
===============================================================================
*/

/*
===============================================================================
 1. user_product_features
===============================================================================
 Grain: one row per (user_id, product_id) the user has touched.

 The interaction score is the weighted funnel: a purchase says ten times more
 about intent than a view. The CASE is written out rather than joined to
 `interaction_weights` so that the single most important scoring rule in the
 system is visible at the point of use; the table carries the same numbers for
 analytics that need them relationally.

 `decayed_score` is the same sum with an exponential half life applied. The
 ranker uses the decayed form, because a basket abandoned last week is a much
 stronger signal than one abandoned last year. The raw score is kept alongside
 it for analytics and for the interview conversation about why they differ.
===============================================================================
*/
CREATE OR REPLACE VIEW user_product_features AS
SELECT
    i.user_id,
    i.product_id,

    COUNT(*) FILTER (WHERE i.interaction_type = 'view')     AS view_count,
    COUNT(*) FILTER (WHERE i.interaction_type = 'wishlist') AS wishlist_count,
    COUNT(*) FILTER (WHERE i.interaction_type = 'cart')     AS cart_count,
    COUNT(*) FILTER (WHERE i.interaction_type = 'purchase') AS purchase_count,
    COUNT(*)                                                AS interaction_count,

    MIN(i.interaction_timestamp)                            AS first_interaction,
    MAX(i.interaction_timestamp)                            AS last_interaction,

    /* Whole days between the most recent touch and the pipeline cutoff. */
    FLOOR(
        EXTRACT(EPOCH FROM (cfg.as_of - MAX(i.interaction_timestamp))) / 86400.0
    )::INTEGER                                              AS days_since_interaction,

    /* The weighted funnel score. */
    SUM(
        CASE i.interaction_type
            WHEN 'view'     THEN 1
            WHEN 'wishlist' THEN 3
            WHEN 'cart'     THEN 5
            WHEN 'purchase' THEN 10
            ELSE 0
        END
    )                                                       AS interaction_score,

    /* The same funnel score with exponential recency decay applied per event. */
    ROUND(
        SUM(
            CASE i.interaction_type
                WHEN 'view'     THEN 1
                WHEN 'wishlist' THEN 3
                WHEN 'cart'     THEN 5
                WHEN 'purchase' THEN 10
                ELSE 0
            END
            * rec_decay(i.interaction_timestamp, cfg.as_of, cfg.affinity_half_life)
        ),
        4
    )                                                       AS decayed_score,

    /* Cheap boolean the ranker uses to build its exclusion set. */
    BOOL_OR(i.interaction_type = 'purchase')                AS has_purchased

FROM user_interactions AS i
CROSS JOIN LATERAL (
    SELECT
        rec_as_of()                        AS as_of,
        rec_setting('affinity_half_life')  AS affinity_half_life
) AS cfg
WHERE i.interaction_timestamp < cfg.as_of
GROUP BY i.user_id, i.product_id, cfg.as_of;


/*
===============================================================================
 2. user_category_preferences
===============================================================================
 Grain: one row per (user_id, category_id) the user has engaged with.

 This is the taste model. It answers "which aisles does this shopper live in",
 and it is what keeps recommendations coherent when collaborative filtering
 returns a thin or noisy candidate set.

 Three ranking functions appear here because they answer three different
 questions, and the difference is worth being able to explain:

   ROW_NUMBER()  arbitrary but unique; used to pick exactly one favourite
                 category per user with no tie ambiguity.
   RANK()        ties share a rank and leave a gap; the honest answer to
                 "is this a joint favourite".
   DENSE_RANK()  ties share a rank with no gap; used to take "the top three
                 preference levels" rather than the top three rows.

 `category_affinity` is the share of the user's decayed engagement that lands
 in this category. It is already normalised to 0 through 1 and sums to 1 per
 user, so the ranker can blend it without rescaling.
===============================================================================
*/
CREATE OR REPLACE VIEW user_category_preferences AS
WITH category_engagement AS (
    SELECT
        f.user_id,
        p.category_id,
        c.category_name,
        SUM(f.interaction_score)                    AS interaction_score,
        SUM(f.decayed_score)                        AS decayed_score,
        SUM(f.purchase_count)                       AS purchase_count,
        COUNT(DISTINCT f.product_id)                AS distinct_products,
        MAX(f.last_interaction)                     AS last_interaction
    FROM user_product_features AS f
    JOIN products   AS p ON p.product_id  = f.product_id
    JOIN categories AS c ON c.category_id = p.category_id
    GROUP BY f.user_id, p.category_id, c.category_name
)
SELECT
    user_id,
    category_id,
    category_name,
    interaction_score,
    decayed_score,
    purchase_count,
    distinct_products,
    last_interaction,

    /* Share of this user's total decayed engagement. Sums to 1 per user. */
    ROUND(
        decayed_score / NULLIF(SUM(decayed_score) OVER (PARTITION BY user_id), 0),
        4
    )                                               AS category_affinity,

    ROW_NUMBER() OVER (
        PARTITION BY user_id ORDER BY decayed_score DESC, category_id
    )                                               AS preference_rank,

    RANK() OVER (
        PARTITION BY user_id ORDER BY decayed_score DESC
    )                                               AS preference_rank_with_ties,

    DENSE_RANK() OVER (
        PARTITION BY user_id ORDER BY decayed_score DESC
    )                                               AS preference_tier,

    /* Where this category sits in the user's own distribution, 0 is weakest
       and 1 is strongest. Useful when a user engages with twenty categories
       and a raw rank of 4 means something very different than it does for a
       user with three. */
    ROUND(
        PERCENT_RANK() OVER (PARTITION BY user_id ORDER BY decayed_score)::NUMERIC,
        4
    )                                               AS affinity_percentile
FROM category_engagement;


/*
===============================================================================
 3. product_popularity
===============================================================================
 Grain: one row per product in the catalogue, including products nobody has
 touched yet, so cold catalogue items still receive a score instead of
 disappearing from the ranker.

 Popularity is deliberately not a purchase count. A raw count rewards whatever
 has been on the site longest and never decays, which is how a recommender ends
 up showing last year's bestseller forever. Three corrections are applied:

   1. Funnel weighting.   purchases 10, carts 5, wishlists 3, views 1.
   2. Exponential decay.  every event is discounted by its age against the
                          cutoff with a 30 day half life.
   3. Bayesian ratings.   a 5.0 from two people should not outrank a 4.6 from
                          four hundred, so the mean is shrunk toward the global
                          mean by a prior worth `m` votes.

 The output `popularity_score` is a PERCENT_RANK over the decayed engagement,
 which puts it on the same 0 to 1 footing as category affinity without any
 hand tuned constant.
===============================================================================
*/
CREATE OR REPLACE VIEW product_popularity AS
WITH cfg AS (
    SELECT
        rec_as_of()                         AS as_of,
        rec_setting('popularity_half_life') AS popularity_half_life
),
engagement AS (
    SELECT
        i.product_id,
        COUNT(*) FILTER (WHERE i.interaction_type = 'view')     AS view_count,
        COUNT(*) FILTER (WHERE i.interaction_type = 'wishlist') AS wishlist_count,
        COUNT(*) FILTER (WHERE i.interaction_type = 'cart')     AS cart_count,
        COUNT(*) FILTER (WHERE i.interaction_type = 'purchase') AS purchase_count,
        COUNT(DISTINCT i.user_id)                               AS unique_users,
        MAX(i.interaction_timestamp)                            AS last_interaction,

        /* Undecayed funnel weight, the number most people mean by popularity. */
        SUM(
            CASE i.interaction_type
                WHEN 'view'     THEN 1
                WHEN 'wishlist' THEN 3
                WHEN 'cart'     THEN 5
                WHEN 'purchase' THEN 10
                ELSE 0
            END
        )                                                       AS raw_engagement,

        /* Same weights, discounted by age. This is what actually ranks. */
        SUM(
            CASE i.interaction_type
                WHEN 'view'     THEN 1
                WHEN 'wishlist' THEN 3
                WHEN 'cart'     THEN 5
                WHEN 'purchase' THEN 10
                ELSE 0
            END
            * rec_decay(i.interaction_timestamp, cfg.as_of, cfg.popularity_half_life)
        )                                                       AS decayed_engagement
    FROM user_interactions AS i
    CROSS JOIN cfg
    WHERE i.interaction_timestamp < cfg.as_of
    GROUP BY i.product_id
),
rating_summary AS (
    SELECT
        r.product_id,
        AVG(r.rating)::NUMERIC(4, 3) AS avg_rating,
        COUNT(*)                     AS rating_count
    FROM ratings AS r
    CROSS JOIN cfg
    WHERE r.created_at < cfg.as_of
    GROUP BY r.product_id
),
/* Prior for the Bayesian shrink: the catalogue wide mean, and a prior strength
   equal to the median number of ratings a product carries. */
rating_prior AS (
    SELECT
        COALESCE(AVG(avg_rating), 3.5)                                            AS global_mean,
        GREATEST(COALESCE(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY rating_count)::NUMERIC, 10), 5) AS prior_votes
    FROM rating_summary
),
combined AS (
    SELECT
        p.product_id,
        p.name                                  AS product_name,
        p.category_id,
        c.category_name,
        p.subcategory,
        p.brand,
        p.price,
        p.is_active,

        COALESCE(e.view_count, 0)               AS view_count,
        COALESCE(e.wishlist_count, 0)           AS wishlist_count,
        COALESCE(e.cart_count, 0)               AS cart_count,
        COALESCE(e.purchase_count, 0)           AS purchase_count,
        COALESCE(e.unique_users, 0)             AS unique_users,
        COALESCE(e.raw_engagement, 0)           AS raw_engagement,
        ROUND(COALESCE(e.decayed_engagement, 0), 4) AS decayed_engagement,
        e.last_interaction,

        COALESCE(rs.rating_count, 0)            AS rating_count,
        rs.avg_rating,

        /* Bayesian average: (v * R + m * C) / (v + m). */
        ROUND(
            (
                COALESCE(rs.rating_count, 0) * COALESCE(rs.avg_rating, rp.global_mean)
                + rp.prior_votes * rp.global_mean
            ) / (COALESCE(rs.rating_count, 0) + rp.prior_votes),
            4
        )                                       AS smoothed_rating,

        /* Conversion quality, used by analytics and as a tie breaker. */
        ROUND(
            COALESCE(e.purchase_count, 0)::NUMERIC / NULLIF(e.view_count, 0),
            4
        )                                       AS view_to_purchase_rate,

        FLOOR(
            EXTRACT(EPOCH FROM (cfg.as_of - e.last_interaction)) / 86400.0
        )::INTEGER                              AS days_since_last_interaction,

        /* Catalogue level freshness on the same half life as popularity. */
        ROUND(
            COALESCE(rec_decay(e.last_interaction, cfg.as_of, cfg.popularity_half_life), 0),
            4
        )                                       AS recency_score
    FROM products AS p
    CROSS JOIN cfg
    CROSS JOIN rating_prior AS rp
    JOIN categories AS c   ON c.category_id = p.category_id
    LEFT JOIN engagement AS e      ON e.product_id  = p.product_id
    LEFT JOIN rating_summary AS rs ON rs.product_id = p.product_id
)
SELECT
    combined.*,

    /* Normalised popularity on 0 to 1. PERCENT_RANK rather than a min max
       scale because engagement is heavily right skewed: one runaway bestseller
       would otherwise compress every other product into the bottom decile. */
    ROUND(
        PERCENT_RANK() OVER (ORDER BY decayed_engagement)::NUMERIC,
        4
    )                                           AS popularity_score,

    ROW_NUMBER() OVER (ORDER BY decayed_engagement DESC, product_id)
                                                AS popularity_global_rank,

    RANK() OVER (PARTITION BY category_id ORDER BY decayed_engagement DESC)
                                                AS popularity_category_rank,

    /* Quartile label, used by the dashboard and by the popularity bias check. */
    CASE NTILE(4) OVER (ORDER BY decayed_engagement DESC)
        WHEN 1 THEN 'head'
        WHEN 2 THEN 'upper_torso'
        WHEN 3 THEN 'lower_torso'
        ELSE        'long_tail'
    END                                         AS demand_tier
FROM combined;
