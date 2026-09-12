/*
===============================================================================
 indexes.sql
===============================================================================
 Indexes are created AFTER the bulk load. Building them once over a finished
 table is materially cheaper than maintaining them across 500k inserts, and it
 leaves the planner with fresh statistics.

 Every index below exists because a specific query in views.sql,
 materialized_views.sql, recommendations.sql or analytics.sql needs it. The
 comment on each one names that query. Indexes without a caller are a cost, not
 an asset, so there are none here.

 Measured impact is in docs/query_optimization.md, produced by python/benchmark.py.
===============================================================================
*/

BEGIN;

/*
===============================================================================
 user_interactions: the hot table
===============================================================================
 300k rows, read by every stage of the pipeline, always filtered by the
 `interaction_timestamp < rec_as_of()` cutoff.
*/

/*
 Serves the feature layer, which groups interactions by (user_id, product_id).
 `interaction_timestamp` rides along as an INCLUDE payload so that computing
 `last_interaction` and the decayed scores stays an index only scan and never
 touches the heap.
*/
CREATE INDEX IF NOT EXISTS idx_interactions_user_product
    ON user_interactions (user_id, product_id)
    INCLUDE (interaction_timestamp, interaction_type);

/*
 Serves the popularity layer and the per product trend queries, which scan one
 product across a time window. Leading with product_id keeps the range
 predicate on the second column where it can terminate the scan early.
*/
CREATE INDEX IF NOT EXISTS idx_interactions_product_time
    ON user_interactions (product_id, interaction_timestamp DESC);

/*
 Serves the cutoff itself. Every derived object opens with
 `WHERE interaction_timestamp < rec_as_of()`, and during evaluation the cutoff
 selects roughly 80 percent of the table, so this is used for the ordered pass
 rather than for selectivity.
*/
CREATE INDEX IF NOT EXISTS idx_interactions_timestamp
    ON user_interactions (interaction_timestamp DESC);

/*
 Serves `get_recommendations`, which needs one user's recent history in
 timestamp order to build anchors. Composite rather than two single column
 indexes because the planner would otherwise bitmap AND them and then sort.
*/
CREATE INDEX IF NOT EXISTS idx_interactions_user_time
    ON user_interactions (user_id, interaction_timestamp DESC);

/*
 Partial index over purchases only. Purchases are about 8 percent of the table
 but drive the exclusion set, the conversion funnel and the co purchase
 analytics. A partial index is roughly a twelfth of the size of the equivalent
 full index and stays in cache.
*/
CREATE INDEX IF NOT EXISTS idx_interactions_purchases
    ON user_interactions (user_id, product_id, interaction_timestamp)
    WHERE interaction_type = 'purchase';

/*
===============================================================================
 products
===============================================================================
*/

/* Serves category rollups and the category affinity join in the ranker. */
CREATE INDEX IF NOT EXISTS idx_products_category
    ON products (category_id, subcategory);

/* Serves brand level analytics and the brand facet in catalogue search. */
CREATE INDEX IF NOT EXISTS idx_products_brand
    ON products (brand);

/*
 Partial index on the sellable catalogue. The ranker filters `is_active` on
 every request, so restricting the index to live products keeps candidate
 lookups off the discontinued rows entirely.
*/
CREATE INDEX IF NOT EXISTS idx_products_active_category
    ON products (category_id, rating DESC)
    WHERE is_active;

/*
 GIN index over the generated tsvector. This is what makes `search_products`
 sub millisecond instead of a sequential regex scan, and it is also the index
 behind the content based cold start fallback for products that have no
 collaborative neighbours yet.
*/
CREATE INDEX IF NOT EXISTS idx_products_search_document
    ON products USING GIN (search_document);

/*
===============================================================================
 orders and order_items
===============================================================================
*/

/* Serves customer lifetime value, order frequency and the cohort queries, all
   of which walk one customer's orders in date order. */
CREATE INDEX IF NOT EXISTS idx_orders_user_date
    ON orders (user_id, order_date DESC);

/* Serves the monthly revenue and seasonality rollups, which range scan dates
   across all users. */
CREATE INDEX IF NOT EXISTS idx_orders_date
    ON orders (order_date);

/* Serves the basket side of the co purchase self join. */
CREATE INDEX IF NOT EXISTS idx_order_items_order
    ON order_items (order_id, product_id);

/* Serves revenue by product and the product to basket direction of the same
   self join. `quantity` and `unit_price` are included so revenue rollups are
   index only. */
CREATE INDEX IF NOT EXISTS idx_order_items_product
    ON order_items (product_id)
    INCLUDE (quantity, unit_price);

/*
===============================================================================
 ratings and users
===============================================================================
*/

/* Serves the rating component of the popularity layer. */
CREATE INDEX IF NOT EXISTS idx_ratings_product
    ON ratings (product_id, rating);

/* Serves the signup cohort analytics. */
CREATE INDEX IF NOT EXISTS idx_users_signup_date
    ON users (signup_date);

COMMIT;

/*
 Refresh planner statistics. Without this the first queries after a load run on
 default estimates and can choose a nested loop where a hash join is correct.
*/
ANALYZE users;
ANALYZE products;
ANALYZE orders;
ANALYZE order_items;
ANALYZE user_interactions;
ANALYZE ratings;
