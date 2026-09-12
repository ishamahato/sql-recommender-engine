# SQL Recommendation Engine

## 🚀 Live Demo

👉 [Try the Live Demo](https://drive.google.com/file/d/1XEq6hbzKdm8WGc3IkoR3UOaqONTfn-KR/view?usp=sharing)

A production shaped e commerce recommender in which **PostgreSQL does the
recommending**. Feature engineering, the item to item similarity matrix,
candidate generation, business rule filtering, multi signal scoring, ranking and
the human readable explanation are all SQL. Python generates the dataset, loads
it, orchestrates the pipeline, measures the result and serves it over HTTP.

There is no model file, no embedding store and no scoring code outside the
database. If you want to know why a product was recommended, you read
[`sql/recommendations.sql`](sql/recommendations.sql).

```
Python                PostgreSQL                              Python
generate  ────────▶   feature engineering                     evaluate
load                  user preference model                   API
                      item to item similarity                 dashboard
                      candidate generation
                      scoring and ranking      ───────────▶   top N
```

## Table of contents

- [SQL Recommendation Engine](#sql-recommendation-engine)
  - [Table of contents](#table-of-contents)
  - [What it does](#what-it-does)
  - [Results](#results)
  - [Quick start](#quick-start)
  - [Architecture](#architecture)
  - [Database schema](#database-schema)
  - [The feature layer](#the-feature-layer)
  - [Item to item collaborative filtering in SQL](#item-to-item-collaborative-filtering-in-sql)
    - [Why not a raw co occurrence count](#why-not-a-raw-co-occurrence-count)
    - [Cosine similarity](#cosine-similarity)
    - [The query](#the-query)
  - [The ranking query](#the-ranking-query)
    - [Candidate generation](#candidate-generation)
    - [Scoring](#scoring)
    - [Explanations](#explanations)
    - [Business rules](#business-rules)
  - [Cold start](#cold-start)
  - [Why materialized views](#why-materialized-views)
  - [Indexing and query optimization](#indexing-and-query-optimization)
    - [The two that matter most](#the-two-that-matter-most)
    - [The honest one](#the-honest-one)
  - [Evaluation methodology](#evaluation-methodology)
    - [The split](#the-split)
    - [How leakage is prevented](#how-leakage-is-prevented)
    - [What is measured](#what-is-measured)
  - [SQL techniques, and where to find them](#sql-techniques-and-where-to-find-them)
  - [The synthetic dataset](#the-synthetic-dataset)
  - [What Python does, and what it deliberately does not](#what-python-does-and-what-it-deliberately-does-not)
  - [API](#api)
  - [Dashboard](#dashboard)
  - [Analytics library](#analytics-library)
  - [Project structure](#project-structure)
  - [Known limitations](#known-limitations)
  - [Interview questions](#interview-questions)

## What it does

Given a user, it returns ranked products with a score and a reason:

| user | product | category | price | score | reason |
| -: | - | - | -: | -: | - |
| 2 | Kestrel Creator Laptop 3 | Electronics | 678.27 | 0.923 | Customers who bought Sable Everyday Low Profile Keyboard 6 also bought this, and 33 other items in your history point to it |
| 2 | Northbeam Portable Monitor | Electronics | 626.22 | 0.861 | Top rated in Electronics, your most shopped category |
| 2 | Volta Mechanical Keyboard | Electronics | 78.99 | 0.841 | Top rated in Electronics, your most shopped category |

That user was generated as a `pc_builder`. A `console_gamer` on the same
database gets controllers, consoles and games. The recommender never sees the
persona label; it recovers the structure from behaviour alone.

Three functions make up the public surface:

| Function | Purpose |
| - | - |
| `get_recommendations(user_id, limit)` | Personalised shelf, with cold start handling and explanations |
| `get_similar_products(product_id, limit)` | Customers also viewed, with a full text fallback for new products |
| `search_products(query, limit)` | Catalogue search, relevance blended with demand |

## Results

Measured on a temporal split at the 80th percentile of the interaction
timeline, with the entire pipeline rewound to that cutoff and rebuilt.
1,500 users, 7,737 held out purchases. Full report in
[`docs/evaluation_results.md`](docs/evaluation_results.md).

| Metric | Popularity baseline | Collaborative filtering | Hybrid SQL recommender |
| - | -: | -: | -: |
| Precision@5 | 0.0167 | 0.0873 | **0.0888** |
| Precision@10 | 0.0141 | 0.0722 | **0.0756** |
| Recall@5 | 0.0160 | **0.0900** | 0.0889 |
| Recall@10 | 0.0284 | 0.1432 | **0.1479** |
| Hit Rate@10 | 0.1340 | 0.4373 | **0.4680** |
| NDCG@10 | 0.0229 | 0.1216 | **0.1253** |
| Users served | 1.0000 | 0.7920 | **1.0000** |

Three things in that table are worth more than the headline precision.

**The popularity baseline is in the table at all.** It is trivial to implement
and deceptively strong, and a personalised recommender that cannot beat it is
not paying for its complexity. This one beats it by 5.4x on precision and 3.5x
on hit rate.

**Collaborative filtering serves only 79 percent of users.** It returns nothing
at all for users with no history, because it has nothing to compute a
similarity from. The hybrid serves everyone, and the cold start path is the
reason it wins on hit rate despite being nearly tied on the easy users:

| Tier | Users | Hybrid hit rate@10 | Popularity served | Collaborative served | Hybrid served |
| - | -: | -: | -: | -: | -: |
| cold | 312 | 0.1410 | 1.0000 | **0.0000** | 1.0000 |
| light | 96 | 0.5208 | 1.0000 | 1.0000 | 1.0000 |
| warm | 1,092 | 0.5568 | 1.0000 | 1.0000 | 1.0000 |

**Catalogue coverage.** Precision alone will happily reward a recommender that
shows the same forty bestsellers to everybody.

| | Popularity | Collaborative | Hybrid |
| - | -: | -: | -: |
| Distinct products recommended | 14 | 347 | 354 |
| Catalogue coverage | 0.7% | 18.1% | 18.4% |
| Mean latency per user | 0.69 ms | 1.61 ms | 6.07 ms |

Serving latency is around 6 ms per request against a 1.2 million row
interaction log, because everything expensive was computed offline.

## Quick start

Requires Docker and Python 3.11 or newer.

```bash
make all
```

That runs the six steps below, in order. To do them one at a time:

```bash
make setup
```

```bash
make up
```

```bash
make generate
```

```bash
make build
```

```bash
make evaluate
```

```bash
make benchmark
```

Each target is a one line wrapper over a Python entry point, so they can also be
run directly once the virtualenv is active, for example
`python -m python.generate_data`. No script takes command line flags: everything
is configured in `.env`, which `make setup` creates from `.env.example`.

Then start either interface:

```bash
make api
```

```bash
make dashboard
```

The API serves interactive documentation at `http://127.0.0.1:8000/docs` and
the dashboard runs at `http://localhost:8501`. The API has no root route, so
`http://127.0.0.1:8000/` returning 404 is expected.

To read the SQL output directly, which is the most useful way to inspect what
the engine is doing:

```bash
make psql
```

That reads `.env`, so it reaches the Docker service and a local PostgreSQL
alike, and it turns the pager off so results print straight to the terminal
instead of trapping you at an `(END)` prompt. Then:

```sql
SELECT * FROM get_recommendations(2, 10);
SELECT * FROM get_similar_products(134, 10);
SELECT * FROM search_products('noise cancelling headphones', 10);
SELECT * FROM user_recommendation_profile WHERE user_id = 2;
```

Timings on a laptop, PostgreSQL 18 with the tuning in `docker-compose.yml`:

| Step | Time |
| - | -: |
| Generate 1.2 million interactions | 15 s |
| Load via COPY | 21 s |
| Build indexes | 7 s |
| Build the offline layer including the similarity matrix | 48 s |
| Full build, end to end | 78 s |
| Temporal evaluation including two full rewinds | 105 s |

## Architecture

```
                 ┌─────────────────────────────────────────────┐
                 │  OFFLINE          scheduled, minutes        │
  raw events ───▶│                                             │
                 │  user_product_features        380,230 rows  │
                 │  user_category_preferences     17,303 rows  │
                 │  product_popularity             2,000 rows  │
                 │  product_trend                  1,977 rows  │
                 │  product_similarity            98,850 pairs │
                 └──────────────────┬──────────────────────────┘
                                    │ materialized views
                 ┌──────────────────▼──────────────────────────┐
   request ─────▶│  ONLINE           per request, milliseconds │
                 │                                             │
                 │  anchors ▶ neighbours ▶ filter ▶ score ▶ rank│
                 └──────────────────┬──────────────────────────┘
                                    │
                              FastAPI / Streamlit
```

The split is the whole design. The expensive work, dominated by a self join
that produces millions of co occurrence pairs, runs on a schedule and lands in
materialized views. A request then touches a few hundred indexed rows.

What materialized views give that a cache does not: the offline results are
ordinary relations, so the online query can join them, filter them and rank
against them inside one execution plan, with real statistics and real indexes.

## Database schema

```
users ──────────┬──▶ orders ──▶ order_items ──▶ products ──▶ categories
                │                                   ▲
                ├──▶ user_interactions ─────────────┤
                │                                   │
                └──▶ ratings ───────────────────────┘

interaction_weights   view 1, wishlist 3, cart 5, purchase 10
rec_config            scoring weights, half lives, thresholds
pipeline_state        the cutoff every derived object reads
```

Seven business tables plus three control tables. Full DDL with the reasoning on
every decision is in [`sql/schema.sql`](sql/schema.sql).

Two design choices carry the rest of the system.

**`pipeline_state.as_of_timestamp` is the clock.** Every view, materialized
view and scoring function reads its horizon through `rec_as_of()`. Nothing in
the pipeline calls `now()`. Recency is measured against the cutoff, not against
the wall clock. Rewinding that single value and refreshing makes the entire
recommender behave as though the data after that instant had never been
recorded, which is what makes the temporal evaluation leak free by construction
rather than by discipline.

**`rec_config` holds the scoring weights as rows.** Retuning the ranker or
standing up an A/B arm is an `UPDATE`, not a deploy.

There is also a `users.persona` column that the recommender never reads. It
records which behavioural archetype each synthetic user was drawn from, so the
test suite can assert that a `runner` and a `bookworm` receive meaningfully
different shelves.

## The feature layer

[`sql/views.sql`](sql/views.sql) turns the raw log into the three things a
ranker needs.

**`user_product_features`**, one row per user and product they have touched.
The funnel weighting is the single most important scoring rule in the system, so
it is written out at the point of use rather than hidden behind a join:

```sql
SUM(
    CASE i.interaction_type
        WHEN 'view'     THEN 1
        WHEN 'wishlist' THEN 3
        WHEN 'cart'     THEN 5
        WHEN 'purchase' THEN 10
        ELSE 0
    END
) AS interaction_score
```

Alongside it sits `decayed_score`, the same sum with an exponential half life
applied per event. The ranker uses the decayed form, because a basket abandoned
last week says far more about present intent than one abandoned last year.

**`user_category_preferences`**, the taste model. `ROW_NUMBER`, `RANK` and
`DENSE_RANK` all appear, because they answer three different questions:
`ROW_NUMBER` picks exactly one favourite category with no tie ambiguity, `RANK`
reports honest joint favourites, and `DENSE_RANK` takes the top three preference
*levels* rather than the top three rows. `category_affinity` is the share of the
user's decayed engagement landing in that category, so it already sums to 1 per
user and the ranker can blend it without rescaling.

**`product_popularity`**, deliberately not a purchase count. A raw count rewards
whatever has been on the site longest and never decays, which is how a
recommender ends up showing last year's bestseller forever. Three corrections:

1. Funnel weighting, as above.
2. Exponential decay with a 30 day half life against the cutoff.
3. A Bayesian shrink on ratings, so a 5.0 from two people does not outrank a
   4.6 from four hundred.

The output `popularity_score` is a `PERCENT_RANK` over decayed engagement.
Percentile rather than min max because engagement is heavily right skewed: one
runaway bestseller would otherwise compress every other product into the bottom
decile.

## Item to item collaborative filtering in SQL

The premise: two products are similar if the same people engage with both. No
product attributes are used, which is why the matrix can discover that a yoga
mat and a foam roller belong together when nothing in their descriptions says
so. Full implementation in
[`sql/materialized_views.sql`](sql/materialized_views.sql).

### Why not a raw co occurrence count

```sql
SELECT a.product_id, b.product_id, COUNT(DISTINCT a.user_id)
FROM user_product_features a
JOIN user_product_features b ON a.user_id = b.user_id AND a.product_id <> b.product_id
GROUP BY 1, 2
```

This is the naive version, and it is wrong in a specific and predictable way: it
ranks by popularity. The best selling product in the catalogue co occurs with
everything, so it becomes everybody's nearest neighbour and the recommender
degenerates into a bestseller list. Normalisation is the fix.

### Cosine similarity

Treat each product as a vector over users, where the coordinate is that user's
engagement with it:

```
cosine(a, b) = dot(a, b) / (norm(a) * norm(b))
```

Dividing by both norms removes the popularity term. It measures the angle
between the vectors, not their length, so a niche product with 40 devoted buyers
can be a closer neighbour than a bestseller with 4,000 casual viewers.

Jaccard similarity is computed alongside it as a set overlap sanity check.
Jaccard ignores intensity and only asks how much the two audiences overlap, so
when the two metrics disagree sharply the pair is usually an artefact. Having
both is what makes the matrix auditable rather than a black box.

### The query

```sql
signals AS (                       /* log damped engagement            */
    SELECT user_id, product_id, LN(1 + decayed_score) AS weight
    FROM mv_user_product_features WHERE decayed_score > 0
),
capped AS (                        /* keep each user's strongest N     */
    SELECT user_id, product_id, weight FROM (
        SELECT s.*, ROW_NUMBER() OVER (
            PARTITION BY s.user_id ORDER BY s.weight DESC, s.product_id
        ) AS item_rank
        FROM signals AS s
    ) AS ranked CROSS JOIN cfg
    WHERE ranked.item_rank <= cfg.max_items_per_user
),
norms AS (                         /* vector lengths, audience sizes   */
    SELECT product_id, SQRT(SUM(weight * weight)) AS vector_norm, COUNT(*) AS audience_size
    FROM capped GROUP BY product_id
),
pairs AS (                         /* THE SELF JOIN                    */
    SELECT a.product_id AS product_a, b.product_id AS product_b,
           COUNT(*) AS common_users, SUM(a.weight * b.weight) AS dot_product
    FROM capped AS a
    JOIN capped AS b ON a.user_id = b.user_id AND a.product_id < b.product_id
    CROSS JOIN cfg
    GROUP BY a.product_id, b.product_id, cfg.min_common_users
    HAVING COUNT(*) >= cfg.min_common_users
)
```

Three optimisations make this tractable, and they are the difference between a
query that finishes in 30 seconds and one that never finishes at all:

**Log damping.** A user who viewed one product 60 times would otherwise dominate
every pair they touch. `LN(1 + score)` compresses that without losing the
ordering.

**Activity capping.** The self join is quadratic in items per user, so a single
user with 800 interactions contributes 640,000 pairs on their own. `ROW_NUMBER`
keeps each user's strongest 50 items and drops the tail. This is the single
biggest cost control in the file.

**Triangular join.** `a.product_id < b.product_id` computes each unordered pair
once instead of twice, halving the aggregation. The mirrored half is restored
afterwards with a `UNION ALL` over the already aggregated result, not over the
raw join.

A minimum support floor removes pairs backed by one or two people, and a per
product neighbour cap of 50 keeps the matrix a bounded size regardless of how
the catalogue grows. On this dataset that is 98,850 pairs over 1,977 products.

## The ranking query

[`sql/recommendations.sql`](sql/recommendations.sql) is one multi stage CTE
pipeline, stage names matching the concepts:

```sql
WITH cfg                  AS (...),   /* scoring weights from rec_config   */
     profile              AS (...),   /* cold, light or warm               */
     anchors              AS (...),   /* the user's strongest history      */
     purchased            AS (...),   /* the exclusion set                 */
     cf_candidates        AS (...),   /* neighbours of every anchor        */
     category_candidates  AS (...),   /* best of their favourite aisles    */
     trending_candidates  AS (...),   /* cold start only                   */
     candidates           AS (...),   /* deduplicated pool                 */
     filtered             AS (...),   /* purchased and inactive removed    */
     normalised           AS (...),   /* every signal rescaled to 0 to 1   */
     scored               AS (...),   /* the weighted blend                */
     ranked               AS (...)    /* ROW_NUMBER and RANK               */
SELECT ... FROM ranked WHERE row_rank <= p_limit;
```

### Candidate generation

Each anchor is looked up in the similarity matrix, and each neighbour's evidence
is weighted by how strongly the user engaged with the anchor that suggested it:

```
cf_score(candidate) = SUM over anchors of similarity(anchor, candidate) * anchor_weight(anchor)
```

A candidate reached from five different anchors therefore scores well above one
reached from a single weak anchor, which is the desired behaviour: agreement
across a user's history is stronger evidence than one coincidence.

`ARRAY_AGG` with an `ORDER BY` inside it captures which anchor contributed most,
so the explanation can name a concrete product the user already owns.

### Scoring

```
recommendation_score = 0.50 * collaborative_similarity
                     + 0.20 * category_affinity
                     + 0.15 * popularity
                     + 0.10 * product_rating
                     + 0.05 * recency
```

**Normalisation is the part that matters.** Raw cosine similarity lives around
0.02 to 0.4, popularity is already a percentile, and ratings run 1 to 5. Blend
them unnormalised and the weights mean nothing at all, because the largest raw
scale silently wins regardless of what the coefficients say. Every term is min
max scaled inside the candidate set using window aggregates, in one pass:

```sql
COALESCE(
    (f.cf_score - MIN(f.cf_score) OVER ())
    / NULLIF(MAX(f.cf_score) OVER () - MIN(f.cf_score) OVER (), 0),
0) AS n_similarity
```

`NULLIF` guards the degenerate case where every candidate shares a value, which
happens routinely for a cold user whose collaborative score is zero across the
board. `COALESCE` then sends that term to zero so it contributes nothing rather
than poisoning the sum with a `NULL`.

Scaling within the candidate set rather than catalogue wide is deliberate: the
question is which of these candidates is best for this user, not where each
product sits in the catalogue. One consequence worth stating plainly is that
**scores are comparable within one response and not across users**.

### Explanations

Generated from the same normalised components that produced the score, in
descending order of how strong each signal was. The reason is a readout of the
winning term, not a label chosen after the fact:

```sql
CASE
    WHEN r.n_similarity >= r.reason_similarity_cut AND r.supporting_anchors >= 3
        THEN FORMAT('Customers who bought %s also bought this, and %s other items in your history point to it', ...)
    WHEN r.n_category >= r.reason_affinity_cut AND r.preference_rank = 1
        THEN FORMAT('Number %s in %s, the category you shop most', r.popularity_category_rank, r.category_name)
    WHEN r.n_popularity >= r.reason_popularity_cut AND r.momentum > 1.2
        THEN 'Trending right now across the store'
    ...
END
```

### Business rules

Two filters are applied in SQL rather than in the application, so a caller that
forgets to check cannot get it wrong: already purchased products are removed by
an anti join, and withdrawn stock is removed by `is_active`.

The exclusion set carries a predicate that is easy to omit and was omitted in
the first version of this file:

```sql
WHERE o.user_id = p_user_id
  AND o.order_date < rec_as_of()
```

`mv_user_product_features` is already bounded by the cutoff, so the first arm of
the union is safe by construction. The second arm reads the order ledger
directly, and without the cutoff it sees the whole table including orders placed
after it. During a temporal replay that turns the exclusion set into a list of
exactly the products the user is about to buy, and the ranker then filters out
every correct answer. It scored a clean zero on every accuracy metric while the
collaborative baseline scored normally, which is what exposed it. The general
rule: anything reading a base table rather than an `mv_` view has to apply the
cutoff itself.

## Cold start

Three regimes, decided in SQL by `user_recommendation_profile` so that the API,
the dashboard, the evaluation harness and the ranker all agree on what a new
user is.

| Regime | Definition | Candidate sources |
| - | - | - |
| Cold | fewer than 3 distinct products | trending, which is popularity multiplied by momentum and weighted by rating |
| Light | fewer than 10 distinct products | category preferences plus trending plus whatever collaborative evidence exists |
| Warm | everything else | collaborative neighbours plus category preferences |

There is no separate code path. Cold start is handled by *which sources
contribute candidates*; the same scoring, ranking and explanation code then runs
over whatever arrived. A user with no history simply contributes nothing from
the collaborative and category stages.

Two further fallbacks:

**An unknown user id is not an error.** The function returns trending, which is
the correct product behaviour for an anonymous visitor.

**A user whose candidate pool empties out still gets a shelf.** A warm user can
in principle have bought or seen withdrawn everything the matrix suggests.
`IF NOT FOUND` returns trending, so a non empty result is part of the function's
contract rather than something the API layer has to remember.

Product cold start is handled too. A product added yesterday has no row in the
similarity matrix at all, so `get_similar_products` falls back to content
similarity over a generated `tsvector`: the new product's name, brand and
subcategory become a full text query against the rest of the catalogue.
Behaviour first, text second, never nothing.

## Why materialized views

A recommendation request has a latency budget of a few milliseconds and the work
it depends on does not fit in it. The similarity matrix alone aggregates
millions of co occurrence pairs.

| View | Rows | What it costs to build |
| - | -: | - |
| `mv_user_product_features` | 380,230 | aggregation over 1.2 M interactions |
| `mv_user_category_preferences` | 17,303 | rollup plus four window functions |
| `mv_product_popularity` | 2,000 | decay, Bayesian shrink, percentile rank |
| `mv_product_trend` | 1,977 | weekly buckets with `LAG` and a moving average |
| `mv_product_similarity` | 98,850 | the self join, millions of pairs |

Every one carries a `UNIQUE` index. That is not decoration: it is the
precondition for `REFRESH MATERIALIZED VIEW CONCURRENTLY`, which rebuilds
without an exclusive lock so recommendations keep serving from the previous
snapshot while the next one builds.

There are two refresh paths, and the difference is worth knowing.
`refresh_recommendation_layer()` uses plain `REFRESH`, because a function body
runs inside a transaction and PostgreSQL forbids `CONCURRENTLY` there. That is
correct for the initial build and for the evaluation replay, where nothing is
serving. The production path is `python/pipeline.py`, which issues
`CONCURRENTLY` in autocommit mode outside any transaction.

One PostgreSQL 17 behaviour is load bearing here and cost an hour to diagnose:
maintenance commands including `CREATE MATERIALIZED VIEW` and `REFRESH
MATERIALIZED VIEW` execute with a restricted `search_path`. An unqualified table
reference inside a function called by the view definition resolves to nothing,
and the whole materialized layer fails to build. `rec_as_of()` and
`rec_setting()` therefore reference `public.pipeline_state` and
`public.rec_config` explicitly, rather than carrying a `SET search_path` clause,
which would block the planner from inlining them.

## Indexing and query optimization

Indexes are created after the bulk load, because building an index once over a
finished table beats maintaining it across a million inserts. Every index in
[`sql/indexes.sql`](sql/indexes.sql) names the query it exists for; an index
without a caller is a cost, not an asset.

[`python/benchmark.py`](python/benchmark.py) measures each one by dropping it,
timing the query, restoring it and timing again. The index definition is read
from `pg_indexes` before the drop and replayed verbatim, so there is no second
copy of the DDL to drift. Timings are the median `Execution Time` from
`EXPLAIN (ANALYZE, BUFFERS)` over five runs after a warm up pass, so both sides
read a warm cache. Full report in
[`docs/query_optimization.md`](docs/query_optimization.md).

| Query | Without index | With index | Speedup |
| - | -: | -: | -: |
| Anchor lookup for one user | 96.824 ms | 0.432 ms | **224x** |
| Recent demand for one product | 25.473 ms | 0.265 ms | **96x** |
| Neighbour lookup in the similarity matrix | 10.186 ms | 0.368 ms | **28x** |
| Full text catalogue search | 0.522 ms | 0.111 ms | **4.7x** |
| Purchase exclusion set | 0.023 ms | 0.011 ms | 2.1x |

### The two that matter most

**Anchor lookup.** Stage 2 of every recommendation request.

```
Without:  Parallel Seq Scan on user_interactions      96.824 ms
With:     Index Only Scan using idx_interactions_user_product     0.432 ms
```

```sql
CREATE INDEX idx_interactions_user_product
    ON user_interactions (user_id, product_id)
    INCLUDE (interaction_timestamp, interaction_type);
```

The `INCLUDE` payload is what makes it an *index only* scan. Without it the
planner finds the rows in the index and then visits the heap for the timestamp
and type, which on a 1.2 million row table means random I/O across the whole
relation.

**Recent demand for one product.** The shape of every trend and popularity
query: one product, one time window.

```sql
CREATE INDEX idx_interactions_product_time
    ON user_interactions (product_id, interaction_timestamp DESC);
```

Column order is the whole trick. Leading with `product_id` puts the equality
predicate first and the range predicate second, where the scan can terminate
early. Reversed, the index would have to be scanned across every product in the
window.

### The honest one

Dropping `idx_interactions_purchases` does not produce a sequential scan; it
falls back to the broad composite index, which already answers the query well.
That partial index earns its place on size rather than speed: 4.7 MB against the
49 MB composite it displaces, which is what keeps it resident in cache under
memory pressure. Reporting it at 2.1x rather than dropping it from the table is
the point.

## Evaluation methodology

[`python/evaluate.py`](python/evaluate.py) and
[`sql/evaluation.sql`](sql/evaluation.sql).

### The split

The interaction log is split on a single timestamp, chosen with
`PERCENTILE_DISC` at the 80th percentile of the event timeline rather than a
calendar date, so the split lands where the data actually is and stays a fixed
proportion of history if the generator's window changes. `PERCENTILE_DISC` and
not `PERCENTILE_CONT`: the continuous variant interpolates and is therefore only
defined for numeric and interval inputs, while the discrete variant returns an
actual observed value and works on timestamps.

### How leakage is prevented

The tempting shortcut is to build the similarity matrix over all the data and
then hold out a random slice of purchases. It produces excellent numbers and
they mean nothing, because the matrix already encoded the held out purchases
when it was built.

Instead the harness calls `set_pipeline_as_of(cutoff)`, which moves
`pipeline_state.as_of_timestamp` and rebuilds every materialized view behind it.
Because every feature, every similarity score and every popularity rank reads
its horizon from `rec_as_of()`, the post cutoff events become invisible to the
entire pipeline at once. There is no per query `WHERE` clause to forget.

The enforcement is structural, but it is not magic, as the exclusion set bug
described earlier demonstrates: a query that reads a base table still has to
apply the cutoff itself.

### What is measured

Ground truth is the set of products a user **purchased** after the cutoff and
had **not** purchased before it. Purchases rather than views, because a purchase
is the outcome the business cares about. New purchases only, because re
recommending something already owned is excluded by the ranker anyway and would
otherwise be free credit.

Users are **not** filtered on history length. Requiring, say, five prior
interactions is tempting and is the wrong call: it quietly removes exactly the
users cold start handling exists for, and it flatters pure collaborative
filtering, which cannot serve them at all.

Python computes precision, recall, hit rate and NDCG from ranked lists that
PostgreSQL produced. It never scores, ranks or filters a candidate. All three
strategies are asked the same question through one SQL dispatcher,
`eval_strategy_recommendations`, so the harness has no opportunity to treat one
differently from another.

## SQL techniques, and where to find them

Every entry below is doing a job. None was inserted to tick a box.

| Technique | Where | What it is for |
| - | - | - |
| `ROW_NUMBER()` | `user_category_preferences`, similarity capping, final ranking | one favourite category per user; capping each user's contribution to the self join; a stable gapless shelf order |
| `RANK()` | `product_popularity`, final ranking | honest joint positions where products genuinely tie |
| `DENSE_RANK()` | `user_category_preferences` | the top three preference *levels*, not the top three rows |
| `LAG()` | `mv_product_trend`, analytics 03, 15, 20, 25 | week over week momentum; month over month growth; order cadence |
| `LEAD()` | `mv_product_trend`, analytics 03 | forward looking comparison without a self join |
| `SUM() OVER ()` | score normalisation, analytics 01, 02, 18 | grand totals and running totals in one pass |
| `AVG() OVER (...)` | `mv_product_trend`, analytics 03 | trailing moving averages that smooth low volume noise |
| `COUNT() OVER ()` | analytics 18 | catalogue size alongside each row for the Pareto curve |
| `PERCENT_RANK()` | `product_popularity`, `user_category_preferences`, analytics 19 | normalising a right skewed distribution to 0 to 1 |
| `NTILE()` | `product_popularity`, analytics 05 | demand tiers and customer value deciles |
| `FIRST_VALUE()` | analytics 24 | labelling each order against the customer's first |
| `FILTER (WHERE ...)` | throughout | several conditional aggregates in one pass |
| Self join | `mv_product_similarity`, analytics 12, 21 | item to item similarity; market basket; category crossover |
| Anti join with `NOT EXISTS` | ranker, analytics 14 | excluding purchased products; cross sell target lists |
| Recursive CTE alternative | analytics 15 | gaps and islands for consecutive month streaks |
| Materialized views | `sql/materialized_views.sql` | the offline online split |
| Generated columns | `products.search_document` | `tsvector` computed on write, indexed with GIN |
| Full text search | `search_products`, product cold start | catalogue search; content fallback for new products |
| Partial indexes | `idx_interactions_purchases`, `idx_products_active_category` | small hot indexes over the rows that are actually queried |
| Covering indexes | `idx_interactions_user_product` | index only scans, no heap visits |
| `CROSS JOIN LATERAL` | ranker, evaluation harness | per row function calls, and config carried through a pipeline |
| Ordered set aggregates | `evaluation_cutoff`, analytics 04 | percentiles over timestamps and over money |
| `WIDTH_BUCKET()` | analytics 22 | log scale bucketing of a three order of magnitude price range |
| `GENERATE_SERIES` | analytics 16 | dense cohort retention grids, so an empty month is a zero and not a missing row |

## The synthetic dataset

No dataset was available, so the project generates one.
[`python/generate_data.py`](python/generate_data.py) and
[`python/catalog.py`](python/catalog.py).

| Table | Rows |
| - | -: |
| users | 10,000 |
| categories | 8 |
| products | 2,000 (1,920 active) |
| orders | 53,109 |
| order_items | 152,292 |
| user_interactions | 1,213,873 |
| ratings | 48,151 |

Interaction mix: 762,571 views, 48,408 wishlist saves, 244,772 cart additions,
151,921 purchases. Seeded, so a regenerated dataset is identical.

A recommender evaluated on random data measures nothing: uniformly sampled
interactions contain no co occurrence structure, so the similarity matrix comes
out as noise and every metric lands at the popularity baseline. Three kinds of
structure are planted and then hidden.

**Taste.** Twelve personas, each a weighted distribution over 47 subcategories:
`audio_enthusiast`, `pc_builder`, `console_gamer`, `fashion_forward`, `runner`,
`outdoors`, `bookworm`, `tech_reader`, `home_cook`, `home_maker`,
`beauty_shopper`, `parent`. The persona mix is uneven on purpose, because a
uniform split would make every category equally popular.

**Complements.** 540 specific product pairs are bundled across complementary
subcategories such as laptops and keyboards, or running shoes and sportswear.
Buying one pulls the other into a later session through an intent queue. This is
the signal item to item filtering exists to find, and the pairs are never
written to the database: their only trace is in behaviour, which is exactly the
situation a real recommender faces.

**Demand skew.** Product appeal follows a power law inside each aisle, so the
catalogue has a head and a long tail. Without it, popularity would be
meaningless and the popularity baseline untestable.

Also modelled: weekday and seasonal demand curves with a November and December
lift, accelerating signups so the newest cohort is genuinely cold, per user
price sensitivity, heavy tailed engagement, latent product quality driving both
star ratings and conversion, and 4 percent of the catalogue retired while
keeping its history so the ranker has to filter it at serving time.

**One honest caveat.** The funnel is compressed. Roughly a third of seriously
considered products get bought here, against low single digit percentages in
real retail. Generating a realistic conversion rate alongside the requested
152,000 order lines would need a view log of fifteen million rows, which would
make the project tedious to run without changing anything it demonstrates. The
ordering of the funnel stages and the relative weight of each signal are
preserved; only the absolute conversion rate is optimistic.

Brands are invented, built to sound like real retail brands without being any
particular company's trademark.

## What Python does, and what it deliberately does not

**Does:** generate the dataset, `COPY` it in, run the SQL files in dependency
order, refresh materialized views concurrently, compute evaluation metrics from
SQL produced lists, benchmark indexes, serve HTTP, render a dashboard.

**Does not:** compute a feature, a similarity, a popularity score, a candidate
set, a rank or a filter. There is no scoring code outside PostgreSQL.

That boundary is worth defending. The moment ranking logic starts leaking into
the service layer, the dashboard, the batch jobs and the API each grow their own
slightly different version of it, and the database stops being the source of
truth for what a good recommendation is. Keeping it sharp means the evaluation
harness measures exactly what the API serves.

There is also no ORM and no query builder. Every query that matters lives in
`sql/` where it can be read.

## API

```
FastAPI  ──▶  PostgreSQL function  ──▶  SQL pipeline  ──▶  PostgreSQL
```

No endpoint scores, ranks, filters, sorts or merges anything. Each calls a
single PostgreSQL function and serialises the rows.

| Endpoint | Calls |
| - | - |
| `GET /health` | pipeline mode, cutoff, similarity matrix size |
| `GET /recommendations/{user_id}?limit=10` | `get_recommendations` |
| `GET /products/{product_id}/similar?limit=10` | `get_similar_products` |
| `GET /products/search?q=...` | `search_products` |
| `GET /trending?limit=10` | `get_trending_products` |
| `GET /evaluation` | the latest evaluation report |

```bash
curl "http://127.0.0.1:8000/recommendations/2?limit=3"
```

The health check reports the similarity matrix size, because a recommender with
an empty matrix answers every request successfully and uselessly.

Connections come from a pool opened at startup: a request is a few milliseconds
of query time, so a TCP handshake and authentication per request would dominate
the response.

## Dashboard

```bash
make dashboard
```

Four tabs, all reading what PostgreSQL computed:

- **User recommendations.** Pick a user by tier, see their purchase history, the
  category preference model built from it, and their shelf with scores and
  reasons.
- **Product similarity.** Search the catalogue, see a product's demand profile,
  and see its nearest neighbours with the relationship type.
- **Catalogue.** Popularity leaderboard, revenue by category, monthly revenue.
- **Model evaluation.** The three strategies compared across all metrics, with
  catalogue coverage and the per tier breakdown.

## Analytics library

[`sql/analytics.sql`](sql/analytics.sql) holds 25 standalone analytical queries.
Nothing there creates an object, and `python/pipeline.py` does not run it;
[`tests/test_analytics.py`](tests/test_analytics.py) executes every one on every
test pass, because a query library nobody runs rots quietly.

Revenue by product, category and month. Average order value and basket size.
Customer lifetime value with deciles. Repeat purchase rate by acquisition
category. Purchase frequency distribution. Most viewed and highest converting
products. Trending products. Favourite and second favourite category per
customer. Market basket analysis with support, confidence and lift. Nearest
neighbours. Customers who bought X but not Y. Consecutive month streaks. Cohort
retention. Product rank within category. Pareto revenue concentration. Top decile
customers. The conversion funnel. Category crossover. Price band performance.
Brand performance. New against returning revenue. Order cadence and churn signal.

## Project structure

```
sql-recommender-engine/
├── sql/
│   ├── schema.sql               tables, constraints, control tables, accessors
│   ├── indexes.sql              every index, each naming the query it serves
│   ├── views.sql                the feature layer
│   ├── materialized_views.sql   offline layer and the similarity matrix
│   ├── recommendations.sql      the ranker, product to product, search
│   ├── analytics.sql            25 standalone analytical queries
│   └── evaluation.sql           temporal harness and the two baselines
├── python/
│   ├── config.py                all settings, no command line flags anywhere
│   ├── db.py                    thin connection helpers, no ORM
│   ├── catalog.py               taxonomy, brands, personas, complement pairs
│   ├── generate_data.py         synthetic data generation
│   ├── load_data.py             bulk load via COPY
│   ├── pipeline.py              build and refresh orchestration
│   ├── evaluate.py              temporal evaluation and metrics
│   └── benchmark.py             index before and after timings
├── api/main.py                  FastAPI over the SQL functions
├── dashboard/app.py             Streamlit
├── tests/                       55 tests against a real database
├── docs/                        generated evaluation and optimization reports
├── data/                        generated CSVs, not committed
├── docker-compose.yml
├── Makefile
├── requirements.txt
└── .env.example
```

## Known limitations

Stated because they are the first things a reviewer should ask about.

**The dataset is synthetic, and the structure the recommender finds was planted
there.** That is unavoidable without real data, and the evaluation is honest
about it: the popularity baseline is measured on the same data, and the gap
between the two is the claim.

**The funnel is compressed**, as described above.

**Recommendation scores are not comparable across users.** They are min max
normalised within one candidate set. A cold user's top score around 0.29 and a
warm user's around 0.92 say nothing about which recommendation is better.

**The similarity matrix is rebuilt in full.** Incremental maintenance is
possible and is not implemented; at this catalogue size a full rebuild takes 30
seconds and is not worth the complexity.

**Popularity bias is measured but not corrected.** 98 percent of recommendations
come from the head of the demand curve. Catalogue coverage is reported alongside
precision so the tradeoff is visible, and the fix would be an inverse popularity
penalty in the blend.

**There is no online evaluation.** Offline metrics on held out purchases are a
proxy for what an A/B test would measure, and they systematically favour
recommending things users would have found anyway.





