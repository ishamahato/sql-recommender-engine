/*
===============================================================================
 materialized_views.sql
===============================================================================
 WHY MATERIALIZE

 A recommendation request has a latency budget of a few milliseconds, and the
 work it depends on does not fit in that budget. The similarity matrix alone
 aggregates several million co occurrence pairs. Doing that per request would
 be absurd; doing it per request for every user on the site would melt the
 database.

 The split that makes this workable is the same one every production recommender
 uses, whether or not it calls it this:

   OFFLINE   expensive, runs on a schedule, reads the whole history.
             feature aggregation, similarity, popularity, taste model.

   ONLINE    cheap, runs per request, reads a handful of indexed rows.
             candidate lookup, filtering, scoring, ranking.

 Materialized views are how that split is expressed in PostgreSQL. They also
 give something a cache does not: the offline results are ordinary relations, so
 the online query can JOIN to them, filter them and rank against them inside the
 same execution plan, with real statistics and real indexes.

 Every matview here carries a UNIQUE index. That is not decoration. It is the
 precondition for REFRESH MATERIALIZED VIEW CONCURRENTLY, which rebuilds the
 view without taking an exclusive lock, so recommendations keep serving from the
 previous snapshot while the next one is built.
===============================================================================
*/

DROP MATERIALIZED VIEW IF EXISTS mv_product_similarity        CASCADE;
DROP MATERIALIZED VIEW IF EXISTS mv_product_trend             CASCADE;
DROP MATERIALIZED VIEW IF EXISTS mv_product_popularity        CASCADE;
DROP MATERIALIZED VIEW IF EXISTS mv_user_category_preferences CASCADE;
DROP MATERIALIZED VIEW IF EXISTS mv_user_product_features     CASCADE;

/*
===============================================================================
 1. mv_user_product_features
===============================================================================
 A straight snapshot of the feature view. It is the input to everything below,
 so materialising it first means the similarity build reads a compact
 pre aggregated relation instead of re scanning 300k raw interactions.
===============================================================================
*/
CREATE MATERIALIZED VIEW mv_user_product_features AS
SELECT * FROM user_product_features;

CREATE UNIQUE INDEX idx_mv_upf_pk
    ON mv_user_product_features (user_id, product_id);

/* Serves the anchor lookup: one user's strongest history items. */
CREATE INDEX idx_mv_upf_user_score
    ON mv_user_product_features (user_id, decayed_score DESC);

/* Serves the exclusion set: has this user already bought this product. */
CREATE INDEX idx_mv_upf_purchased
    ON mv_user_product_features (user_id, product_id)
    WHERE has_purchased;


/*
===============================================================================
 2. mv_user_category_preferences
===============================================================================
*/
CREATE MATERIALIZED VIEW mv_user_category_preferences AS
SELECT * FROM user_category_preferences;

CREATE UNIQUE INDEX idx_mv_ucp_pk
    ON mv_user_category_preferences (user_id, category_id);

/* Serves "the categories this user actually likes", the hot access pattern. */
CREATE INDEX idx_mv_ucp_user_rank
    ON mv_user_category_preferences (user_id, preference_rank);


/*
===============================================================================
 3. mv_product_popularity
===============================================================================
*/
CREATE MATERIALIZED VIEW mv_product_popularity AS
SELECT * FROM product_popularity;

CREATE UNIQUE INDEX idx_mv_pop_pk
    ON mv_product_popularity (product_id);

/* Serves the cold start path, which asks for the globally best live products. */
CREATE INDEX idx_mv_pop_rank
    ON mv_product_popularity (popularity_global_rank)
    WHERE is_active;

/* Serves the light user path, which asks for the best products in a category. */
CREATE INDEX idx_mv_pop_category_rank
    ON mv_product_popularity (category_id, popularity_category_rank)
    WHERE is_active;


