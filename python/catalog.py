"""
The synthetic world: catalogue taxonomy, brands, product vocabulary and the
behavioural personas that drive demand.

This module holds no logic. It is the content that makes the generated data
look like a real storefront instead of random integers, kept separate from
generate_data.py so the taxonomy can be read, reviewed and extended on its own.

Brands are invented. They are built to sound like real retail brands without
being any particular company's trademark.
"""

from __future__ import annotations

# ===========================================================================
# Taxonomy: category -> subcategories
# ===========================================================================

TAXONOMY: dict[str, list[str]] = {
    "Electronics": [
        "Headphones", "Speakers", "Laptops", "Keyboards", "Mice",
        "Monitors", "Smartphones", "Phone Accessories", "Smartwatches", "Cameras",
    ],
    "Fashion": [
        "Running Shoes", "Sneakers", "Sportswear", "Jackets",
        "Denim", "Handbags", "Watches", "Sunglasses",
    ],
    "Books": [
        "Fiction", "Science Fiction", "Technology Books",
        "Business Books", "Cookbooks", "Children Books",
    ],
    "Home and Kitchen": [
        "Cookware", "Kitchen Gadgets", "Coffee and Tea",
        "Bedding", "Lighting", "Storage",
    ],
    "Sports and Outdoors": [
        "Yoga and Fitness", "Camping", "Cycling", "Hiking Gear", "Water Bottles",
    ],
    "Beauty": [
        "Skincare", "Haircare", "Fragrance", "Makeup",
    ],
    "Toys and Games": [
        "Board Games", "Puzzles", "Building Sets", "Educational Toys",
    ],
    "Gaming": [
        "Consoles", "Video Games", "Gaming Accessories", "PC Components",
    ],
}

SUBCATEGORY_TO_CATEGORY: dict[str, str] = {
    sub: cat for cat, subs in TAXONOMY.items() for sub in subs
}
ALL_SUBCATEGORIES: list[str] = list(SUBCATEGORY_TO_CATEGORY)


# ===========================================================================
# Brands, scoped to the aisles they plausibly compete in
# ===========================================================================

BRANDS_BY_CATEGORY: dict[str, list[str]] = {
    "Electronics": [
        "Aurex", "Volta", "Northbeam", "Kestrel", "Lumen Labs",
        "Pantheon", "Halcyon", "Arclight", "Meridian", "Sable",
    ],
    "Fashion": [
        "Marlowe", "Kestrel", "Verity", "Ashgrove", "Solene",
        "Trailhead", "Copperline", "Nordvik",
    ],
    "Books": [
        "Thornfield Press", "Blue Harbour Books", "Quill and Anchor",
        "Ironwood Press", "Lantern House", "Meridian Press",
    ],
    "Home and Kitchen": [
        "Hearthstone", "Copperline", "Willowbrook", "Stillwater",
        "Brassmill", "Northbeam",
    ],
    "Sports and Outdoors": [
        "Trailhead", "Summit Nine", "Nordvik", "Ridgeline",
        "Quarry", "Kestrel",
    ],
    "Beauty": [
        "Solene", "Verity", "Lumen Labs", "Petal and Ash", "Cassia",
    ],
    "Toys and Games": [
        "Tinderbox", "Puffin Row", "Cogsworth", "Bright Meadow", "Willowbrook",
    ],
    "Gaming": [
        "Arclight", "Pantheon", "Volta", "Nexus Forge", "Halcyon",
    ],
}


# ===========================================================================
# Product naming: a head noun per subcategory plus modifiers
# ===========================================================================

