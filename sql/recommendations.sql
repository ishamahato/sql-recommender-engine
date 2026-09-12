/*
===============================================================================
 recommendations.sql
===============================================================================
 THE RANKER. This is the file to read first.

 Everything above it is preparation. views.sql turned the interaction log into
 features, materialized_views.sql cached them and computed the item to item
 similarity matrix. This file is the part that runs per request, and it is a
 complete recommender: candidate generation, business rule filtering, multi
 signal scoring, ranking and explanation, expressed as one multi stage CTE
 pipeline.

     user history
          |
     similar products          via mv_product_similarity, the SQL CF matrix
          |
     candidate products        plus category and trending sources
          |
     remove purchased          anti join, plus the live catalogue filter
          |
     score                     five normalised signals, weights from rec_config
          |
     RANK()
          |
     top N
===============================================================================
*/

/*
===============================================================================
 user_recommendation_profile
===============================================================================
 Which of the three cold start regimes a user falls into, decided in SQL rather
 than by an `if` statement in the application. Putting it in a view means the
 API, the dashboard, the evaluation harness and the ranker itself all agree on
 what "new user" means, because they all read the same definition.
===============================================================================
*/
CREATE OR REPLACE VIEW user_recommendation_profile AS
SELECT
    u.user_id,
    u.signup_date,
    COALESCE(f.distinct_products, 0)    AS distinct_products,
    COALESCE(f.total_interactions, 0)   AS total_interactions,
    COALESCE(f.purchased_products, 0)   AS purchased_products,
    f.last_activity,
    COALESCE(c.distinct_categories, 0)  AS distinct_categories,

    CASE
        WHEN COALESCE(f.distinct_products, 0) < rec_setting('cold_start_threshold')
            THEN 'cold'
        WHEN COALESCE(f.distinct_products, 0) < rec_setting('light_user_threshold')
            THEN 'light'
        ELSE 'warm'
    END                                 AS user_tier
FROM users AS u
LEFT JOIN (
    SELECT
        user_id,
        COUNT(*)                                        AS distinct_products,
        SUM(interaction_count)                          AS total_interactions,
        COUNT(*) FILTER (WHERE has_purchased)           AS purchased_products,
        MAX(last_interaction)                           AS last_activity
    FROM mv_user_product_features
    GROUP BY user_id
) AS f ON f.user_id = u.user_id
LEFT JOIN (
    SELECT user_id, COUNT(*) AS distinct_categories
    FROM mv_user_category_preferences
    GROUP BY user_id
) AS c ON c.user_id = u.user_id;


