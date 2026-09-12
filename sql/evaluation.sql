/*
===============================================================================
 evaluation.sql
===============================================================================
 The offline evaluation harness, and the two baselines the hybrid ranker is
 measured against.

 HOW LEAKAGE IS PREVENTED

 The interaction log is split on a single timestamp, chosen as a percentile of
 the event timeline rather than a calendar date so the split lands where the
 data actually is:

     everything BEFORE the cutoff   ->  history the recommender may see
     everything AFTER  the cutoff   ->  the future it is scored against

 The enforcement is structural rather than procedural. Every feature view,
 every materialized view and every scoring function reads its horizon from
 `rec_as_of()`. Setting the cutoff and refreshing makes the post cutoff events
 invisible to the entire pipeline at once. There is no per query WHERE clause to
 forget, and no way for a future purchase to reach a similarity score.

 This matters more than it sounds. The classic way to produce a beautiful and
 completely worthless offline result is to build the similarity matrix over the
 whole dataset and then evaluate on a random holdout: the matrix has already
 seen the answers. Rewinding the clock and rebuilding is the only way to be sure
 it has not.

 WHAT IS BEING MEASURED

 Ground truth is the set of products a user PURCHASED after the cutoff and had
 NOT purchased before it. Purchases rather than views, because a purchase is the
 outcome the business cares about, and new purchases only, because re
 recommending something already owned is excluded by the ranker anyway and would
 otherwise be free credit.

 The metrics themselves are computed in python/evaluate.py from the lists these
 functions return.
===============================================================================
*/

/*
===============================================================================
 evaluation_cutoff
===============================================================================
 The split point, as a percentile of the interaction timeline.

 An ordered set aggregate rather than a hand picked date: a fixed date would
 split the data unevenly the moment the generator's window changes, and what the
 experiment needs is a fixed PROPORTION of history, not a particular day.

 PERCENTILE_DISC, not PERCENTILE_CONT. The continuous variant interpolates
 between the two neighbouring values and is therefore only defined for numeric
 and interval inputs; the discrete variant returns an actual observed value and
 works on any sortable type, timestamps included. It also gives a cutoff that
 lands exactly on a real event, which is what a replay wants.
===============================================================================
*/
CREATE OR REPLACE FUNCTION evaluation_cutoff(p_train_fraction NUMERIC DEFAULT 0.80)
RETURNS TIMESTAMP
LANGUAGE sql
STABLE
AS $$
    SELECT PERCENTILE_DISC(p_train_fraction) WITHIN GROUP (
        ORDER BY interaction_timestamp
    )
    FROM public.user_interactions;
$$;


/*
===============================================================================
 eval_ground_truth
===============================================================================
 What each user actually went on to buy after the cutoff.

 NOT EXISTS rather than a LEFT JOIN with an IS NULL test: the anti join reads
 better and lets the planner stop at the first matching row instead of
 materialising the whole left side.
===============================================================================
*/
CREATE OR REPLACE VIEW eval_ground_truth AS
SELECT
    future.user_id,
    future.product_id,
    MIN(future.interaction_timestamp) AS first_future_purchase
FROM user_interactions AS future
WHERE future.interaction_type = 'purchase'
  AND future.interaction_timestamp >= rec_as_of()
  AND NOT EXISTS (
        SELECT 1
        FROM user_interactions AS past
        WHERE past.user_id           = future.user_id
          AND past.product_id        = future.product_id
          AND past.interaction_type  = 'purchase'
          AND past.interaction_timestamp < rec_as_of()
  )
GROUP BY future.user_id, future.product_id;


/*
===============================================================================
 eval_candidate_users
===============================================================================
 Every user with at least one held out purchase, whatever their history looks
 like. The only filter is the join to ground truth, because a user who buys
 nothing after the cutoff gives the metric nothing to be right or wrong about.

 Deliberately NOT filtered on history length. It is tempting to require, say,
 five prior interactions so that every strategy has something to work with, and
 it is the wrong call: it quietly removes exactly the users cold start handling
 exists for, and it flatters pure collaborative filtering, which cannot serve
 them at all. Keeping them in is what makes the `users served` row in the report
 meaningful, and the tier breakdown is there so the easy and hard cases can
 still be read separately.
===============================================================================
*/
CREATE OR REPLACE VIEW eval_candidate_users AS
SELECT
    prof.user_id,
    prof.user_tier,
    prof.total_interactions,
    prof.distinct_products,
    truth.future_purchases
FROM user_recommendation_profile AS prof
JOIN (
    SELECT user_id, COUNT(*) AS future_purchases
    FROM eval_ground_truth
    GROUP BY user_id
) AS truth ON truth.user_id = prof.user_id;