PRODUCT_NOUNS: dict[str, list[str]] = {
    "Headphones": ["Wireless Headphones", "Noise Cancelling Headphones", "Studio Headphones", "Earbuds"],
    "Speakers": ["Bluetooth Speaker", "Bookshelf Speaker", "Portable Speaker", "Soundbar"],
    "Laptops": ["Ultrabook Laptop", "Creator Laptop", "Everyday Laptop", "Workstation Laptop"],
    "Keyboards": ["Mechanical Keyboard", "Wireless Keyboard", "Low Profile Keyboard", "Ergonomic Keyboard"],
    "Mice": ["Wireless Mouse", "Ergonomic Mouse", "Precision Mouse", "Trackball Mouse"],
    "Monitors": ["Ultrawide Monitor", "4K Monitor", "Portable Monitor", "Colour Grading Monitor"],
    "Smartphones": ["Smartphone", "Compact Smartphone", "Camera Smartphone", "Rugged Smartphone"],
    "Phone Accessories": ["Phone Case", "Charging Dock", "Screen Protector", "Magnetic Car Mount"],
    "Smartwatches": ["Smartwatch", "Fitness Watch", "Hybrid Smartwatch", "Sports Watch"],
    "Cameras": ["Mirrorless Camera", "Compact Camera", "Action Camera", "Instant Camera"],
    "Running Shoes": ["Running Shoes", "Trail Running Shoes", "Racing Flats", "Marathon Shoes"],
    "Sneakers": ["Sneakers", "Court Sneakers", "Canvas Sneakers", "Retro Trainers"],
    "Sportswear": ["Training Tee", "Performance Leggings", "Running Shorts", "Track Jacket"],
    "Jackets": ["Rain Jacket", "Down Jacket", "Windbreaker", "Quilted Jacket"],
    "Denim": ["Slim Jeans", "Straight Jeans", "Denim Jacket", "Relaxed Jeans"],
    "Handbags": ["Shoulder Bag", "Tote Bag", "Crossbody Bag", "Leather Satchel"],
    "Watches": ["Automatic Watch", "Field Watch", "Dress Watch", "Chronograph Watch"],
    "Sunglasses": ["Polarised Sunglasses", "Aviator Sunglasses", "Round Sunglasses", "Sport Sunglasses"],
    "Fiction": ["Novel", "Short Story Collection", "Literary Novel", "Historical Novel"],
    "Science Fiction": ["Science Fiction Novel", "Space Opera", "Cyberpunk Novel", "Time Travel Novel"],
    "Technology Books": ["Programming Guide", "Systems Design Handbook", "Database Handbook", "Machine Learning Primer"],
    "Business Books": ["Strategy Handbook", "Negotiation Guide", "Leadership Handbook", "Startup Playbook"],
    "Cookbooks": ["Cookbook", "Baking Cookbook", "Weeknight Cookbook", "Regional Cookbook"],
    "Children Books": ["Picture Book", "Bedtime Story Book", "First Reader", "Activity Book"],
    "Cookware": ["Cast Iron Skillet", "Saucepan Set", "Nonstick Frying Pan", "Dutch Oven"],
    "Kitchen Gadgets": ["Digital Kitchen Scale", "Immersion Blender", "Mandoline Slicer", "Food Thermometer"],
    "Coffee and Tea": ["Pour Over Coffee Maker", "Burr Grinder", "French Press", "Electric Kettle"],
    "Bedding": ["Linen Duvet Cover", "Cotton Sheet Set", "Weighted Blanket", "Memory Foam Pillow"],
    "Lighting": ["Floor Lamp", "Desk Lamp", "Pendant Light", "Smart Bulb Set"],
    "Storage": ["Storage Basket Set", "Stackable Bins", "Under Bed Organiser", "Shelving Unit"],
    "Yoga and Fitness": ["Yoga Mat", "Foam Roller", "Resistance Band Set", "Adjustable Dumbbells"],
    "Camping": ["Two Person Tent", "Sleeping Bag", "Camp Stove", "Camping Lantern"],
    "Cycling": ["Cycling Helmet", "Bike Computer", "Cycling Jersey", "Bike Repair Kit"],
    "Hiking Gear": ["Hiking Backpack", "Trekking Poles", "Hiking Boots", "Headlamp"],
    "Water Bottles": ["Insulated Water Bottle", "Collapsible Bottle", "Hydration Flask", "Sports Bottle"],
    "Skincare": ["Vitamin C Serum", "Daily Moisturiser", "Gentle Cleanser", "Mineral Sunscreen"],
    "Haircare": ["Repair Shampoo", "Leave In Conditioner", "Scalp Treatment", "Hair Oil"],
    "Fragrance": ["Eau de Parfum", "Cologne", "Travel Fragrance Set", "Solid Perfume"],
    "Makeup": ["Liquid Foundation", "Eyeshadow Palette", "Lip Balm Set", "Setting Powder"],
    "Board Games": ["Strategy Board Game", "Party Board Game", "Cooperative Board Game", "Card Game"],
    "Puzzles": ["1000 Piece Puzzle", "Wooden Puzzle", "3D Puzzle", "Logic Puzzle Set"],
    "Building Sets": ["Building Brick Set", "Marble Run Set", "Magnetic Tile Set", "Model Kit"],
    "Educational Toys": ["Coding Robot", "Science Kit", "Counting Blocks", "Microscope Kit"],
    "Consoles": ["Home Console", "Handheld Console", "Retro Console", "Console Bundle"],
    "Video Games": ["Open World Game", "Racing Game", "Strategy Game", "Platformer Game"],
    "Gaming Accessories": ["Gaming Headset", "Controller", "Gaming Mousepad", "Console Charging Stand"],
    "PC Components": ["Graphics Card", "Mechanical SSD Drive", "CPU Cooler", "Power Supply Unit"],
}