/*
===============================================================================
 get_trending_products
===============================================================================
 The cold start engine and the last resort fallback.

 Trending is not the same as popular. Popularity is a decayed volume measure;
 momentum from mv_product_trend is the derivative. Multiplying them surfaces
 products that are both substantial and accelerating, which is the right answer
 for a visitor about whom nothing at all is known.

 The Bayesian smoothed rating is folded in so that a product trending purely on
 curiosity traffic does not outrank one people actually like.
===============================================================================
*/
CREATE OR REPLACE FUNCTION get_trending_products(p_limit INTEGER DEFAULT 10)
RETURNS TABLE (
    product_id      INTEGER,
    product_name    TEXT,
    category        TEXT,
    price           NUMERIC,
    trending_score  NUMERIC,
    trend_direction TEXT
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        pop.product_id,
        pop.product_name,
        pop.category_name,
        pop.price,
        ROUND(
            pop.popularity_score
            * COALESCE(tr.momentum, 1.0)
            * (pop.smoothed_rating / 5.0),
            6
        )                                   AS trending_score,
        COALESCE(tr.trend_direction, 'steady')
    FROM mv_product_popularity AS pop
    LEFT JOIN mv_product_trend AS tr ON tr.product_id = pop.product_id
    WHERE pop.is_active
    ORDER BY trending_score DESC, pop.product_id
    LIMIT p_limit;
$$;


/*
===============================================================================
 get_recommendations
===============================================================================
 THE MAIN QUERY.

 Signature:  get_recommendations(user_id, limit)

 Reads:      mv_product_similarity          collaborative evidence
             mv_user_product_features       the user's own history
             mv_user_category_preferences   the user's taste model
             mv_product_popularity          crowd signal, ratings, recency
             mv_product_trend               momentum
             rec_config                     the scoring weights

 SCORING

     recommendation_score =
           0.50 * collaborative_similarity
         + 0.20 * category_affinity
         + 0.15 * popularity
         + 0.10 * product_rating
         + 0.05 * recency

 Every one of those five terms is normalised to 0 through 1 inside the
 candidate set before the blend, with min max scaling in a window function. The
 normalisation is the part that matters: raw cosine similarity lives around
 0.02 to 0.4, popularity is already a percentile, and ratings run 1 to 5. Blend
 them unnormalised and the weights mean nothing at all, because the largest raw
 scale silently wins regardless of what the coefficients say.

 Scaling within the candidate set rather than catalogue wide is deliberate. The
 question being answered is "which of these 2000 candidates is best for this
 user", not "where does this product sit in the catalogue", so the contrast that
 matters is the contrast among the candidates in front of us.

 The weights come from rec_config, so retuning the ranker or running an A/B arm
 is an UPDATE rather than a deploy.

 COLD START is handled by which sources contribute candidates, not by a
 separate code path. A warm user's pool is dominated by collaborative
 neighbours; a cold user has no history, so the collaborative and category
 stages contribute nothing and the trending stage supplies the whole pool. The
 same scoring and ranking code then runs over whatever arrived.
===============================================================================
*/
CREATE OR REPLACE FUNCTION get_recommendations(
    p_user_id   INTEGER,
    p_limit     INTEGER DEFAULT 10
)
RETURNS TABLE (
    user_id                 INTEGER,
    product_id              INTEGER,
    product_name            TEXT,
    category                TEXT,
    price                   NUMERIC,
    recommendation_score    NUMERIC,
    recommendation_reason   TEXT,
    strategy                TEXT,
    recommendation_rank     INTEGER
)
LANGUAGE plpgsql
STABLE
AS $$
#variable_conflict use_column
BEGIN

RETURN QUERY
WITH
/* Stage 0: the scoring weights, read once and carried through the pipeline. */
cfg AS (
    SELECT
        rec_setting('weight_similarity')        AS w_similarity,
        rec_setting('weight_category')          AS w_category,
        rec_setting('weight_popularity')        AS w_popularity,
        rec_setting('weight_rating')            AS w_rating,
        rec_setting('weight_recency')           AS w_recency,
        rec_setting('max_anchors_per_user')     AS max_anchors,
        rec_setting('reason_similarity_cut')    AS reason_similarity_cut,
        rec_setting('reason_affinity_cut')      AS reason_affinity_cut,
        rec_setting('reason_popularity_cut')    AS reason_popularity_cut
),

/* Stage 1: which cold start regime this user is in. */
profile AS (
    SELECT COALESCE(
        (SELECT prof.user_tier FROM user_recommendation_profile AS prof
          WHERE prof.user_id = p_user_id),
        'cold'
    ) AS user_tier
),

/*
 Stage 2: ANCHORS. The user's own history, strongest first, capped.

 The cap bounds the work: without it a power user with 600 touched products
 would seed 600 similarity lookups per request. The normalised weight makes
 each anchor's vote proportional to how much the user actually engaged with it,
 so a product they bought counts for far more than one they glanced at.
*/
anchors AS (
    SELECT
        f.product_id,
        f.decayed_score,
        f.decayed_score / NULLIF(SUM(f.decayed_score) OVER (), 0) AS anchor_weight
    FROM (
        SELECT upf.product_id, upf.decayed_score
        FROM mv_user_product_features AS upf
        CROSS JOIN cfg
        WHERE upf.user_id = p_user_id
          AND upf.decayed_score > 0
        ORDER BY upf.decayed_score DESC
        LIMIT (SELECT max_anchors::INTEGER FROM cfg)
    ) AS f
),

/*
 Stage 3: EXCLUSION SET. Everything the user has already bought.

 Taken from both the behavioural log and the order ledger. They should agree,
 and a UNION of the two costs nothing and means a recommendation can never slip
 through on a discrepancy between them.

 The `order_date < rec_as_of()` predicate is not optional, and leaving it out is
 a mistake worth describing because it is easy to make and hard to spot.
 `mv_user_product_features` is already bounded by the cutoff, so the first arm of
 the union is safe by construction. The second arm reads a base table directly,
 and without the cutoff it sees the whole ledger including orders placed after
 the cutoff. During a temporal replay that turns the exclusion set into a list of
 exactly the products the user is about to buy, and the ranker then filters out
 every single correct answer. The first version of this file did that and scored
 a clean zero on every accuracy metric while the collaborative baseline scored
 normally, which is what exposed it.

 The general rule: anything reading a base table rather than an `mv_` view has
 to apply the cutoff itself.
*/
purchased AS (
    SELECT upf.product_id
    FROM mv_user_product_features AS upf
    WHERE upf.user_id = p_user_id
      AND upf.has_purchased
    UNION
    SELECT oi.product_id
    FROM orders AS o
    JOIN order_items AS oi ON oi.order_id = o.order_id
    WHERE o.user_id = p_user_id
      AND o.order_date < rec_as_of()
),

/*
 Stage 4a: COLLABORATIVE CANDIDATES.

 The heart of it. Every anchor is looked up in the similarity matrix and its
 neighbours are collected, with each neighbour's evidence weighted by how
 strongly the user engaged with the anchor that suggested it.

     cf_score(candidate) = SUM over anchors of similarity(anchor, candidate)
                                                * anchor_weight(anchor)

 A candidate reached from five different anchors therefore scores well above
 one reached from a single weak anchor, which is exactly the desired behaviour:
 agreement across the user's history is stronger evidence than one coincidence.

 ARRAY_AGG with an ORDER BY inside it captures which anchor contributed most,
 so the explanation can name a concrete product the user already owns instead
 of saying "based on your activity".
*/
cf_candidates AS (
    SELECT
        sim.product_b                       AS product_id,
        SUM(sim.similarity_score * a.anchor_weight) AS cf_score,
        MAX(sim.similarity_score)           AS best_similarity,
        COUNT(*)                            AS supporting_anchors,
        MAX(sim.common_users)               AS peak_common_users,
        (ARRAY_AGG(a.product_id ORDER BY sim.similarity_score * a.anchor_weight DESC))[1]
                                            AS top_anchor_product_id
    FROM anchors AS a
    JOIN mv_product_similarity AS sim ON sim.product_a = a.product_id
    GROUP BY sim.product_b
),

/*
 Stage 4b: CATEGORY CANDIDATES.

 Collaborative filtering is blind to anything nobody has co engaged with yet,
 and for a light user the matrix has almost nothing to say. Pulling the best
 products from the user's top three categories keeps the pool populated and
 keeps the result coherent with their demonstrated taste.
*/
category_candidates AS (
    SELECT
        pop.product_id,
        prefs.category_affinity
    FROM mv_user_category_preferences AS prefs
    JOIN mv_product_popularity AS pop ON pop.category_id = prefs.category_id
    WHERE prefs.user_id = p_user_id
      AND prefs.preference_rank <= 3
      AND pop.popularity_category_rank <= 25
      AND pop.is_active
),

/*
 Stage 4c: TRENDING CANDIDATES.

 Only for users the other two stages cannot serve. For a warm user these would
 be noise, and worse, they would bias the whole shelf toward the head of the
 catalogue.

 The tier test is pushed into the function's own LIMIT rather than left as a
 WHERE clause on its output. A set returning function in a CROSS JOIN is
 evaluated before any filter above it can discard the rows, so the WHERE version
 paid for the full trending computation on every warm user request and then
 threw it away. Passing a limit of zero makes the executor return from the Limit
 node without pulling a single row.
*/
trending_candidates AS (
    SELECT t.product_id
    FROM profile
    CROSS JOIN LATERAL get_trending_products(
        CASE WHEN profile.user_tier IN ('cold', 'light') THEN 200 ELSE 0 END
    ) AS t
),

/* Stage 5: POOL. One row per distinct candidate, tagged with its origin. */
candidate_pool AS (
    SELECT cf.product_id, 'collaborative'::TEXT AS source FROM cf_candidates AS cf
    UNION
    SELECT cc.product_id, 'category'::TEXT      FROM category_candidates AS cc
    UNION
    SELECT tc.product_id, 'trending'::TEXT      FROM trending_candidates AS tc
),
candidates AS (
    SELECT
        cp.product_id,
        /* Collaborative evidence outranks the other origins when a product was
           found by more than one route. */
        MIN(
            CASE cp.source
                WHEN 'collaborative' THEN 1
                WHEN 'category'      THEN 2
                ELSE                      3
            END
        ) AS source_priority
    FROM candidate_pool AS cp
    GROUP BY cp.product_id
),

/*
 Stage 6: FILTER, then enrich.

 The anti join against `purchased` is the one business rule that is never
 negotiable: recommending someone the toaster they bought last week is the
 classic way to make a recommender look broken. `is_active` does the same job
 for withdrawn stock, and doing it here rather than in the application means an
 out of stock product cannot reach a caller that forgot to check.
*/
filtered AS (
    SELECT
        c.product_id,
        c.source_priority,
        p.name                                      AS product_name,
        pop.category_name,
        p.price,
        COALESCE(cf.cf_score, 0)                    AS cf_score,
        COALESCE(cf.best_similarity, 0)             AS best_similarity,
        COALESCE(cf.supporting_anchors, 0)          AS supporting_anchors,
        cf.top_anchor_product_id,
        COALESCE(prefs.category_affinity, 0)        AS category_affinity,
        prefs.preference_rank,
        pop.popularity_score,
        pop.smoothed_rating,
        pop.recency_score,
        pop.demand_tier,
        pop.popularity_category_rank,
        COALESCE(tr.momentum, 1.0)                  AS momentum
    FROM candidates AS c
    JOIN products AS p               ON p.product_id   = c.product_id
    JOIN mv_product_popularity AS pop ON pop.product_id = c.product_id
    LEFT JOIN cf_candidates AS cf    ON cf.product_id  = c.product_id
    LEFT JOIN mv_user_category_preferences AS prefs
           ON prefs.user_id     = p_user_id
          AND prefs.category_id = p.category_id
    LEFT JOIN mv_product_trend AS tr  ON tr.product_id  = c.product_id
    WHERE p.is_active
      AND NOT EXISTS (
            SELECT 1 FROM purchased AS x WHERE x.product_id = c.product_id
      )
),

/*
 Stage 7: NORMALISE.

 Min max scaling inside the candidate set, computed with window aggregates so
 the whole thing stays one pass:

     normalised = (x - MIN(x) OVER ()) / (MAX(x) OVER () - MIN(x) OVER ())

 NULLIF guards the degenerate case where every candidate shares a value, which
 happens routinely for a cold user whose collaborative score is zero across the
 board. COALESCE then sends that term to 0 so it contributes nothing rather
 than poisoning the sum with a NULL.
*/
normalised AS (
    SELECT
        f.*,
        COALESCE(
            (f.cf_score - MIN(f.cf_score) OVER ())
            / NULLIF(MAX(f.cf_score) OVER () - MIN(f.cf_score) OVER (), 0),
        0)  AS n_similarity,
        COALESCE(
            (f.category_affinity - MIN(f.category_affinity) OVER ())
            / NULLIF(MAX(f.category_affinity) OVER () - MIN(f.category_affinity) OVER (), 0),
        0)  AS n_category,
        COALESCE(
            (f.popularity_score - MIN(f.popularity_score) OVER ())
            / NULLIF(MAX(f.popularity_score) OVER () - MIN(f.popularity_score) OVER (), 0),
        0)  AS n_popularity,
        COALESCE(
            (f.smoothed_rating - MIN(f.smoothed_rating) OVER ())
            / NULLIF(MAX(f.smoothed_rating) OVER () - MIN(f.smoothed_rating) OVER (), 0),
        0)  AS n_rating,
        COALESCE(
            (f.recency_score - MIN(f.recency_score) OVER ())
            / NULLIF(MAX(f.recency_score) OVER () - MIN(f.recency_score) OVER (), 0),
        0)  AS n_recency
    FROM filtered AS f
),

/* Stage 8: BLEND. */
scored AS (
    SELECT
        n.*,
        ROUND(
              cfg.w_similarity * n.n_similarity
            + cfg.w_category   * n.n_category
            + cfg.w_popularity * n.n_popularity
            + cfg.w_rating     * n.n_rating
            + cfg.w_recency    * n.n_recency,
            6
        ) AS final_score,
        cfg.reason_similarity_cut,
        cfg.reason_affinity_cut,
        cfg.reason_popularity_cut
    FROM normalised AS n
    CROSS JOIN cfg
),

/*
 Stage 9: RANK and EXPLAIN.

 ROW_NUMBER gives a stable, gapless ordering with the product id as the tie
 break, so the same request returns the same shelf in the same order. RANK is
 kept alongside it so a genuine tie is visible rather than hidden by an
 arbitrary choice.

 The explanation is generated from the same normalised components that produced
 the score, in descending order of how strong each signal was. That is what
 keeps it honest: the reason is a readout of the winning term, not a label
 chosen after the fact.
*/
ranked AS (
    SELECT
        s.*,
        ROW_NUMBER() OVER (ORDER BY s.final_score DESC, s.product_id) AS row_rank,
        RANK()       OVER (ORDER BY s.final_score DESC)               AS tie_rank
    FROM scored AS s
)
SELECT
    p_user_id                                       AS user_id,
    r.product_id,
    r.product_name,
    r.category_name                                 AS category,
    r.price,
    r.final_score                                   AS recommendation_score,

    CASE
        WHEN r.n_similarity >= r.reason_similarity_cut AND r.supporting_anchors >= 3
            THEN FORMAT(
                'Customers who bought %s also bought this, and %s other items in your history point to it',
                (SELECT anchor.name FROM products AS anchor
                  WHERE anchor.product_id = r.top_anchor_product_id),
                r.supporting_anchors - 1
            )
        WHEN r.n_similarity >= r.reason_similarity_cut
            THEN FORMAT(
                'Similar to %s, which you already engaged with',
                (SELECT anchor.name FROM products AS anchor
                  WHERE anchor.product_id = r.top_anchor_product_id)
            )
        /* The category branches cite the product's rank inside the aisle rather
           than repeating one sentence. Without it every candidate from a user's
           favourite category gets an identical explanation, because min max
           normalisation sends them all to the same affinity value. A shelf
           where three consecutive rows say the same thing reads as a template,
           which is exactly the impression an explanation layer exists to
           avoid. */
        WHEN r.n_category >= r.reason_affinity_cut AND r.preference_rank = 1
            THEN FORMAT(
                'Number %s in %s, the category you shop most',
                r.popularity_category_rank, r.category_name
            )
        WHEN r.n_category >= r.reason_affinity_cut
            THEN FORMAT(
                'Number %s in %s, a category you shop regularly',
                r.popularity_category_rank, r.category_name
            )
        WHEN r.n_popularity >= r.reason_popularity_cut AND r.momentum > 1.2
            THEN 'Trending right now across the store'
        WHEN r.n_popularity >= r.reason_popularity_cut
            THEN 'Currently popular across the store'
        WHEN r.cf_score > 0
            THEN 'Recommended based on your recent activity'
        ELSE 'Highly rated pick to get you started'
    END                                             AS recommendation_reason,

    CASE r.source_priority
        WHEN 1 THEN 'collaborative_filtering'
        WHEN 2 THEN 'category_affinity'
        ELSE        'trending_cold_start'
    END                                             AS strategy,

    r.row_rank::INTEGER                             AS recommendation_rank
FROM ranked AS r
WHERE r.row_rank <= p_limit
ORDER BY r.row_rank;

/*
 Guaranteed non empty result.

 A warm user can in principle exhaust their candidate pool: everything the
 matrix suggests is already bought or has been withdrawn from sale. Returning
 an empty shelf in that case is a worse answer than returning the trending one,
 so the fallback is part of the contract rather than something the API layer
 has to remember to do.
*/
IF NOT FOUND THEN
    RETURN QUERY
    SELECT
        p_user_id,
        t.product_id,
        t.product_name,
        t.category,
        t.price,
        ROUND(t.trending_score, 6),
        'Popular right now, picked while we learn what you like'::TEXT,
        'trending_fallback'::TEXT,
        (ROW_NUMBER() OVER (ORDER BY t.trending_score DESC))::INTEGER
    FROM get_trending_products(p_limit) AS t
    WHERE NOT EXISTS (
        SELECT 1
        FROM orders AS o
        JOIN order_items AS oi ON oi.order_id = o.order_id
        WHERE o.user_id = p_user_id
          AND oi.product_id = t.product_id
          AND o.order_date < rec_as_of()
    );
END IF;

END;
$$;


/*
===============================================================================
 get_similar_products
===============================================================================
 Product to product recommendations: the "customers also viewed" shelf.

 This reads the same SQL built similarity matrix as the personalised ranker, so
 the two can never disagree about what is similar to what.

 There is one fallback, and it is the product cold start problem. A product
 added to the catalogue yesterday has no co occurrence history, so it has no
 row in the matrix at all. Rather than return nothing, the function falls back
 to content similarity over the generated tsvector: the new product's name,
 brand and subcategory become a full text query against the rest of the
 catalogue. Behaviour first, text second, never nothing.
===============================================================================
*/
CREATE OR REPLACE FUNCTION get_similar_products(
    p_product_id    INTEGER,
    p_limit         INTEGER DEFAULT 10
)
RETURNS TABLE (
    source_product_id   INTEGER,
    product_id          INTEGER,
    product_name        TEXT,
    category            TEXT,
    brand               TEXT,
    price               NUMERIC,
    similarity_score    NUMERIC,
    common_users        BIGINT,
    similarity_basis    TEXT,
    relationship        TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
#variable_conflict use_column
BEGIN

RETURN QUERY
SELECT
    p_product_id                AS source_product_id,
    p.product_id,
    p.name                      AS product_name,
    c.category_name             AS category,
    p.brand,
    p.price,
    sim.similarity_score,
    sim.common_users,
    'collaborative'::TEXT       AS similarity_basis,
    CASE
        WHEN sim.same_subcategory AND p.brand = src.brand
            THEN 'Same range from ' || p.brand
        WHEN sim.same_subcategory
            THEN 'Direct alternative'
        WHEN sim.same_category
            THEN 'Frequently bought alongside'
        WHEN sim.jaccard_similarity >= 0.10
            THEN 'Shoppers pair these up'
        ELSE 'Discovered through shared audience'
    END                         AS relationship
FROM mv_product_similarity AS sim
JOIN products   AS p   ON p.product_id   = sim.product_b
JOIN categories AS c   ON c.category_id  = p.category_id
JOIN products   AS src ON src.product_id = sim.product_a
WHERE sim.product_a = p_product_id
  AND p.is_active
ORDER BY sim.similarity_score DESC, p.product_id
LIMIT p_limit;

/* Content based fallback for products with no behavioural neighbours yet. */
IF NOT FOUND THEN
    RETURN QUERY
    SELECT
        p_product_id,
        p.product_id,
        p.name,
        c.category_name,
        p.brand,
        p.price,
        ROUND(ts_rank(p.search_document, src.query)::NUMERIC, 6),
        0::BIGINT,
        'content'::TEXT,
        'Similar catalogue entry, no purchase history yet'::TEXT
    FROM products AS p
    JOIN categories AS c ON c.category_id = p.category_id
    CROSS JOIN LATERAL (
        SELECT plainto_tsquery(
            'english',
            s.name || ' ' || s.brand || ' ' || s.subcategory
        ) AS query
        FROM products AS s
        WHERE s.product_id = p_product_id
    ) AS src
    WHERE p.product_id <> p_product_id
      AND p.is_active
      AND p.search_document @@ src.query
    ORDER BY ts_rank(p.search_document, src.query) DESC, p.product_id
    LIMIT p_limit;
END IF;

END;
$$;


/*
===============================================================================
 search_products
===============================================================================
 Catalogue search, ranked by relevance AND by demand.

 Pure text relevance is the wrong objective for a storefront: among twenty
 equally relevant matches for "running shoes", the one people actually buy
 should come first. The score blends ts_rank_cd, which rewards matches that
 appear close together in the document, with the same decayed popularity the
 recommender uses.

 The GIN index on the generated `search_document` column is what makes this a
 sub millisecond lookup rather than a scan of 2000 descriptions.
===============================================================================
*/
CREATE OR REPLACE FUNCTION search_products(
    p_query TEXT,
    p_limit INTEGER DEFAULT 20
)
RETURNS TABLE (
    product_id      INTEGER,
    product_name    TEXT,
    category        TEXT,
    brand           TEXT,
    price           NUMERIC,
    text_rank       REAL,
    blended_score   NUMERIC
)
LANGUAGE sql
STABLE
AS $$
    WITH q AS (
        SELECT websearch_to_tsquery('english', p_query) AS query
    ),
    matches AS (
        SELECT
            p.product_id,
            p.name,
            c.category_name,
            p.brand,
            p.price,
            ts_rank_cd(p.search_document, q.query) AS text_rank,
            pop.popularity_score
        FROM products AS p
        CROSS JOIN q
        JOIN categories AS c              ON c.category_id = p.category_id
        JOIN mv_product_popularity AS pop ON pop.product_id = p.product_id
        WHERE p.search_document @@ q.query
          AND p.is_active
    )
    /*
     Normalise before blending, for the same reason the ranker does.
     ts_rank_cd returns small unbounded floats, typically between 0.01 and 0.3,
     while popularity_score is already a percentile on 0 to 1. Blending them raw
     means a 70 percent weight on relevance loses to a 30 percent weight on
     popularity every time, and the search box quietly turns into a bestseller
     list. Rescaling both across the matched set is what makes the stated
     weights mean what they say.
    */
    SELECT
        m.product_id,
        m.name,
        m.category_name,
        m.brand,
        m.price,
        m.text_rank,
        ROUND(
            0.70 * COALESCE(
                (m.text_rank - MIN(m.text_rank) OVER ())::NUMERIC
                / NULLIF((MAX(m.text_rank) OVER () - MIN(m.text_rank) OVER ())::NUMERIC, 0),
            1)
            + 0.30 * COALESCE(
                (m.popularity_score - MIN(m.popularity_score) OVER ())
                / NULLIF(MAX(m.popularity_score) OVER () - MIN(m.popularity_score) OVER (), 0),
            1),
            6
        ) AS blended_score
    FROM matches AS m
    ORDER BY blended_score DESC, m.product_id
    LIMIT p_limit;
$$;
