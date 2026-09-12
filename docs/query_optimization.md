# Query optimization

Produced by `python -m python.benchmark`. Each row is measured by dropping the index, timing the query, restoring the index and timing again. Timings are the median `Execution Time` from `EXPLAIN (ANALYZE, BUFFERS)` over 5 runs, after a warm up pass so both sides read a warm cache.

## Summary

| Query | Without index (ms) | With index (ms) | Speedup |
| - | -: | -: | -: |
| Anchor lookup for one user | 96.824 | 0.432 | 224.1x |
| Recent demand for one product | 25.473 | 0.265 | 96.1x |
| Neighbour lookup in the similarity matrix | 10.186 | 0.368 | 27.7x |
| Full text catalogue search | 0.522 | 0.111 | 4.7x |
| Purchase exclusion set | 0.023 | 0.011 | 2.1x |

## Anchor lookup for one user

**Question.** What has this user engaged with, and how strongly?

**Why it matters.** Stage 2 of get_recommendations runs this on every request. Without an index it is a sequential scan of the whole interaction log to find the few dozen rows belonging to one person.

```sql
SELECT
    i.product_id,
    SUM(CASE i.interaction_type
            WHEN 'view' THEN 1 WHEN 'wishlist' THEN 3
            WHEN 'cart' THEN 5 WHEN 'purchase' THEN 10 ELSE 0 END) AS score,
    MAX(i.interaction_timestamp) AS last_interaction
FROM user_interactions AS i
WHERE i.user_id = %s
  AND i.interaction_timestamp < rec_as_of()
GROUP BY i.product_id
ORDER BY score DESC
LIMIT 50
```

Index under test: `idx_interactions_user_product`, `idx_interactions_user_time`

| | Plan | Execution time |
| - | - | -: |
| Without | Index Scan using idx_interactions_timestamp | 96.824 ms |
| With | Index Only Scan using idx_interactions_user_product | 0.432 ms |

Speedup: **224.1x**.

## Recent demand for one product

**Question.** How much engagement has this product had in the last four weeks?

**Why it matters.** The shape of every trend and popularity query: one product, one time window. The composite index puts the range predicate on the second column so the scan can stop early instead of filtering the product's entire history.

```sql
SELECT
    COUNT(*)                                                AS events,
    COUNT(*) FILTER (WHERE interaction_type = 'purchase')   AS purchases,
    COUNT(DISTINCT user_id)                                 AS unique_users
FROM user_interactions
WHERE product_id = %s
  AND interaction_timestamp >= rec_as_of() - INTERVAL '4 weeks'
  AND interaction_timestamp <  rec_as_of()
```

Index under test: `idx_interactions_product_time`

| | Plan | Execution time |
| - | - | -: |
| Without | Index Only Scan using idx_interactions_user_product | 25.473 ms |
| With | Bitmap Heap Scan on user_interactions; Bitmap Index Scan using idx_interactions_product_time | 0.265 ms |

Speedup: **96.1x**.

## Neighbour lookup in the similarity matrix

**Question.** Given twenty products this user likes, what is similar to them?

**Why it matters.** Candidate generation. This is the single hottest read in the serving path and it runs against a hundred thousand row matrix that will only grow with the catalogue.

```sql
SELECT sim.product_b, SUM(sim.similarity_score) AS score
FROM mv_product_similarity AS sim
WHERE sim.product_a = ANY(%s)
GROUP BY sim.product_b
ORDER BY score DESC
LIMIT 100
```

Index under test: `idx_mv_sim_lookup`, `idx_mv_sim_pk`

| | Plan | Execution time |
| - | - | -: |
| Without | Seq Scan on mv_product_similarity | 10.186 ms |
| With | Index Only Scan using idx_mv_sim_lookup | 0.368 ms |

Speedup: **27.7x**.

## Full text catalogue search

**Question.** Which products match a free text query?

**Why it matters.** Without the GIN index over the generated tsvector, every search re tokenises and scans the whole catalogue. The generated column plus GIN turns that into an inverted index probe.

```sql
SELECT p.product_id, p.name, ts_rank_cd(p.search_document, q.query) AS rank
FROM products AS p
CROSS JOIN websearch_to_tsquery('english', %s) AS q(query)
WHERE p.search_document @@ q.query
  AND p.is_active
ORDER BY rank DESC
LIMIT 20
```

Index under test: `idx_products_search_document`

| | Plan | Execution time |
| - | - | -: |
| Without | Seq Scan on products | 0.522 ms |
| With | Bitmap Heap Scan on products; Bitmap Index Scan using idx_products_search_document | 0.111 ms |

Speedup: **4.7x**.

## Purchase exclusion set

**Question.** Which products has this user already bought?

**Why it matters.** Runs on every recommendation request as the anti join that keeps already owned products off the shelf. This is the honest case in the set: dropping the partial index does not fall back to a sequential scan, it falls back to the broad composite index, which already answers the query well. The partial index earns its place on size rather than on dramatic speed, covering only the purchase rows at roughly a tenth of the composite index it displaces, which is what keeps it resident in cache under memory pressure.

```sql
SELECT DISTINCT product_id
FROM user_interactions
WHERE user_id = %s
  AND interaction_type = 'purchase'
  AND interaction_timestamp < rec_as_of()
```

Index under test: `idx_interactions_purchases`

| | Plan | Execution time |
| - | - | -: |
| Without | Index Only Scan using idx_interactions_user_product | 0.023 ms |
| With | Index Only Scan using idx_interactions_purchases | 0.011 ms |

Speedup: **2.1x**.

## Index sizes

Indexes are not free. They cost disk, they cost write throughput and they cost cache residency. These are the ones this project keeps.

| Index | Table | Size |
| - | - | -: |
| `idx_interactions_user_product` | user_interactions | 49 MB |
| `idx_interactions_product_time` | user_interactions | 37 MB |
| `idx_interactions_user_time` | user_interactions | 35 MB |
| `idx_interactions_timestamp` | user_interactions | 25 MB |
| `idx_mv_upf_user_score` | mv_user_product_features | 11 MB |
| `idx_mv_upf_pk` | mv_user_product_features | 8360 kB |
| `idx_interactions_purchases` | user_interactions | 4712 kB |
| `idx_order_items_product` | order_items | 4712 kB |
| `idx_mv_sim_lookup` | mv_product_similarity | 3936 kB |
| `idx_order_items_order` | order_items | 3368 kB |
| `idx_mv_upf_purchased` | mv_user_product_features | 3368 kB |
| `idx_mv_sim_pk` | mv_product_similarity | 2184 kB |
| `idx_orders_user_date` | orders | 1648 kB |
| `idx_orders_date` | orders | 1184 kB |
| `idx_mv_ucp_user_rank` | mv_user_category_preferences | 552 kB |
| `idx_ratings_product` | ratings | 488 kB |
| `idx_mv_ucp_pk` | mv_user_category_preferences | 400 kB |
| `idx_products_search_document` | products | 136 kB |
| `idx_users_signup_date` | users | 96 kB |
| `idx_products_active_category` | products | 80 kB |
| `idx_mv_pop_category_rank` | mv_product_popularity | 80 kB |
| `idx_mv_pop_rank` | mv_product_popularity | 64 kB |
| `idx_mv_pop_pk` | mv_product_popularity | 64 kB |
| `idx_mv_trend_pk` | mv_product_trend | 64 kB |
| `idx_mv_trend_momentum` | mv_product_trend | 64 kB |
| `idx_products_brand` | products | 32 kB |
| `idx_products_category` | products | 32 kB |