MODIFIERS = [
    "Pro", "Plus", "Lite", "Max", "Studio", "Elite", "Classic",
    "Signature", "Everyday", "Compact", "Prime", "Core", "Edition Two",
]

FEATURE_PHRASES: dict[str, list[str]] = {
    "Electronics": [
        "low latency wireless connection", "USB C fast charging", "aluminium unibody chassis",
        "adaptive noise cancellation", "40 hour battery life", "multipoint pairing",
        "high resolution audio support", "anti glare coating",
    ],
    "Fashion": [
        "breathable recycled mesh upper", "water repellent finish", "reinforced stitching",
        "responsive cushioned midsole", "four way stretch fabric", "full grain leather",
        "packable lightweight shell", "moisture wicking lining",
    ],
    "Books": [
        "paperback edition with a sewn binding", "includes an updated afterword",
        "illustrated throughout", "widely reviewed debut", "annotated reference edition",
        "accessible for newcomers to the subject", "worked examples in every chapter",
    ],
    "Home and Kitchen": [
        "oven safe to 260 degrees", "dishwasher safe components", "pre seasoned cooking surface",
        "stackable for compact storage", "brushed stainless steel finish",
        "hand finished stoneware", "quiet motor with a soft start",
    ],
    "Sports and Outdoors": [
        "ripstop weather resistant shell", "packs down to bottle size",
        "vacuum insulated for 24 hours", "non slip textured grip",
        "certified impact protection", "tool free assembly", "trail tested construction",
    ],
    "Beauty": [
        "fragrance free and dermatologist tested", "suitable for sensitive skin",
        "non comedogenic lightweight formula", "cruelty free and vegan",
        "refillable glass container", "clinically tested for four weeks",
    ],
    "Toys and Games": [
        "for two to six players", "plays in about forty minutes",
        "suitable for ages eight and up", "includes a full colour rulebook",
        "durable moulded storage insert", "award nominated design",
    ],
    "Gaming": [
        "supports 120 frames per second", "low latency wireless receiver",
        "hot swappable switches", "RGB lighting with onboard profiles",
        "tournament grade build quality", "includes a two year warranty",
    ],
}


# ===========================================================================
# Complement pairs: subcategories people buy together
# ===========================================================================
# These drive the co occurrence structure that item to item collaborative
# filtering is supposed to discover. Without planted structure the similarity
# matrix would be noise, and the evaluation would be measuring nothing.

