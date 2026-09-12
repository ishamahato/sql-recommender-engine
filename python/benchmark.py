"""
Index benchmarking.

Measures what each index is actually worth by dropping it, timing the query it
exists for, putting it back and timing again. The index definition is read from
`pg_indexes` before the drop and replayed verbatim afterwards, so this file
never carries a second copy of the DDL that could drift from indexes.sql.

Every number in docs/query_optimization.md comes from here. Nothing is
estimated: the timings are the `Execution Time` reported by
EXPLAIN (ANALYZE, BUFFERS), taken as the median of several runs after a warm up
pass, so the comparison is not measuring a cold cache on one side and a warm one
on the other.

Run with:  python -m python.benchmark
"""

from __future__ import annotations

import json
import statistics
import textwrap
from dataclasses import dataclass, field

from python.config import DOCS_DIR
from python.db import connect

RUNS = 5


@dataclass
class Benchmark:
    name: str
    question: str
    why_it_matters: str
    sql: str
    params: tuple = ()
    indexes: list[str] = field(default_factory=list)


BENCHMARKS: list[Benchmark] = [
    Benchmark(
        name="Anchor lookup for one user",
        question="What has this user engaged with, and how strongly?",
        why_it_matters=(
            "Stage 2 of get_recommendations runs this on every request. Without "
            "an index it is a sequential scan of the whole interaction log to "
            "find the few dozen rows belonging to one person."
        ),
        sql="""
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
        """,
        params=(4127,),
        indexes=["idx_interactions_user_product", "idx_interactions_user_time"],
    ),
    Benchmark(
        name="Recent demand for one product",
        question="How much engagement has this product had in the last four weeks?",
        why_it_matters=(
            "The shape of every trend and popularity query: one product, one "
            "time window. The composite index puts the range predicate on the "
            "second column so the scan can stop early instead of filtering the "
            "product's entire history."
        ),
        sql="""
            SELECT
                COUNT(*)                                                AS events,
                COUNT(*) FILTER (WHERE interaction_type = 'purchase')   AS purchases,
                COUNT(DISTINCT user_id)                                 AS unique_users
            FROM user_interactions
            WHERE product_id = %s
              AND interaction_timestamp >= rec_as_of() - INTERVAL '4 weeks'
              AND interaction_timestamp <  rec_as_of()
        """,
        params=(134,),
        indexes=["idx_interactions_product_time"],
    ),
    Benchmark(
        name="Neighbour lookup in the similarity matrix",
        question="Given twenty products this user likes, what is similar to them?",
        why_it_matters=(
            "Candidate generation. This is the single hottest read in the "
            "serving path and it runs against a hundred thousand row matrix "
            "that will only grow with the catalogue."
        ),
        sql="""
            SELECT sim.product_b, SUM(sim.similarity_score) AS score
            FROM mv_product_similarity AS sim
            WHERE sim.product_a = ANY(%s)
            GROUP BY sim.product_b
            ORDER BY score DESC
            LIMIT 100
        """,
        params=(list(range(120, 140)),),
        indexes=["idx_mv_sim_lookup", "idx_mv_sim_pk"],
    ),
    Benchmark(
        name="Full text catalogue search",
        question="Which products match a free text query?",
        why_it_matters=(
            "Without the GIN index over the generated tsvector, every search "
            "re tokenises and scans the whole catalogue. The generated column "
            "plus GIN turns that into an inverted index probe."
        ),
        sql="""
            SELECT p.product_id, p.name, ts_rank_cd(p.search_document, q.query) AS rank
            FROM products AS p
            CROSS JOIN websearch_to_tsquery('english', %s) AS q(query)
            WHERE p.search_document @@ q.query
              AND p.is_active
            ORDER BY rank DESC
            LIMIT 20
        """,
        params=("noise cancelling wireless headphones",),
        indexes=["idx_products_search_document"],
    ),
    Benchmark(
        name="Purchase exclusion set",
        question="Which products has this user already bought?",
        why_it_matters=(
            "Runs on every recommendation request as the anti join that keeps "
            "already owned products off the shelf. This is the honest case in "
            "the set: dropping the partial index does not fall back to a "
            "sequential scan, it falls back to the broad composite index, which "
            "already answers the query well. The partial index earns its place "
            "on size rather than on dramatic speed, covering only the purchase "
            "rows at roughly a tenth of the composite index it displaces, which "
            "is what keeps it resident in cache under memory pressure."
        ),
        sql="""
            SELECT DISTINCT product_id
            FROM user_interactions
            WHERE user_id = %s
              AND interaction_type = 'purchase'
              AND interaction_timestamp < rec_as_of()
        """,
        params=(4127,),
        indexes=["idx_interactions_purchases"],
    ),
]


def index_definition(conn, name: str) -> str | None:
    row = conn.execute(
        "SELECT indexdef FROM pg_indexes WHERE indexname = %s", (name,)
    ).fetchone()
    return row["indexdef"] if row else None


def explain(conn, sql: str, params: tuple) -> dict:
    plan = conn.execute(
        f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {sql}", params
    ).fetchone()
    return plan["QUERY PLAN"][0]


def time_query(conn, sql: str, params: tuple) -> tuple[float, dict]:
    """Warm up once, then take the median execution time of RUNS runs."""
    explain(conn, sql, params)
    timings = []
    plan = {}
    for _ in range(RUNS):
        plan = explain(conn, sql, params)
        timings.append(plan["Execution Time"])
    return statistics.median(timings), plan