/*
===============================================================================
 BASELINE 1: popularity
===============================================================================
 Recommend the most popular products the user has not bought.

 This is the baseline that matters. It is trivial to implement, it is what a
 storefront does with no recommender at all, and it is deceptively strong,
 because popular things are popular for a reason. A personalised recommender
 that cannot beat it is not earning its complexity, and reporting a hit rate
 without this comparison tells you nothing.
===============================================================================
*/
CREATE OR REPLACE FUNCTION get_popularity_baseline(
    p_user_id   INTEGER,
    p_limit     INTEGER DEFAULT 10
)
RETURNS TABLE (
    product_id  INTEGER,
    score       NUMERIC,
    rank        INTEGER
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        pop.product_id,
        pop.popularity_score,
        (ROW_NUMBER() OVER (ORDER BY pop.decayed_engagement DESC, pop.product_id))::INTEGER
    FROM mv_product_popularity AS pop
    WHERE pop.is_active
      AND NOT EXISTS (
            SELECT 1
            FROM mv_user_product_features AS f
            WHERE f.user_id = p_user_id
              AND f.product_id = pop.product_id
              AND f.has_purchased
      )
    ORDER BY pop.decayed_engagement DESC, pop.product_id
    LIMIT p_limit;
$$;


/*
===============================================================================
 BASELINE 2: pure item to item collaborative filtering
===============================================================================
 The same candidate generation the hybrid uses, with none of the blending: no
 category affinity, no popularity, no rating, no recency. Just the similarity
 matrix and the user's history.

 Isolating it this way is what makes the comparison in evaluate.py an ablation
 rather than a beauty contest. The gap between this and the hybrid is exactly
 the contribution of the other four signals.
===============================================================================
*/
CREATE OR REPLACE FUNCTION get_cf_baseline(
    p_user_id   INTEGER,
    p_limit     INTEGER DEFAULT 10
)
RETURNS TABLE (
    product_id  INTEGER,
    score       NUMERIC,
    rank        INTEGER
)
LANGUAGE sql
STABLE
AS $$
    WITH anchors AS (
        SELECT
            f.product_id,
            f.decayed_score / NULLIF(SUM(f.decayed_score) OVER (), 0) AS anchor_weight
        FROM (
            SELECT upf.product_id, upf.decayed_score
            FROM mv_user_product_features AS upf
            WHERE upf.user_id = p_user_id
              AND upf.decayed_score > 0
            ORDER BY upf.decayed_score DESC
            LIMIT 50
        ) AS f
    ),
    scored AS (
        SELECT
            sim.product_b AS product_id,
            SUM(sim.similarity_score * a.anchor_weight) AS cf_score
        FROM anchors AS a
        JOIN mv_product_similarity AS sim ON sim.product_a = a.product_id
        GROUP BY sim.product_b
    )
    SELECT
        s.product_id,
        ROUND(s.cf_score, 6),
        (ROW_NUMBER() OVER (ORDER BY s.cf_score DESC, s.product_id))::INTEGER
    FROM scored AS s
    JOIN products AS p ON p.product_id = s.product_id
    WHERE p.is_active
      AND NOT EXISTS (
            SELECT 1
            FROM mv_user_product_features AS f
            WHERE f.user_id = p_user_id
              AND f.product_id = s.product_id
              AND f.has_purchased
      )
    ORDER BY s.cf_score DESC, s.product_id
    LIMIT p_limit;
$$;


/*
===============================================================================
 eval_strategy_recommendations
===============================================================================
 One dispatcher so the Python harness asks all three strategies the same
 question in the same shape. Keeping the dispatch in SQL means the harness has
 no opportunity to treat one strategy differently from another, accidentally or
 otherwise.
===============================================================================
*/
CREATE OR REPLACE FUNCTION eval_strategy_recommendations(
    p_strategy  TEXT,
    p_user_id   INTEGER,
    p_limit     INTEGER DEFAULT 10
)
RETURNS TABLE (
    product_id  INTEGER,
    rank        INTEGER
)
LANGUAGE plpgsql
STABLE
AS $$
#variable_conflict use_column
BEGIN
    IF p_strategy = 'popularity' THEN
        RETURN QUERY
        SELECT b.product_id, b.rank FROM get_popularity_baseline(p_user_id, p_limit) AS b;

    ELSIF p_strategy = 'collaborative' THEN
        RETURN QUERY
        SELECT b.product_id, b.rank FROM get_cf_baseline(p_user_id, p_limit) AS b;

    ELSIF p_strategy = 'hybrid' THEN
        RETURN QUERY
        SELECT r.product_id, r.recommendation_rank
        FROM get_recommendations(p_user_id, p_limit) AS r;

    ELSE
        RAISE EXCEPTION 'Unknown strategy: %', p_strategy;
    END IF;
END;
$$;


/*
===============================================================================
 eval_coverage_report
===============================================================================
 Catalogue coverage and popularity bias, which precision alone will not reveal.

 A recommender that shows the same forty bestsellers to everyone can post a
 respectable hit rate while being useless as a discovery tool. This reports how
 much of the catalogue each strategy actually reaches, and what share of its
 recommendations come from the head of the demand curve.
===============================================================================
*/
CREATE OR REPLACE FUNCTION eval_coverage_report(
    p_strategy      TEXT,
    p_sample_users  INTEGER DEFAULT 300,
    p_limit         INTEGER DEFAULT 10
)
RETURNS TABLE (
    strategy            TEXT,
    users_sampled       BIGINT,
    distinct_products   BIGINT,
    catalogue_coverage  NUMERIC,
    head_share          NUMERIC
)
LANGUAGE sql
STABLE
AS $$
    WITH sampled AS (
        SELECT user_id
        FROM eval_candidate_users
        ORDER BY user_id
        LIMIT p_sample_users
    ),
    recommended AS (
        SELECT s.user_id, r.product_id
        FROM sampled AS s
        CROSS JOIN LATERAL eval_strategy_recommendations(p_strategy, s.user_id, p_limit) AS r
    )
    SELECT
        p_strategy,
        COUNT(DISTINCT rec.user_id),
        COUNT(DISTINCT rec.product_id),
        ROUND(
            COUNT(DISTINCT rec.product_id)::NUMERIC
            / (SELECT COUNT(*) FROM products WHERE is_active),
            4
        ),
        ROUND(
            COUNT(*) FILTER (WHERE pop.demand_tier = 'head')::NUMERIC
            / NULLIF(COUNT(*), 0),
            4
        )
    FROM recommended AS rec
    JOIN mv_product_popularity AS pop ON pop.product_id = rec.product_id;
$$;