COMPLEMENT_PAIRS: list[tuple[str, str]] = [
    ("Headphones", "Phone Accessories"),
    ("Headphones", "Smartphones"),
    ("Speakers", "Headphones"),
    ("Laptops", "Keyboards"),
    ("Laptops", "Mice"),
    ("Laptops", "Monitors"),
    ("Keyboards", "Mice"),
    ("Monitors", "PC Components"),
    ("Smartphones", "Phone Accessories"),
    ("Smartwatches", "Sportswear"),
    ("Running Shoes", "Sportswear"),
    ("Running Shoes", "Water Bottles"),
    ("Yoga and Fitness", "Sportswear"),
    ("Yoga and Fitness", "Water Bottles"),
    ("Cycling", "Water Bottles"),
    ("Cycling", "Sportswear"),
    ("Camping", "Hiking Gear"),
    ("Camping", "Jackets"),
    ("Hiking Gear", "Water Bottles"),
    ("Cookware", "Kitchen Gadgets"),
    ("Cookware", "Cookbooks"),
    ("Coffee and Tea", "Kitchen Gadgets"),
    ("Bedding", "Lighting"),
    ("Lighting", "Storage"),
    ("Skincare", "Haircare"),
    ("Skincare", "Makeup"),
    ("Fragrance", "Makeup"),
    ("Board Games", "Puzzles"),
    ("Building Sets", "Educational Toys"),
    ("Children Books", "Educational Toys"),
    ("Consoles", "Video Games"),
    ("Consoles", "Gaming Accessories"),
    ("Video Games", "Gaming Accessories"),
    ("PC Components", "Gaming Accessories"),
    ("Technology Books", "Business Books"),
    ("Fiction", "Science Fiction"),
    ("Sneakers", "Denim"),
    ("Denim", "Jackets"),
    ("Handbags", "Sunglasses"),
    ("Watches", "Sunglasses"),
]


# ===========================================================================
# Personas
# ===========================================================================
# Each persona is a taste profile: the aisles it lives in, with weights. The
# recommender never sees the label. It has to rediscover the structure from
# behaviour alone, which is the entire point of the exercise.

PERSONAS: dict[str, dict[str, float]] = {
    "audio_enthusiast": {
        "Headphones": 0.30, "Speakers": 0.22, "Phone Accessories": 0.14,
        "Smartphones": 0.12, "Smartwatches": 0.10, "Technology Books": 0.06,
        "Gaming Accessories": 0.06,
    },
    "pc_builder": {
        "PC Components": 0.26, "Keyboards": 0.20, "Mice": 0.16,
        "Monitors": 0.16, "Laptops": 0.10, "Gaming Accessories": 0.08,
        "Technology Books": 0.04,
    },
    "console_gamer": {
        "Consoles": 0.22, "Video Games": 0.32, "Gaming Accessories": 0.24,
        "Headphones": 0.10, "Monitors": 0.06, "Board Games": 0.06,
    },
    "fashion_forward": {
        "Sneakers": 0.24, "Handbags": 0.18, "Sunglasses": 0.14,
        "Denim": 0.16, "Watches": 0.12, "Jackets": 0.10, "Fragrance": 0.06,
    },
    "runner": {
        "Running Shoes": 0.30, "Sportswear": 0.24, "Water Bottles": 0.14,
        "Smartwatches": 0.14, "Yoga and Fitness": 0.12, "Cycling": 0.06,
    },
    "outdoors": {
        "Camping": 0.24, "Hiking Gear": 0.24, "Jackets": 0.16,
        "Water Bottles": 0.14, "Cycling": 0.12, "Sportswear": 0.10,
    },
    "bookworm": {
        "Fiction": 0.34, "Science Fiction": 0.26, "Children Books": 0.12,
        "Business Books": 0.10, "Cookbooks": 0.10, "Board Games": 0.08,
    },
    "tech_reader": {
        "Technology Books": 0.32, "Business Books": 0.22, "Laptops": 0.16,
        "Keyboards": 0.12, "Monitors": 0.10, "Science Fiction": 0.08,
    },
    "home_cook": {
        "Cookware": 0.28, "Kitchen Gadgets": 0.24, "Coffee and Tea": 0.22,
        "Cookbooks": 0.16, "Storage": 0.10,
    },
    "home_maker": {
        "Bedding": 0.26, "Lighting": 0.22, "Storage": 0.20,
        "Cookware": 0.14, "Kitchen Gadgets": 0.10, "Coffee and Tea": 0.08,
    },
    "beauty_shopper": {
        "Skincare": 0.32, "Haircare": 0.24, "Makeup": 0.24,
        "Fragrance": 0.14, "Handbags": 0.06,
    },
    "parent": {
        "Children Books": 0.24, "Educational Toys": 0.22, "Building Sets": 0.20,
        "Puzzles": 0.14, "Board Games": 0.14, "Storage": 0.06,
    },
}

