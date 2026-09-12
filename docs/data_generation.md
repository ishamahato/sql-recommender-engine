# Synthetic data generation

Produced by `python -m python.generate_data`, defined in
[`python/generate_data.py`](../python/generate_data.py) and
[`python/catalog.py`](../python/catalog.py). Seeded, so a regenerated dataset is
identical.

## The problem this has to solve

A recommender evaluated on random data measures nothing. Uniformly sampled
interactions contain no co occurrence structure, so the similarity matrix comes
out as noise, every strategy lands at the popularity baseline, and the
evaluation reports a number that means nothing at all.

The generator therefore plants structure and then hides it. The recommender
never sees any of the generating parameters; its only input is the interaction
log, which is exactly the situation a real system is in.

## What gets planted

### Taste

Twelve personas, each a weighted distribution over the 47 subcategories.

| Persona | Lives in |
| - | - |
| `audio_enthusiast` | headphones, speakers, phone accessories, smartwatches |
| `pc_builder` | PC components, keyboards, mice, monitors, laptops |
| `console_gamer` | consoles, video games, gaming accessories |
| `fashion_forward` | sneakers, handbags, sunglasses, denim, watches |
| `runner` | running shoes, sportswear, water bottles, smartwatches |
| `outdoors` | camping, hiking gear, jackets, cycling |
| `bookworm` | fiction, science fiction, children books |
| `tech_reader` | technology books, business books, laptops |
| `home_cook` | cookware, kitchen gadgets, coffee and tea, cookbooks |
| `home_maker` | bedding, lighting, storage |
| `beauty_shopper` | skincare, haircare, makeup, fragrance |
| `parent` | children books, educational toys, building sets, puzzles |

The mix is uneven on purpose. A uniform split would make every category equally
popular, which no storefront is.

The persona label is written to `users.persona` but never read by the
recommender. It exists so `tests/test_recommendations.py` can assert two things
that together define personalisation: that users from different personas receive
mostly different shelves, and that users from the *same* persona agree more than
users from different ones. The second test is the one that matters, because
producing different output is easy and producing output that tracks taste is not.

### Complements

540 specific product pairs are bundled across complementary subcategories:
laptops and keyboards, running shoes and sportswear, consoles and video games,
cookware and kitchen gadgets, skincare and haircare, and 35 other pairings.

Buying one pushes the other onto an intent queue, which the next session draws
from before anything else. This is the mechanism that creates genuine item to
item co occurrence, and it is the signal collaborative filtering exists to find.

The pairs are never written to the database. Their only trace is in behaviour.

### Demand skew

Product appeal follows a power law inside each aisle, so the catalogue has a head
and a long tail. Without it, popularity would be meaningless and the popularity
baseline would be untestable.

## The funnel

Each user gets a number of sessions drawn from their signup date, a heavy tailed
activity multiplier and the day level demand curve. A session picks a focus
subcategory from the persona distribution, draws products weighted by appeal and
price fit, and walks them through the funnel.

| Stage | Rate |
| - | -: |
| Repeat view of the same product in a session | 0.45 |
| Wishlist given a view | 0.09, scaled by product fit |
| Cart given a view | 0.55, scaled by product fit |
| Purchase given a cart | 0.62 |
| Rating given a purchase | 0.34 |

Product fit combines latent quality, which the shopper can partly see, with how
close the price sits to that shopper's comfortable band.

### The honest caveat

The funnel is compressed. Roughly a third of seriously considered products get
bought here, against low single digit percentages in real retail.

Generating a realistic conversion rate alongside 152,000 order lines would need a
view log of around fifteen million rows. That would make the project tedious to
run and would not change anything it demonstrates. The ordering of the funnel
stages and the relative weight of each signal are preserved; only the absolute
conversion rate is optimistic.

## Everything else that is modelled

- **Seasonality.** Weekday and weekend demand differ, November and December lift
  by 40 percent, and the store grows slowly across the window. All three show up
  in the monthly revenue and cohort queries in `sql/analytics.sql`.
- **Accelerating signups**, so the newest cohort is genuinely cold and the cold
  start path has real users to serve.
- **Latent product quality**, which drives both the star rating and the
  conversion rate, so the conversion analytics have something real to find.
- **Price sensitivity per user**, so a budget shopper and a premium shopper
  behave differently inside the same aisle.
- **Heavy tailed engagement**, so most users are quiet and a few live on the
  site. This is what makes the activity cap in the similarity build necessary.
- **4 percent of the catalogue retired** while keeping its history, so the ranker
  has to filter withdrawn stock at serving time rather than never seeing it.
- **Ratings only from purchasers**, biased by product quality and by whether the
  product fits that persona.

## Output

| File | Rows |
| - | -: |
| `data/categories.csv` | 8 |
| `data/products.csv` | 2,000 |
| `data/users.csv` | 10,000 |
| `data/orders.csv` | 53,109 |
| `data/order_items.csv` | 152,292 |
| `data/user_interactions.csv` | 1,213,873 |
| `data/ratings.csv` | 48,151 |

Around 15 seconds to generate, 57 MB on disk, loaded by `COPY` in 21 seconds.
The CSVs are not committed; regenerate them with `make generate`.

## Brands

All invented, built to sound like real retail brands without being any
particular company's trademark: Aurex, Volta, Northbeam, Kestrel, Lumen Labs,
Pantheon, Halcyon, Arclight, Meridian, Sable, Marlowe, Verity, Trailhead,
Hearthstone, Solene, Nexus Forge and a dozen others, scoped to the aisles they
plausibly compete in.
