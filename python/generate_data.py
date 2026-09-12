"""
Synthetic e commerce data generation.

WHAT THIS HAS TO GET RIGHT

A recommender evaluated on random data measures nothing. Uniformly sampled
interactions contain no co occurrence structure, so the similarity matrix comes
out as noise and every metric lands at the popularity baseline. The generator
therefore plants three kinds of structure and then hides them:

  1. TASTE.       Every user is drawn from one of twelve personas, each a
                  weighted distribution over aisles. The recommender never sees
                  the label; it has to rediscover the clustering from behaviour.

  2. COMPLEMENTS. Specific product pairs are bundled across complementary
                  subcategories. Buying one pulls the other into a later
                  session. This is the signal item to item filtering exists to
                  find, and it is why a laptop can recommend a keyboard.

  3. DEMAND SKEW. Product appeal follows a power law within each aisle, so the
                  catalogue has a head and a long tail like a real storefront.
                  Without it, popularity would be meaningless and the popularity
                  baseline would be untestable.

Everything else is a funnel: users browse sessions, some views become wishlist
saves, some become carts, some carts convert to orders, and some purchases
become ratings.

ONE HONEST CAVEAT

The funnel is compressed. Roughly a third of seriously considered products get
bought here, against low single digit percentages in real retail. Generating a
realistic conversion rate alongside the requested 155k order lines would need a
view log of fifteen million rows, which would make the project tedious to run
without changing anything it demonstrates. The ORDERING of the funnel stages
and the relative weight of each signal are preserved; only the absolute
conversion rate is optimistic.

Output: one CSV per table in data/, ready for COPY.
"""

from __future__ import annotations

import csv
import math
import time
from collections import defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path

import numpy as np

from python import catalog
from python.config import DATA_DIR, GEN

DATA_END = datetime.fromisoformat(GEN.data_end_date)
DATA_START = DATA_END - timedelta(days=GEN.history_days)

MEAN_SESSIONS_FULL_WINDOW = 12.6
MEAN_VIEWS_PER_SESSION = 8.2
MAX_VIEWS_PER_SESSION = 16
INACTIVE_PRODUCT_SHARE = 0.04


# ===========================================================================
# Day level seasonality
# ===========================================================================

def build_day_weights() -> tuple[list[date], np.ndarray]:
    """
    Relative shopping intensity for every day in the history window.

    Three effects, all of which show up later in the monthly revenue and cohort
    queries in analytics.sql:
      weekends are busier than midweek,
      November and December lift hard,
      and the store grows slowly over the whole window.
    """
    days = [(DATA_START + timedelta(days=i)).date() for i in range(GEN.history_days)]
    weights = np.zeros(len(days))

    weekday_factor = {0: 0.95, 1: 0.92, 2: 0.94, 3: 1.00, 4: 1.12, 5: 1.28, 6: 1.20}
    month_factor = {
        1: 0.88, 2: 0.86, 3: 0.95, 4: 0.98, 5: 1.02, 6: 1.00,
        7: 1.04, 8: 1.06, 9: 1.05, 10: 1.18, 11: 1.42, 12: 1.34,
    }

    for i, day in enumerate(days):
        growth = 0.72 + 0.56 * (i / len(days))
        weights[i] = weekday_factor[day.weekday()] * month_factor[day.month] * growth

    return days, weights


# ===========================================================================
# Catalogue
# ===========================================================================

def build_categories() -> list[dict]:
    return [
        {"category_id": idx, "category_name": name}
        for idx, name in enumerate(catalog.TAXONOMY, start=1)
    ]


def allocate_products_per_subcategory(rng: np.random.Generator) -> dict[str, int]:
    """
    Spread the catalogue across aisles in proportion to how much demand the
    persona mix sends there, with a floor so no aisle is too thin to recommend
    within.
    """
    demand = defaultdict(float)
    for persona, share in catalog.PERSONA_MIX.items():
        for sub, weight in catalog.PERSONAS[persona].items():
            demand[sub] += share * weight

    subs = catalog.ALL_SUBCATEGORIES
    raw = np.array([demand.get(sub, 0.0) + 0.004 for sub in subs])
    raw = raw / raw.sum()

    floor = 18
    remaining = GEN.n_products - floor * len(subs)
    counts = {sub: floor for sub in subs}

    extra = rng.multinomial(remaining, raw)
    for sub, n in zip(subs, extra):
        counts[sub] += int(n)
    return counts