/*
===============================================================================
 4. mv_product_trend
===============================================================================
 Momentum, which popularity alone cannot express. A product with 400 lifetime
 interactions and a product with 400 interactions acquired this month look
 identical to a counter and completely different to a merchandiser.

 LAG and LEAD do the work. Weekly engagement is put in order per product, LAG
 supplies the previous week for a growth ratio, and a four week trailing average
 smooths the noise that makes raw week over week ratios useless on low volume
 items.

 The final row per product is selected with ROW_NUMBER, which is the standard
 "latest row per group" idiom and avoids a correlated subquery over the same
 table.
===============================================================================
*/
CREATE MATERIALIZED VIEW mv_product_trend AS
WITH cfg AS (
    SELECT rec_as_of() AS as_of
),
weekly AS (
    SELECT
        i.product_id,
        DATE_TRUNC('week', i.interaction_timestamp) AS week_start,
        SUM(
            CASE i.interaction_type
                WHEN 'view'     THEN 1
                WHEN 'wishlist' THEN 3
                WHEN 'cart'     THEN 5
                WHEN 'purchase' THEN 10
                ELSE 0
            END
        )::NUMERIC AS weekly_engagement
    FROM user_interactions AS i
    CROSS JOIN cfg
    WHERE i.interaction_timestamp < cfg.as_of
      AND i.interaction_timestamp >= cfg.as_of - INTERVAL '16 weeks'
    GROUP BY i.product_id, DATE_TRUNC('week', i.interaction_timestamp)
),
windowed AS (
    SELECT
        product_id,
        week_start,
        weekly_engagement,
        LAG(weekly_engagement) OVER w   AS previous_week_engagement,
        LEAD(weekly_engagement) OVER w  AS next_week_engagement,
        AVG(weekly_engagement) OVER (
            PARTITION BY product_id
            ORDER BY week_start
            ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
        )                               AS trailing_4week_average,
        SUM(weekly_engagement) OVER (
            PARTITION BY product_id
            ORDER BY week_start
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                               AS cumulative_engagement,
        ROW_NUMBER() OVER (
            PARTITION BY product_id ORDER BY week_start DESC
        )                               AS recency_rank
    FROM weekly
    WINDOW w AS (PARTITION BY product_id ORDER BY week_start)
)
SELECT
    product_id,
    week_start                                          AS latest_week,
    weekly_engagement                                   AS latest_week_engagement,
    previous_week_engagement,
    ROUND(trailing_4week_average, 4)                    AS trailing_4week_average,
    cumulative_engagement,

    /* Growth against the smoothed baseline rather than against a single noisy
       week. 1.0 means flat, above 1.0 means accelerating. Capped at 5 so one
       product coming off a zero week cannot dominate the trending shelf. */
    LEAST(
        ROUND(
            weekly_engagement / NULLIF(trailing_4week_average, 0),
            4
        ),
        5.0
    )                                                   AS momentum,

    CASE
        WHEN previous_week_engagement IS NULL                       THEN 'new'
        WHEN weekly_engagement > previous_week_engagement * 1.25    THEN 'rising'
        WHEN weekly_engagement < previous_week_engagement * 0.75    THEN 'falling'
        ELSE                                                             'steady'
    END                                                 AS trend_direction
FROM windowed
WHERE recency_rank = 1;

CREATE UNIQUE INDEX idx_mv_trend_pk ON mv_product_trend (product_id);
CREATE INDEX idx_mv_trend_momentum  ON mv_product_trend (momentum DESC);


/*
===============================================================================
 5. mv_product_similarity
===============================================================================
 ITEM TO ITEM COLLABORATIVE FILTERING, COMPUTED ENTIRELY IN SQL.

 The premise: two products are similar if the same people engage with both.
 No product attributes are used. The catalogue text never enters this
 calculation, which is why it can discover that a yoga mat and a foam roller
 belong together when nothing in their descriptions says so.

 The whole thing is one self join on the user product feature table, plus the
 arithmetic that turns a raw co occurrence count into a defensible score.

 WHY NOT A RAW CO OCCURRENCE COUNT

 `COUNT(DISTINCT user_id)` over the self join is the naive version and it is
 wrong in a specific, predictable way: it ranks by popularity. The single best
 selling product in the catalogue co occurs with everything, so it becomes
 everybody's nearest neighbour and the recommender degenerates into a
 bestseller list. Normalisation is the fix.

 COSINE SIMILARITY

 Treat each product as a vector over users, where the coordinate is that user's
 engagement with it:

     cosine(a, b) = dot(a, b) / (norm(a) * norm(b))

 Dividing by both norms removes the popularity term. It measures the angle
 between the two vectors, not their length, so a niche product with 40 devoted
 buyers can be a closer neighbour than a bestseller with 4000 casual viewers.

 JACCARD SIMILARITY

 Kept alongside it as a set overlap sanity check:

     jaccard(a, b) = |users(a) AND users(b)| / |users(a) OR users(b)|

 Jaccard ignores intensity and only asks how much the audiences overlap. When
 the two metrics disagree sharply the pair is usually an artefact, so having
 both is what makes the matrix auditable rather than a black box.

 THREE OPTIMISATIONS THAT MAKE THIS TRACTABLE

 1. Log damping of the engagement weight. A user who viewed one product 60
    times would otherwise dominate every pair they touch. ln(1 + score)
    compresses that without discarding the ordering.

 2. Activity capping. The self join is quadratic in items per user, so a single
    user with 800 interactions contributes 640k pairs on their own. ROW_NUMBER
    keeps each user's strongest N items and drops the tail. This is the single
    biggest cost control in the file.

 3. Triangular join. `a.product_id < b.product_id` computes each unordered pair
    once instead of twice, halving the aggregation, and the mirrored half is
    restored afterwards with a UNION ALL over the already aggregated result.

 The `min_common_users` floor removes pairs supported by one or two people,
 which are noise rather than signal, and the per product neighbour cap keeps the
 matrix a bounded size regardless of catalogue growth.
===============================================================================
*/
CREATE MATERIALIZED VIEW mv_product_similarity AS
WITH cfg AS (
    SELECT
        rec_setting('min_common_users')         AS min_common_users,
        rec_setting('max_anchors_per_user')     AS max_items_per_user,
        rec_setting('max_neighbours_per_item')  AS max_neighbours_per_item
),
/* Step 1: the engagement signal, log damped. */
signals AS (
    SELECT
        f.user_id,
        f.product_id,
        LN(1 + f.decayed_score) AS weight
    FROM mv_user_product_features AS f
    WHERE f.decayed_score > 0
),
/* Step 2: cap each user's contribution to their strongest items. */
capped AS (
    SELECT user_id, product_id, weight
    FROM (
        SELECT
            s.*,
            ROW_NUMBER() OVER (
                PARTITION BY s.user_id ORDER BY s.weight DESC, s.product_id
            ) AS item_rank
        FROM signals AS s
    ) AS ranked
    CROSS JOIN cfg
    WHERE ranked.item_rank <= cfg.max_items_per_user
),
/* Step 3: vector lengths and audience sizes, one row per product. */
norms AS (
    SELECT
        product_id,
        SQRT(SUM(weight * weight)) AS vector_norm,
        COUNT(*)                   AS audience_size
    FROM capped
    GROUP BY product_id
),
/* Step 4: THE SELF JOIN. Every pair of products touched by the same user. */
pairs AS (
    SELECT
        a.product_id            AS product_a,
        b.product_id            AS product_b,
        COUNT(*)                AS common_users,
        SUM(a.weight * b.weight) AS dot_product
    FROM capped AS a
    JOIN capped AS b
        ON  a.user_id     = b.user_id
        AND a.product_id  < b.product_id
    CROSS JOIN cfg
    GROUP BY a.product_id, b.product_id, cfg.min_common_users
    HAVING COUNT(*) >= cfg.min_common_users
),
/* Step 5: normalise the raw overlap into comparable similarity metrics. */
scored AS (
    SELECT
        p.product_a,
        p.product_b,
        p.common_users,
        ROUND(p.dot_product / NULLIF(na.vector_norm * nb.vector_norm, 0), 6) AS cosine_similarity,
        ROUND(
            p.common_users::NUMERIC
            / NULLIF(na.audience_size + nb.audience_size - p.common_users, 0),
            6
        )                                                                    AS jaccard_similarity
    FROM pairs AS p
    JOIN norms AS na ON na.product_id = p.product_a
    JOIN norms AS nb ON nb.product_id = p.product_b
),
/* Step 6: restore the mirrored half of the matrix. SYMMETRIC is a reserved
   word in PostgreSQL, hence the name. */
mirrored AS (
    SELECT product_a, product_b, common_users, cosine_similarity, jaccard_similarity FROM scored
    UNION ALL
    SELECT product_b, product_a, common_users, cosine_similarity, jaccard_similarity FROM scored
),
/* Step 7: keep only the strongest neighbours per product. */
ranked AS (
    SELECT
        s.*,
        ROW_NUMBER() OVER (
            PARTITION BY s.product_a ORDER BY s.cosine_similarity DESC, s.product_b
        ) AS neighbour_rank
    FROM mirrored AS s
)
SELECT
    r.product_a,
    r.product_b,
    r.common_users,
    r.cosine_similarity,
    r.jaccard_similarity,
    r.cosine_similarity AS similarity_score,
    r.neighbour_rank,
    /* Two levels of "same aisle", because they answer different questions.
       Same subcategory means the pair are substitutes, two headphones competing
       for one slot in the basket. Same category but different subcategory means
       they are complements, headphones and a phone case. The product to product
       shelf needs to tell those apart, and the category alone cannot: every
       gadget in the store shares the Electronics category. */
    (pa.subcategory = pb.subcategory) AS same_subcategory,
    (pa.category_id = pb.category_id) AS same_category
FROM ranked AS r
CROSS JOIN cfg
JOIN products AS pa ON pa.product_id = r.product_a
JOIN products AS pb ON pb.product_id = r.product_b
WHERE r.neighbour_rank <= cfg.max_neighbours_per_item;

CREATE UNIQUE INDEX idx_mv_sim_pk
    ON mv_product_similarity (product_a, product_b);

/* THE index for candidate generation: given the user's history items, walk
   straight to their best neighbours in similarity order. */
CREATE INDEX idx_mv_sim_lookup
    ON mv_product_similarity (product_a, similarity_score DESC)
    INCLUDE (product_b, common_users);


/*
===============================================================================
 Refresh orchestration
===============================================================================
 Dependency order matters: features feed the taste model and the similarity
 matrix, so they rebuild first.

 This function uses plain REFRESH, not CONCURRENTLY, because a function body
 runs inside a transaction and PostgreSQL forbids CONCURRENTLY there. That is
 the right choice for the two cases this function serves: the initial build, and
 the evaluation replay, where nothing is serving traffic anyway.

 The production path is the opposite: python/pipeline.py issues CONCURRENTLY
 statements in autocommit mode, outside any transaction, so live requests keep
 reading the previous snapshot while the next one builds.
===============================================================================
*/
CREATE OR REPLACE FUNCTION refresh_recommendation_layer()
RETURNS TABLE (layer TEXT, rows_loaded BIGINT, elapsed_seconds NUMERIC)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start     TIMESTAMP;
    v_layer     TEXT;
    v_layers    TEXT[] := ARRAY[
        'mv_user_product_features',
        'mv_user_category_preferences',
        'mv_product_popularity',
        'mv_product_trend',
        'mv_product_similarity'
    ];
BEGIN
    FOREACH v_layer IN ARRAY v_layers LOOP
        v_start := clock_timestamp();
        EXECUTE FORMAT('REFRESH MATERIALIZED VIEW %I', v_layer);
        EXECUTE FORMAT('ANALYZE %I', v_layer);

        layer := v_layer;
        EXECUTE FORMAT('SELECT COUNT(*) FROM %I', v_layer) INTO rows_loaded;
        elapsed_seconds := ROUND(
            EXTRACT(EPOCH FROM (clock_timestamp() - v_start))::NUMERIC, 3
        );
        RETURN NEXT;
    END LOOP;

    UPDATE pipeline_state SET last_refreshed_at = clock_timestamp();
END;
$$;

/*
 Move the pipeline cutoff and rebuild everything behind it.

 This is the leakage control for evaluation. Calling it with a past timestamp
 makes every view, every matview, every similarity score and every popularity
 rank behave as though the data after that instant had never been recorded.
*/
CREATE OR REPLACE FUNCTION set_pipeline_as_of(
    p_as_of TIMESTAMP,
    p_mode  TEXT DEFAULT 'evaluation'
)
RETURNS TIMESTAMP
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE pipeline_state
       SET as_of_timestamp = p_as_of,
           mode            = p_mode;

    PERFORM refresh_recommendation_layer();

    RETURN p_as_of;
END;
$$;
