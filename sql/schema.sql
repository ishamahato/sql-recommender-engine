/*
===============================================================================
 schema.sql
===============================================================================
 Base relational model for the SQL first recommendation engine.

 DESIGN NOTES

 1. Every fact table carries a surrogate key plus the natural foreign keys the
    recommendation pipeline joins on. The pipeline is join heavy, so the keys
    are narrow integer types rather than text.

 2. `user_interactions` is the behavioural spine of the system. It is append
    only and is the single input to the feature layer. Orders exist alongside
    it for revenue analytics, and every purchase is written to BOTH tables so
    that behavioural queries and financial queries agree.

 3. `pipeline_state.as_of_timestamp` is the cutoff every derived object reads
    through `rec_as_of()`. Nothing in the feature, similarity or ranking layer
    ever calls `now()`. That single indirection is what makes the temporal
    evaluation in evaluation.sql leak free: rewind the cutoff, refresh, and the
    whole pipeline behaves as if the future had not happened yet.

 4. `rec_config` holds the scoring blend weights as data. Retuning the ranker
    is an UPDATE, not a code deploy, which is also what makes an A/B test
    possible without shipping SQL.
===============================================================================
*/

BEGIN;

DROP TABLE IF EXISTS ratings              CASCADE;
DROP TABLE IF EXISTS user_interactions    CASCADE;
DROP TABLE IF EXISTS order_items          CASCADE;
DROP TABLE IF EXISTS orders               CASCADE;
DROP TABLE IF EXISTS products             CASCADE;
DROP TABLE IF EXISTS categories           CASCADE;
DROP TABLE IF EXISTS users                CASCADE;
DROP TABLE IF EXISTS interaction_weights  CASCADE;
DROP TABLE IF EXISTS rec_config           CASCADE;
DROP TABLE IF EXISTS pipeline_state       CASCADE;

/*
===============================================================================
 Reference and control tables
===============================================================================
*/

/* Single row control table. The CHECK plus the primary key make a second row
   impossible, so `rec_as_of()` can never become ambiguous. */
CREATE TABLE pipeline_state (
    is_singleton        BOOLEAN     PRIMARY KEY DEFAULT TRUE,
    as_of_timestamp     TIMESTAMP   NOT NULL,
    mode                TEXT        NOT NULL DEFAULT 'production',
    last_refreshed_at   TIMESTAMP,
    CONSTRAINT pipeline_state_one_row CHECK (is_singleton),
    CONSTRAINT pipeline_state_mode_valid CHECK (mode IN ('production', 'evaluation'))
);

/* Scoring knobs. Kept as rows so the ranker can be retuned without a deploy. */
CREATE TABLE rec_config (
    config_key      TEXT            PRIMARY KEY,
    config_value    NUMERIC(10, 4)  NOT NULL,
    description     TEXT            NOT NULL
);

/* Behavioural weights. The feature view spells the weights out in a CASE so the
   scoring rule is readable at the point of use; this table is the documented
   reference for those numbers and is what analytics.sql joins against. */
CREATE TABLE interaction_weights (
    interaction_type    TEXT            PRIMARY KEY,
    weight              NUMERIC(5, 2)   NOT NULL CHECK (weight > 0),
    funnel_stage        SMALLINT        NOT NULL
);

/*
===============================================================================
 Dimensions
===============================================================================
*/

CREATE TABLE users (
    user_id         INTEGER     PRIMARY KEY,
    age             SMALLINT    NOT NULL CHECK (age BETWEEN 13 AND 99),
    gender          TEXT        NOT NULL CHECK (gender IN ('female', 'male', 'other')),
    city            TEXT        NOT NULL,
    signup_date     DATE        NOT NULL,
    /* Denormalised label describing the behavioural archetype the synthetic
       user was drawn from. The recommender never reads it. It exists so that
       tests can assert that users with different tastes receive different
       recommendations. */
    persona         TEXT        NOT NULL
);

CREATE TABLE categories (
    category_id     INTEGER     PRIMARY KEY,
    category_name   TEXT        NOT NULL UNIQUE
);

CREATE TABLE products (
    product_id      INTEGER         PRIMARY KEY,
    category_id     INTEGER         NOT NULL REFERENCES categories (category_id),
    subcategory     TEXT            NOT NULL,
    brand           TEXT            NOT NULL,
    name            TEXT            NOT NULL,
    description     TEXT            NOT NULL,
    price           NUMERIC(10, 2)  NOT NULL CHECK (price > 0),
    rating          NUMERIC(3, 2)   NOT NULL CHECK (rating BETWEEN 0 AND 5),
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMP       NOT NULL,
    /* Generated full text column. Stored rather than computed per query so the
       GIN index in indexes.sql can be a plain index on a real column, and so
       catalogue search costs nothing at read time. Weighting puts the product
       name above the brand and the brand above the free text body. */
    search_document  TSVECTOR GENERATED ALWAYS AS (
          setweight(to_tsvector('english', coalesce(name, '')),        'A')
       || setweight(to_tsvector('english', coalesce(brand, '')),       'B')
       || setweight(to_tsvector('english', coalesce(subcategory, '')), 'B')
       || setweight(to_tsvector('english', coalesce(description, '')), 'C')
    ) STORED
);

/*
===============================================================================
 Facts
===============================================================================
*/

CREATE TABLE orders (
    order_id        INTEGER         PRIMARY KEY,
    user_id         INTEGER         NOT NULL REFERENCES users (user_id),
    order_date      TIMESTAMP       NOT NULL,
    total_amount    NUMERIC(12, 2)  NOT NULL CHECK (total_amount >= 0)
);