def build_products(rng: np.random.Generator, categories: list[dict]) -> list[dict]:
    category_ids = {c["category_name"]: c["category_id"] for c in categories}
    counts = allocate_products_per_subcategory(rng)

    products: list[dict] = []
    product_id = 1

    for sub, n in counts.items():
        category = catalog.SUBCATEGORY_TO_CATEGORY[sub]
        brands = catalog.BRANDS_BY_CATEGORY[category]
        nouns = catalog.PRODUCT_NOUNS[sub]
        low, high = catalog.PRICE_BANDS[sub]

        # Appeal follows a power law inside the aisle: a handful of hero
        # products, a long tail of also rans.
        appeal = 1.0 / np.power(np.arange(1, n + 1), 0.85)
        appeal = appeal[rng.permutation(n)]
        appeal = appeal / appeal.sum()

        log_mid = (math.log(low) + math.log(high)) / 2
        log_spread = (math.log(high) - math.log(low)) / 4.4

        for i in range(n):
            brand = brands[rng.integers(len(brands))]
            noun = nouns[rng.integers(len(nouns))]

            name_parts = [brand]
            if rng.random() < 0.55:
                name_parts.append(catalog.MODIFIERS[rng.integers(len(catalog.MODIFIERS))])
            name_parts.append(noun)
            name = " ".join(name_parts)
            if rng.random() < 0.40:
                name = f"{name} {int(rng.integers(2, 10))}"

            price = float(np.exp(rng.normal(log_mid, log_spread)))
            price = round(min(max(price, low * 0.7), high * 1.4), 2)

            # Latent quality drives both the star rating and how often a view
            # converts, which is what gives the conversion analytics something
            # real to find.
            quality = float(rng.beta(6.0, 2.4))
            star_rating = round(2.6 + 2.3 * quality + float(rng.normal(0, 0.12)), 2)
            star_rating = min(max(star_rating, 1.0), 5.0)

            age_days = int(rng.integers(20, GEN.history_days + 120))
            created_at = DATA_END - timedelta(days=age_days)

            features = catalog.FEATURE_PHRASES[category]
            chosen = rng.choice(len(features), size=3, replace=False)
            feature_text = ", ".join(features[int(c)] for c in chosen)
            description = (
                f"The {name} is a {sub.lower()} product from {brand}. "
                f"Built for everyday use with {feature_text}. "
                f"Part of the {brand} {sub.lower()} range."
            )

            products.append({
                "product_id": product_id,
                "category_id": category_ids[category],
                "category_name": category,
                "subcategory": sub,
                "brand": brand,
                "name": name,
                "description": description,
                "price": price,
                "rating": star_rating,
                "is_active": True,
                "created_at": created_at,
                "appeal": float(appeal[i]),
                "quality": quality,
            })
            product_id += 1

    # Retire a slice of the weakest sellers. They keep their history, so the
    # ranker has to filter them out at serving time rather than never seeing
    # them, which is the situation a real catalogue is always in.
    order = sorted(products, key=lambda p: p["appeal"])
    for p in order[: int(len(products) * INACTIVE_PRODUCT_SHARE)]:
        p["is_active"] = False

    return products


def build_bundles(rng: np.random.Generator, products: list[dict]) -> dict[int, list[int]]:
    """
    Plant explicit cross aisle product pairs.

    These are the ground truth that item to item collaborative filtering should
    recover. They are never written to the database: the only trace they leave
    is in behaviour, which is exactly the situation a real recommender faces.
    """
    by_sub: dict[str, list[dict]] = defaultdict(list)
    for p in products:
        by_sub[p["subcategory"]].append(p)

    bundles: dict[int, list[int]] = defaultdict(list)
    pairs = catalog.COMPLEMENT_PAIRS

    for _ in range(GEN.n_product_bundles):
        sub_a, sub_b = pairs[rng.integers(len(pairs))]
        pool_a, pool_b = by_sub[sub_a], by_sub[sub_b]
        if not pool_a or not pool_b:
            continue

        # Bias toward products people actually see, so the planted pairs
        # accumulate enough co occurrence to clear the min_common_users floor.
        weights_a = np.array([p["appeal"] for p in pool_a])
        weights_b = np.array([p["appeal"] for p in pool_b])
        a = pool_a[int(rng.choice(len(pool_a), p=weights_a / weights_a.sum()))]
        b = pool_b[int(rng.choice(len(pool_b), p=weights_b / weights_b.sum()))]

        if a["product_id"] == b["product_id"]:
            continue
        bundles[a["product_id"]].append(b["product_id"])
        bundles[b["product_id"]].append(a["product_id"])

    return bundles


