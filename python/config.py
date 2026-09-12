"""
Configuration for every Python entry point in the project.

All tunables live here or in the environment. No script takes command line
flags: a pipeline that is configured in one place is a pipeline you can run
identically from a shell, from cron, from CI and from a notebook.

Values are read from the environment, falling back to the defaults below, which
match the docker-compose service.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

from dotenv import load_dotenv

PROJECT_ROOT = Path(__file__).resolve().parent.parent

load_dotenv(PROJECT_ROOT / ".env")

DATA_DIR = PROJECT_ROOT / "data"
SQL_DIR = PROJECT_ROOT / "sql"
DOCS_DIR = PROJECT_ROOT / "docs"


@dataclass(frozen=True)
class DatabaseSettings:
    """Connection settings for the PostgreSQL instance."""

    host: str = os.getenv("DB_HOST", "localhost")
    port: int = int(os.getenv("DB_PORT", "5433"))
    name: str = os.getenv("DB_NAME", "recsys")
    user: str = os.getenv("DB_USER", "recsys")
    password: str = os.getenv("DB_PASSWORD", "recsys")

    @property
    def dsn(self) -> str:
        return (
            f"host={self.host} port={self.port} dbname={self.name} "
            f"user={self.user} password={self.password}"
        )

    @property
    def maintenance_dsn(self) -> str:
        """Connection to the default database, used to create or drop `name`."""
        return (
            f"host={self.host} port={self.port} dbname=postgres "
            f"user={self.user} password={self.password}"
        )


@dataclass(frozen=True)
class GenerationSettings:
    """
    Size and shape of the synthetic dataset.

    The seed is fixed so that a regenerated dataset is byte identical. Every
    number quoted in the README was produced with this seed.
    """

    seed: int = int(os.getenv("GEN_SEED", "20260912"))

    n_users: int = int(os.getenv("GEN_USERS", "10000"))
    n_products: int = int(os.getenv("GEN_PRODUCTS", "2000"))

    history_days: int = int(os.getenv("GEN_HISTORY_DAYS", "540"))
    data_end_date: str = os.getenv("GEN_END_DATE", "2026-09-01")

    # Funnel conversion rates. See docs/data_generation.md for why these are
    # compressed relative to real retail.
    p_repeat_view: float = 0.45
    p_wishlist_given_view: float = 0.09
    p_cart_given_view: float = 0.24
    p_purchase_given_cart: float = 0.62
    p_rating_given_purchase: float = 0.34

    # Probability that buying a product pulls its bundled complement into a
    # later session. This is what creates real item to item structure for the
    # collaborative filter to find.
    p_complement_followup: float = 0.45
    n_product_bundles: int = 420


@dataclass(frozen=True)
class EvaluationSettings:
    """Temporal split and cutoffs for the offline evaluation."""

    # Share of the interaction timeline used as history. The remainder is the
    # held out future the recommender is scored against.
    train_fraction: float = float(os.getenv("EVAL_TRAIN_FRACTION", "0.80"))

    # How many users to score. They are sampled deterministically by hashing
    # the user id, so repeated runs measure the same cohort. Users are NOT
    # filtered on history length: see eval_candidate_users in sql/evaluation.sql
    # for why that would flatter collaborative filtering.
    n_eval_users: int = int(os.getenv("EVAL_USERS", "1500"))

    cutoffs: tuple[int, ...] = field(default_factory=lambda: (5, 10))


DB = DatabaseSettings()
GEN = GenerationSettings()
EVAL = EvaluationSettings()