CREATE TABLE order_items (
    order_item_id   BIGINT          PRIMARY KEY,
    order_id        INTEGER         NOT NULL REFERENCES orders (order_id) ON DELETE CASCADE,
    product_id      INTEGER         NOT NULL REFERENCES products (product_id),
    quantity        SMALLINT        NOT NULL CHECK (quantity > 0),
    unit_price      NUMERIC(10, 2)  NOT NULL CHECK (unit_price > 0),
    /* A product may legitimately appear once per order only. Enforcing it here
       means the basket analysis queries in analytics.sql never need DISTINCT. */
    CONSTRAINT order_items_unique_product_per_order UNIQUE (order_id, product_id)
);

CREATE TABLE user_interactions (
    interaction_id          BIGINT      PRIMARY KEY,
    user_id                 INTEGER     NOT NULL REFERENCES users (user_id),
    product_id              INTEGER     NOT NULL REFERENCES products (product_id),
    interaction_type        TEXT        NOT NULL REFERENCES interaction_weights (interaction_type),
    interaction_timestamp   TIMESTAMP   NOT NULL
);

CREATE TABLE ratings (
    rating_id   BIGINT      PRIMARY KEY,
    user_id     INTEGER     NOT NULL REFERENCES users (user_id),
    product_id  INTEGER     NOT NULL REFERENCES products (product_id),
    rating      SMALLINT    NOT NULL CHECK (rating BETWEEN 1 AND 5),
    created_at  TIMESTAMP   NOT NULL,
    /* One opinion per user per product. */
    CONSTRAINT ratings_unique_user_product UNIQUE (user_id, product_id)
);

/*
===============================================================================
 Seed the control tables
===============================================================================
*/

INSERT INTO interaction_weights (interaction_type, weight, funnel_stage) VALUES
    ('view',      1,  1),
    ('wishlist',  3,  2),
    ('cart',      5,  3),
    ('purchase', 10,  4);

INSERT INTO rec_config (config_key, config_value, description) VALUES
    ('weight_similarity',        0.50, 'Share of the final score driven by item to item collaborative filtering'),
    ('weight_category',          0.20, 'Share driven by the user affinity for the candidate category'),
    ('weight_popularity',        0.15, 'Share driven by time decayed catalogue popularity'),
    ('weight_rating',            0.10, 'Share driven by the average product rating'),
    ('weight_recency',           0.05, 'Share driven by how recently the candidate was engaged with catalogue wide'),
    ('popularity_half_life',    30.00, 'Days after which an interaction contributes half as much popularity'),
    ('affinity_half_life',      60.00, 'Days after which an interaction contributes half as much category affinity'),
    ('max_anchors_per_user',    50.00, 'Cap on the number of history items used to seed candidate generation'),
    ('max_neighbours_per_item', 50.00, 'Cap on stored neighbours per product in the similarity matrix'),
    ('min_common_users',         3.00, 'Minimum co occurring users before a product pair is considered similar'),
    ('cold_start_threshold',     3.00, 'Distinct products below which a user is treated as cold'),
    ('light_user_threshold',    10.00, 'Distinct products below which a user is treated as light'),
    ('reason_similarity_cut',    0.80, 'Normalised similarity above which the reason cites collaborative evidence'),
    ('reason_affinity_cut',      0.70, 'Normalised category affinity above which the reason cites the category'),
    ('reason_popularity_cut',    0.80, 'Normalised popularity above which the reason cites trending status');

/* Bootstrapped by load_data.py to the maximum observed interaction timestamp. */
INSERT INTO pipeline_state (is_singleton, as_of_timestamp, mode)
VALUES (TRUE, '2000-01-01 00:00:00', 'production');

/*
===============================================================================
 Accessors
===============================================================================
*/

/*
 The clock the whole pipeline runs on.

 Marked STABLE so the planner evaluates it once per statement and can still
 fold it into index conditions. Every derived object filters interactions with
 `interaction_timestamp < rec_as_of()` and measures recency against it, so
 rewinding this one value rewinds the entire recommender.

 The table reference is schema qualified, and that is load bearing. Since
 PostgreSQL 17, maintenance commands including CREATE MATERIALIZED VIEW and
 REFRESH MATERIALIZED VIEW execute with a restricted search_path as a hardening
 measure, so an unqualified `pipeline_state` inside this body resolves to
 nothing during a refresh and the whole materialized layer fails to build.
 Qualifying the reference fixes it without attaching a SET search_path clause to
 the function, which would block the planner from inlining the body into the
 calling query.
*/
CREATE OR REPLACE FUNCTION rec_as_of()
RETURNS TIMESTAMP
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT as_of_timestamp FROM public.pipeline_state;
$$;

/* Typed lookup into rec_config, so scoring queries read weights by name
   instead of embedding magic numbers. Schema qualified for the same reason as
   rec_as_of above. */
CREATE OR REPLACE FUNCTION rec_setting(p_key TEXT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT config_value FROM public.rec_config WHERE config_key = p_key;
$$;

/*
 Exponential time decay shared by the popularity and affinity layers.

     weight(age) = 0.5 ^ (age_in_days / half_life)

 An event at the cutoff counts fully, one a half life old counts half, and the
 curve is smooth so there are no cliff edges between refreshes. The reference
 time is a parameter rather than a call to `rec_as_of()` so the function can be
 IMMUTABLE, which lets the planner constant fold it inside large aggregations.
*/
CREATE OR REPLACE FUNCTION rec_decay(
    p_event_time    TIMESTAMP,
    p_reference     TIMESTAMP,
    p_half_life     NUMERIC
)
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT power(
        0.5,
        GREATEST(EXTRACT(EPOCH FROM (p_reference - p_event_time)), 0) / 86400.0 / p_half_life
    );
$$;

COMMIT;