# ===========================================================================
# Users
# ===========================================================================

AGE_BANDS = {
    "audio_enthusiast": (18, 40), "pc_builder": (18, 38), "console_gamer": (15, 34),
    "fashion_forward": (18, 42), "runner": (22, 48), "outdoors": (24, 55),
    "bookworm": (20, 62), "tech_reader": (24, 50), "home_cook": (26, 58),
    "home_maker": (28, 62), "beauty_shopper": (18, 45), "parent": (27, 47),
}


def build_users(rng: np.random.Generator, days: list[date], day_weights: np.ndarray) -> list[dict]:
    persona_names = list(catalog.PERSONA_MIX)
    persona_p = np.array([catalog.PERSONA_MIX[p] for p in persona_names])

    # Signups accelerate over the window, so the tail of the user base is
    # genuinely new and genuinely cold. Those users are the cold start test.
    signup_weights = day_weights * np.linspace(0.5, 2.4, len(days))
    signup_weights = signup_weights / signup_weights.sum()

    persona_idx = rng.choice(len(persona_names), size=GEN.n_users, p=persona_p)
    signup_idx = rng.choice(len(days), size=GEN.n_users, p=signup_weights)

    users = []
    for uid in range(1, GEN.n_users + 1):
        persona = persona_names[int(persona_idx[uid - 1])]
        low, high = AGE_BANDS[persona]
        users.append({
            "user_id": uid,
            "age": int(rng.integers(low, high + 1)),
            "gender": ["female", "male", "other"][int(rng.choice(3, p=[0.49, 0.48, 0.03]))],
            "city": catalog.CITIES[int(rng.integers(len(catalog.CITIES)))],
            "signup_date": days[int(signup_idx[uid - 1])],
            "persona": persona,
            # Heavy tailed engagement: most users are quiet, a few live here.
            "activity": float(np.exp(rng.normal(0.0, 0.72))),
            # Where in the price distribution this shopper is comfortable.
            "budget": float(np.clip(rng.normal(0.5, 0.22), 0.05, 0.95)),
        })
    return users


# ===========================================================================
# Behaviour
# ===========================================================================

def build_subcategory_pools(products: list[dict]) -> dict[str, tuple[np.ndarray, np.ndarray]]:
    """Per subcategory: product ids and their appeal weights, ready for sampling."""
    pools: dict[str, tuple[list[int], list[float]]] = {}
    grouped: dict[str, list[dict]] = defaultdict(list)
    for p in products:
        grouped[p["subcategory"]].append(p)

    out = {}
    for sub, items in grouped.items():
        ids = np.array([p["product_id"] for p in items], dtype=np.int64)
        weights = np.array([p["appeal"] for p in items], dtype=np.float64)
        out[sub] = (ids, weights / weights.sum())
    return out


def complement_subcategories() -> dict[str, list[str]]:
    out: dict[str, list[str]] = defaultdict(list)
    for a, b in catalog.COMPLEMENT_PAIRS:
        out[a].append(b)
        out[b].append(a)
    return out


class Writers:
    """CSV sinks. Rows are streamed so peak memory stays flat."""

    def __init__(self, directory: Path):
        directory.mkdir(parents=True, exist_ok=True)
        self._handles = {}
        self.writers = {}
        specs = {
            "user_interactions": ["interaction_id", "user_id", "product_id",
                                  "interaction_type", "interaction_timestamp"],
            "orders": ["order_id", "user_id", "order_date", "total_amount"],
            "order_items": ["order_item_id", "order_id", "product_id",
                            "quantity", "unit_price"],
            "ratings": ["rating_id", "user_id", "product_id", "rating", "created_at"],
        }
        for name, header in specs.items():
            handle = open(directory / f"{name}.csv", "w", newline="", encoding="utf-8")
            writer = csv.writer(handle)
            writer.writerow(header)
            self._handles[name] = handle
            self.writers[name] = writer

    def close(self):
        for handle in self._handles.values():
            handle.close()