# Share of the user base drawn from each persona. Uneven on purpose: a uniform
# split would make every category equally popular, which no storefront is.
PERSONA_MIX: dict[str, float] = {
    "audio_enthusiast": 0.10,
    "pc_builder": 0.07,
    "console_gamer": 0.09,
    "fashion_forward": 0.11,
    "runner": 0.10,
    "outdoors": 0.07,
    "bookworm": 0.10,
    "tech_reader": 0.06,
    "home_cook": 0.09,
    "home_maker": 0.07,
    "beauty_shopper": 0.08,
    "parent": 0.06,
}

# Typical price band per subcategory, in currency units. Drawn log normally
# around the midpoint so each aisle has a believable spread rather than a
# uniform smear from 5 to 2000.
PRICE_BANDS: dict[str, tuple[float, float]] = {
    "Headphones": (29, 420), "Speakers": (35, 650), "Laptops": (480, 2600),
    "Keyboards": (35, 260), "Mice": (18, 160), "Monitors": (140, 1200),
    "Smartphones": (220, 1400), "Phone Accessories": (9, 85),
    "Smartwatches": (70, 720), "Cameras": (260, 2400),
    "Running Shoes": (55, 230), "Sneakers": (45, 210), "Sportswear": (18, 120),
    "Jackets": (60, 420), "Denim": (40, 190), "Handbags": (55, 680),
    "Watches": (80, 950), "Sunglasses": (25, 320),
    "Fiction": (7, 26), "Science Fiction": (7, 24), "Technology Books": (22, 72),
    "Business Books": (14, 46), "Cookbooks": (16, 52), "Children Books": (6, 22),
    "Cookware": (25, 340), "Kitchen Gadgets": (12, 140), "Coffee and Tea": (18, 480),
    "Bedding": (30, 280), "Lighting": (22, 320), "Storage": (12, 130),
    "Yoga and Fitness": (15, 260), "Camping": (35, 520), "Cycling": (20, 400),
    "Hiking Gear": (30, 320), "Water Bottles": (12, 55),
    "Skincare": (11, 95), "Haircare": (8, 65), "Fragrance": (25, 190),
    "Makeup": (9, 80),
    "Board Games": (15, 90), "Puzzles": (9, 48), "Building Sets": (18, 190),
    "Educational Toys": (14, 130),
    "Consoles": (180, 720), "Video Games": (20, 80),
    "Gaming Accessories": (18, 220), "PC Components": (60, 1800),
}

CITIES: list[str] = [
    "Bengaluru", "Mumbai", "Delhi", "Hyderabad", "Chennai", "Pune",
    "Kolkata", "Ahmedabad", "Jaipur", "Kochi", "Lucknow", "Chandigarh",
    "Indore", "Bhubaneswar", "Coimbatore", "Nagpur",
]