def scan_summary(node: dict, found: list[str] | None = None) -> list[str]:
    """Collect the scan node types in a plan, which is what actually changed."""
    found = found if found is not None else []
    node_type = node.get("Node Type", "")
    if "Scan" in node_type:
        relation = node.get("Relation Name") or node.get("Index Name") or ""
        label = f"{node_type} on {relation}".strip()
        if node.get("Index Name") and "Index" in node_type:
            label = f"{node_type} using {node['Index Name']}"
        found.append(label)
    for child in node.get("Plans", []):
        scan_summary(child, found)
    return found


def run_benchmark(conn, bench: Benchmark) -> dict:
    definitions: list[str] = []
    for name in bench.indexes:
        definition = index_definition(conn, name)
        if definition:
            definitions.append(definition)

    after_ms, after_plan = time_query(conn, bench.sql, bench.params)

    for name in bench.indexes:
        conn.execute(f"DROP INDEX IF EXISTS {name}")
    conn.execute("ANALYZE user_interactions")

    try:
        before_ms, before_plan = time_query(conn, bench.sql, bench.params)
    finally:
        for definition in definitions:
            conn.execute(definition)
        conn.execute("ANALYZE user_interactions")
        conn.execute("ANALYZE mv_product_similarity")
        conn.execute("ANALYZE products")

    return {
        "name": bench.name,
        "question": bench.question,
        "why_it_matters": bench.why_it_matters,
        "indexes": bench.indexes,
        "without_index_ms": round(before_ms, 3),
        "with_index_ms": round(after_ms, 3),
        "speedup": round(before_ms / after_ms, 1) if after_ms else None,
        "plan_without": scan_summary(before_plan["Plan"]),
        "plan_with": scan_summary(after_plan["Plan"]),
        "rows_without": before_plan["Plan"].get("Actual Rows"),
        "rows_with": after_plan["Plan"].get("Actual Rows"),
        "sql": textwrap.dedent(bench.sql).strip(),
    }


def render(results: list[dict], sizes: list[dict]) -> str:
    lines: list[str] = []
    lines.append("# Query optimization")
    lines.append("")
    lines.append(
        "Produced by `python -m python.benchmark`. Each row is measured by "
        "dropping the index, timing the query, restoring the index and timing "
        "again. Timings are the median `Execution Time` from "
        "`EXPLAIN (ANALYZE, BUFFERS)` over "
        f"{RUNS} runs, after a warm up pass so both sides read a warm cache."
    )
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append("| Query | Without index (ms) | With index (ms) | Speedup |")
    lines.append("| - | -: | -: | -: |")
    for r in results:
        speedup = f"{r['speedup']}x" if r["speedup"] else "n/a"
        lines.append(
            f"| {r['name']} | {r['without_index_ms']:.3f} | "
            f"{r['with_index_ms']:.3f} | {speedup} |"
        )
    lines.append("")

    for r in results:
        lines.append(f"## {r['name']}")
        lines.append("")
        lines.append(f"**Question.** {r['question']}")
        lines.append("")
        lines.append(f"**Why it matters.** {r['why_it_matters']}")
        lines.append("")
        lines.append("```sql")
        lines.append(r["sql"])
        lines.append("```")
        lines.append("")
        lines.append(f"Index under test: `{'`, `'.join(r['indexes'])}`")
        lines.append("")
        lines.append("| | Plan | Execution time |")
        lines.append("| - | - | -: |")
        lines.append(
            f"| Without | {'; '.join(r['plan_without'])} | {r['without_index_ms']:.3f} ms |"
        )
        lines.append(
            f"| With | {'; '.join(r['plan_with'])} | {r['with_index_ms']:.3f} ms |"
        )
        lines.append("")
        if r["speedup"]:
            lines.append(f"Speedup: **{r['speedup']}x**.")
            lines.append("")

    lines.append("## Index sizes")
    lines.append("")
    lines.append(
        "Indexes are not free. They cost disk, they cost write throughput and "
        "they cost cache residency. These are the ones this project keeps."
    )
    lines.append("")
    lines.append("| Index | Table | Size |")
    lines.append("| - | - | -: |")
    for row in sizes:
        lines.append(f"| `{row['indexname']}` | {row['tablename']} | {row['size']} |")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    print(f"Benchmarking {len(BENCHMARKS)} queries, {RUNS} runs each")
    results = []
    with connect(autocommit=True) as conn:
        for bench in BENCHMARKS:
            result = run_benchmark(conn, bench)
            results.append(result)
            speedup = f"{result['speedup']}x" if result["speedup"] else "n/a"
            print(
                f"  {bench.name:<44} "
                f"{result['without_index_ms']:>9.3f} ms  ->  "
                f"{result['with_index_ms']:>8.3f} ms  ({speedup})"
            )

        sizes = conn.execute(
            """
            SELECT
                indexname,
                tablename,
                pg_size_pretty(pg_relation_size(indexname::regclass)) AS size
            FROM pg_indexes
            WHERE schemaname = 'public'
              AND indexname LIKE 'idx_%'
            ORDER BY pg_relation_size(indexname::regclass) DESC
            """
        ).fetchall()

    DOCS_DIR.mkdir(parents=True, exist_ok=True)
    (DOCS_DIR / "query_optimization.md").write_text(
        render(results, sizes), encoding="utf-8"
    )
    (DOCS_DIR / "query_optimization.json").write_text(
        json.dumps(results, indent=2), encoding="utf-8"
    )
    print(f"Wrote {DOCS_DIR / 'query_optimization.md'}")


if __name__ == "__main__":
    main()