def generate_behaviour(
    rng: np.random.Generator,
    users: list[dict],
    products: list[dict],
    bundles: dict[int, list[int]],
    days: list[date],
    day_weights: np.ndarray,
    writers: Writers,
) -> dict[str, int]:
    product_by_id = {p["product_id"]: p for p in products}
    pools = build_subcategory_pools(products)
    complements = complement_subcategories()

    # Price percentile per product inside its own aisle, so "expensive" means
    # expensive for a pair of running shoes, not expensive in absolute terms.
    by_sub_prices: dict[str, list[float]] = defaultdict(list)
    for p in products:
        by_sub_prices[p["subcategory"]].append(p["price"])
    sorted_prices = {sub: np.sort(np.array(v)) for sub, v in by_sub_prices.items()}
    for p in products:
        arr = sorted_prices[p["subcategory"]]
        p["price_pct"] = float(np.searchsorted(arr, p["price"]) / max(len(arr), 1))

    day_index = {d: i for i, d in enumerate(days)}

    interaction_id = 0
    order_id = 0
    order_item_id = 0
    rating_id = 0
    counts = defaultdict(int)

    iw = writers.writers["user_interactions"]
    ow = writers.writers["orders"]
    oiw = writers.writers["order_items"]
    rw = writers.writers["ratings"]

    for user in users:
        persona_weights = catalog.PERSONAS[user["persona"]]
        sub_names = list(persona_weights)
        sub_probs = np.array([persona_weights[s] for s in sub_names])

        start = day_index[user["signup_date"]]
        window = day_weights[start:]
        if window.sum() <= 0:
            continue
        window_p = window / window.sum()

        active_fraction = len(window) / len(days)
        expected = MEAN_SESSIONS_FULL_WINDOW * active_fraction * user["activity"]
        n_sessions = int(rng.poisson(max(expected, 0.15)))
        if n_sessions == 0:
            continue

        session_days = np.sort(rng.choice(len(window), size=n_sessions, p=window_p))
        intent_queue: list[int] = []
        owned: set[int] = set()

        for offset in session_days:
            day = days[start + int(offset)]
            session_start = datetime.combine(
                day, datetime.min.time()
            ) + timedelta(
                hours=float(rng.integers(7, 23)), minutes=float(rng.integers(0, 60))
            )
            if session_start >= DATA_END:
                continue

            focus = sub_names[int(rng.choice(len(sub_names), p=sub_probs))]
            n_views = 1 + int(rng.poisson(MEAN_VIEWS_PER_SESSION))
            n_views = min(n_views, MAX_VIEWS_PER_SESSION)

            viewed: list[int] = []

            # Unfinished business first: complements of things already bought.
            while intent_queue and len(viewed) < n_views and rng.random() < 0.85:
                candidate = intent_queue.pop()
                if candidate not in owned and candidate not in viewed:
                    viewed.append(candidate)

            while len(viewed) < n_views:
                if rng.random() < 0.28 and complements.get(focus):
                    sub = complements[focus][int(rng.integers(len(complements[focus])))]
                elif rng.random() < 0.12:
                    sub = sub_names[int(rng.choice(len(sub_names), p=sub_probs))]
                else:
                    sub = focus

                ids, weights = pools[sub]
                pid = int(rng.choice(ids, p=weights))
                if pid not in viewed:
                    viewed.append(pid)

            cart_this_session: list[int] = []
            clock = session_start

            for pid in viewed:
                product = product_by_id[pid]
                clock = clock + timedelta(seconds=float(rng.integers(25, 400)))
                if clock >= DATA_END:
                    break

                interaction_id += 1
                iw.writerow([interaction_id, user["user_id"], pid, "view", clock])
                counts["view"] += 1

                if rng.random() < GEN.p_repeat_view:
                    clock = clock + timedelta(seconds=float(rng.integers(20, 300)))
                    interaction_id += 1
                    iw.writerow([interaction_id, user["user_id"], pid, "view", clock])
                    counts["view"] += 1

                # How well this product fits the shopper: quality they can see,
                # and a price they are comfortable with.
                price_gap = abs(product["price_pct"] - user["budget"])
                fit = product["quality"] * math.exp(-3.1 * price_gap * price_gap)

                if rng.random() < GEN.p_wishlist_given_view * (0.5 + fit):
                    clock = clock + timedelta(seconds=float(rng.integers(5, 60)))
                    interaction_id += 1
                    iw.writerow([interaction_id, user["user_id"], pid, "wishlist", clock])
                    counts["wishlist"] += 1

                if pid in owned:
                    continue

                if rng.random() < 0.55 * (0.45 + fit):
                    clock = clock + timedelta(seconds=float(rng.integers(10, 120)))
                    interaction_id += 1
                    iw.writerow([interaction_id, user["user_id"], pid, "cart", clock])
                    counts["cart"] += 1
                    cart_this_session.append(pid)

            if not cart_this_session:
                continue

            # dict.fromkeys preserves order while removing any repeat of the
            # same product inside one basket, which the order_items unique
            # constraint rightly refuses.
            bought = [pid for pid in dict.fromkeys(cart_this_session)
                      if rng.random() < GEN.p_purchase_given_cart]
            if not bought:
                continue

            order_id += 1
            order_time = clock + timedelta(seconds=float(rng.integers(30, 600)))
            if order_time >= DATA_END:
                order_time = DATA_END - timedelta(seconds=1)

            total = 0.0
            for pid in bought:
                product = product_by_id[pid]
                quantity = 1 if rng.random() < 0.86 else int(rng.integers(2, 4))
                discount = 1.0 if rng.random() < 0.72 else round(float(rng.uniform(0.72, 0.96)), 2)
                unit_price = round(product["price"] * discount, 2)
                total += unit_price * quantity

                order_item_id += 1
                oiw.writerow([order_item_id, order_id, pid, quantity, unit_price])

                interaction_id += 1
                iw.writerow([interaction_id, user["user_id"], pid, "purchase", order_time])
                counts["purchase"] += 1
                owned.add(pid)

                # The planted structure enters behaviour here and nowhere else.
                for partner in bundles.get(pid, []):
                    if partner not in owned and rng.random() < GEN.p_complement_followup:
                        intent_queue.append(partner)

                if rng.random() < GEN.p_rating_given_purchase:
                    rating_time = order_time + timedelta(
                        days=float(rng.integers(2, 22)), hours=float(rng.integers(0, 24))
                    )
                    if rating_time < DATA_END:
                        persona_fit = 1.0 if product["subcategory"] in persona_weights else 0.62
                        score = 2.2 + 2.6 * product["quality"] * persona_fit + float(rng.normal(0, 0.75))
                        rating_id += 1
                        rw.writerow([
                            rating_id, user["user_id"], pid,
                            int(min(max(round(score), 1), 5)), rating_time,
                        ])
                        counts["rating"] += 1

            ow.writerow([order_id, user["user_id"], order_time, round(total, 2)])

    counts["orders"] = order_id
    counts["order_items"] = order_item_id
    counts["interactions"] = interaction_id
    return dict(counts)


# ===========================================================================
# Entry point
# ===========================================================================

def write_static_csv(path: Path, header: list[str], rows: list[list]) -> None:
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(header)
        writer.writerows(rows)


def main() -> None:
    started = time.perf_counter()
    rng = np.random.default_rng(GEN.seed)

    print(f"Generating synthetic dataset with seed {GEN.seed}")
    print(f"  window: {DATA_START.date()} to {DATA_END.date()}")

    days, day_weights = build_day_weights()

    categories = build_categories()
    products = build_products(rng, categories)
    bundles = build_bundles(rng, products)
    users = build_users(rng, days, day_weights)

    DATA_DIR.mkdir(parents=True, exist_ok=True)

    write_static_csv(
        DATA_DIR / "categories.csv",
        ["category_id", "category_name"],
        [[c["category_id"], c["category_name"]] for c in categories],
    )
    write_static_csv(
        DATA_DIR / "products.csv",
        ["product_id", "category_id", "subcategory", "brand", "name",
         "description", "price", "rating", "is_active", "created_at"],
        [[p["product_id"], p["category_id"], p["subcategory"], p["brand"], p["name"],
          p["description"], p["price"], p["rating"], p["is_active"], p["created_at"]]
         for p in products],
    )
    write_static_csv(
        DATA_DIR / "users.csv",
        ["user_id", "age", "gender", "city", "signup_date", "persona"],
        [[u["user_id"], u["age"], u["gender"], u["city"], u["signup_date"], u["persona"]]
         for u in users],
    )

    writers = Writers(DATA_DIR)
    try:
        counts = generate_behaviour(
            rng, users, products, bundles, days, day_weights, writers
        )
    finally:
        writers.close()

    elapsed = time.perf_counter() - started
    print(f"  categories        {len(categories):>10,}")
    print(f"  products          {len(products):>10,}")
    print(f"  users             {len(users):>10,}")
    print(f"  orders            {counts['orders']:>10,}")
    print(f"  order items       {counts['order_items']:>10,}")
    print(f"  interactions      {counts['interactions']:>10,}")
    print(f"    views           {counts['view']:>10,}")
    print(f"    wishlist        {counts['wishlist']:>10,}")
    print(f"    cart            {counts['cart']:>10,}")
    print(f"    purchase        {counts['purchase']:>10,}")
    print(f"  ratings           {counts['rating']:>10,}")
    print(f"  bundled pairs     {len(bundles):>10,}")
    print(f"Done in {elapsed:.1f}s")


if __name__ == "__main__":
    main()
