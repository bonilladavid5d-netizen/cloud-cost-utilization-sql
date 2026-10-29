#!/usr/bin/env python3
"""Benchmark three queries (baseline vs optimized) on the portfolio database.

    python benchmark/run_benchmark.py            # 7 measured runs per variant
    python benchmark/run_benchmark.py --runs 9

Protocol (documented in benchmark/README.md):
  * Same data and constraints for every variant; only the optional BRIN
    index of sql/05_indexes.sql differs between phases.
  * Phase A: optimization index dropped, VACUUM ANALYZE.
    Phase B: index created (build time and size recorded), ANALYZE.
  * Result equivalence is checked in each phase with EXCEPT ALL in both
    directions (keeps duplicates; NULLs compare as equal).
  * Each variant: 2 warm-up runs, then N measured runs interleaved in
    round-robin order with the other variants of the same phase (warm
    cache: nothing is evicted between runs).
  * Every run uses EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON). Planner cost
    estimates are recorded separately from measured times.
  * No planner settings are changed (enable_seqscan etc. stay on).
"""

import argparse
import csv
import json
import os
import shutil
import statistics
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from pgutil import ROOT, db_name, psql, psql_command, scalar  # noqa: E402

BENCH = ROOT / "benchmark"
OUT = BENCH / "results"
WARMUP = 2

# (query id, description, [(variant, sql file, needs optimization index)])
QUERIES = [
    ("q1_server_week_metrics", "Metrics of one server over one week", [
        ("baseline", "q1_baseline.sql", False),
        ("optimized", "q1_optimized.sql", False),
    ]),
    ("q2_monthly_cost_joins", "Monthly cost by department/region/environment", [
        ("baseline", "q2_baseline.sql", False),
        ("optimized", "q2_optimized.sql", False),
    ]),
    ("q3_dev_utilization_march", "Weekly CPU/memory profile of dev servers in March", [
        ("baseline", "q3_baseline.sql", False),
        ("rewrite_only", "q3_optimized.sql", False),
        ("rewrite_plus_brin", "q3_optimized.sql", True),
    ]),
]
SETTINGS = ["server_version", "shared_buffers", "work_mem", "effective_cache_size",
            "max_parallel_workers_per_gather", "jit", "random_page_cost", "effective_io_concurrency"]


def read_sql(name):
    lines = [ln for ln in (BENCH / "queries" / name).read_text().splitlines()
             if not ln.lstrip().startswith("--")]
    return "\n".join(lines).strip().rstrip(";")


def explain(db, sql):
    _, out, _ = psql(db, sql=f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {sql}", tuples=True)
    plan = json.loads(out)[0]
    root = plan["Plan"]
    return {
        "execution_ms": plan["Execution Time"],
        "planning_ms": plan["Planning Time"],
        "rows": root["Actual Rows"],
        "shared_hit_blocks": root.get("Shared Hit Blocks", 0),
        "shared_read_blocks": root.get("Shared Read Blocks", 0),
        "estimated_total_cost": root["Total Cost"],
        "top_node": root["Node Type"],
        "jit_ms": plan.get("JIT", {}).get("Timing", {}).get("Total"),
    }, plan


def equivalence(db, base_sql, other_sql):
    diff = scalar(db, f"SELECT COUNT(*) FROM (({base_sql}) EXCEPT ALL ({other_sql})) a")
    diff2 = scalar(db, f"SELECT COUNT(*) FROM (({other_sql}) EXCEPT ALL ({base_sql})) b")
    n1 = scalar(db, f"SELECT COUNT(*) FROM ({base_sql}) x")
    n2 = scalar(db, f"SELECT COUNT(*) FROM ({other_sql}) y")
    return int(diff), int(diff2), int(n1), int(n2)


def docker_resources():
    if "docker" not in os.path.basename(psql_command()[0]) or not shutil.which("docker"):
        return None
    out = subprocess.run(["docker", "info", "--format",
                          "{{.NCPU}}|{{.MemTotal}}|{{.OperatingSystem}}|{{.Architecture}}"],
                         capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    ncpu, mem, os_name, arch = out.split("|")
    return {"container_runtime": os_name, "cpus": int(ncpu),
            "memory_gib": round(int(mem) / 1024 ** 3, 1), "architecture": arch}


def summarize(values):
    q = statistics.quantiles(values, n=4) if len(values) >= 4 else [min(values), 0, max(values)]
    return {"median": statistics.median(values), "min": min(values), "max": max(values),
            "iqr": q[2] - q[0]}


def main():
    parser = argparse.ArgumentParser(description="Benchmark baseline vs optimized queries.")
    parser.add_argument("--runs", type=int, default=7)
    args = parser.parse_args()
    if args.runs < 5:
        parser.error("use at least 5 measured runs")

    db = db_name("portfolio")
    (OUT / "plans").mkdir(parents=True, exist_ok=True)
    log_lines = []

    def log(msg=""):
        print(msg, flush=True)
        log_lines.append(msg)

    env = {
        "run_date_utc": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "postgres_version": scalar(db, "SELECT version()"),
        "settings": dict(line.split("|") for line in scalar(
            db, "SELECT name, setting || COALESCE(unit, '') FROM pg_settings "
                f"WHERE name IN ({', '.join(repr(s) for s in SETTINGS)}) ORDER BY name").splitlines()),
        "resources": docker_resources(),
        "row_counts": {t: int(scalar(db, f"SELECT COUNT(*) FROM {t}"))
                       for t in ("server_metrics", "server_hours", "servers", "pricing")},
        "table_sizes": dict(line.split("|") for line in scalar(
            db, "SELECT relname, pg_size_pretty(pg_relation_size(oid)) FROM pg_class "
                "WHERE relname IN ('server_metrics', 'server_hours', 'server_metrics_pkey', "
                "'server_hours_pkey') ORDER BY relname").splitlines()),
        "measured_runs_per_variant": args.runs,
        "warmup_runs_per_variant": WARMUP,
    }
    log(f"Benchmark on {db}: {env['postgres_version']}")
    log(f"Resources: {env['resources']}")

    runs, equivalence_rows, index_info = [], [], {}
    for phase, with_index in (("A_without_index", False), ("B_with_index", True)):
        if with_index:
            _, _, err = psql(db, sql="DO $$ DECLARE t0 TIMESTAMPTZ := clock_timestamp(); BEGIN "
                                      "CREATE INDEX brin_server_metrics_hour ON server_metrics USING brin (hour_start); "
                                      "RAISE NOTICE 'build_ms=%', "
                                      "round(EXTRACT(EPOCH FROM clock_timestamp() - t0) * 1000, 1); END $$")
            psql(db, sql="ANALYZE server_metrics")
            index_info = {
                "index": "brin_server_metrics_hour",
                "build_ms": float(err.split("build_ms=")[1].split()[0]),
                "size_bytes": int(scalar(db, "SELECT pg_relation_size('brin_server_metrics_hour')")),
                "table_size_bytes": int(scalar(db, "SELECT pg_relation_size('server_metrics')")),
            }
            log(f"Phase B: created BRIN index in {index_info['build_ms']} ms, "
                f"size {index_info['size_bytes']} bytes")
        else:
            psql(db, sql="DROP INDEX IF EXISTS brin_server_metrics_hour")
            psql(db, sql="VACUUM ANALYZE")
            log("Phase A: optimization index dropped, VACUUM ANALYZE done")

        variants = [(qid, v, read_sql(f)) for qid, _, vs in QUERIES for v, f, idx in vs if idx == with_index]
        # Equivalence against the baseline of the same query, in this phase.
        for qid, _, vs in QUERIES:
            base_sql = read_sql(vs[0][1])
            for v, f, idx in vs[1:]:
                if idx != with_index:
                    continue
                d1, d2, n1, n2 = equivalence(db, base_sql, read_sql(f))
                ok = d1 == 0 and d2 == 0 and n1 == n2
                equivalence_rows.append({"phase": phase, "query": qid, "variant": v,
                                         "baseline_rows": n1, "variant_rows": n2,
                                         "rows_only_in_baseline": d1, "rows_only_in_variant": d2,
                                         "equivalent": ok})
                log(f"  equivalence {qid}/{v}: rows {n1} vs {n2}, differences {d1}+{d2} -> "
                    f"{'OK' if ok else 'MISMATCH'}")
                if not ok:
                    sys.exit("Result mismatch: benchmark aborted")

        for qid, v, sql in variants:
            for _ in range(WARMUP):
                explain(db, sql)
        plans = {}
        for r in range(1, args.runs + 1):
            for qid, v, sql in variants:
                metrics, plan = explain(db, sql)
                runs.append({"phase": phase, "query": qid, "variant": v, "round": r, **metrics})
                plans.setdefault((qid, v), []).append((metrics["execution_ms"], plan))
        for (qid, v), items in plans.items():
            items.sort(key=lambda x: x[0])
            median_plan = items[len(items) // 2][1]
            (OUT / "plans" / f"{qid}__{v}.json").write_text(json.dumps(median_plan, indent=2) + "\n")
        log(f"{phase}: {len(variants)} variants x {args.runs} measured runs done")

    with (OUT / "benchmark_runs.csv").open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(runs[0]), lineterminator="\n")
        writer.writeheader()
        writer.writerows(runs)
    with (OUT / "equivalence.csv").open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(equivalence_rows[0]), lineterminator="\n")
        writer.writeheader()
        writer.writerows(equivalence_rows)

    summary = []
    for qid, desc, vs in QUERIES:
        base_median = None
        for v, _, _ in vs:
            rs = [r for r in runs if r["query"] == qid and r["variant"] == v]
            ex = summarize([r["execution_ms"] for r in rs])
            if base_median is None:
                base_median = ex["median"]
            summary.append({
                "query": qid,
                "variant": v,
                "phase": rs[0]["phase"],
                "runs": len(rs),
                "median_ms": round(ex["median"], 3),
                "min_ms": round(ex["min"], 3),
                "max_ms": round(ex["max"], 3),
                "iqr_ms": round(ex["iqr"], 3),
                "median_planning_ms": round(statistics.median(r["planning_ms"] for r in rs), 3),
                "median_jit_ms": (round(statistics.median(r["jit_ms"] for r in rs), 3)
                                  if all(r["jit_ms"] is not None for r in rs) else ""),
                "ratio_vs_baseline": round(ex["median"] / base_median, 3),
                "rows": rs[0]["rows"],
                "shared_hit_blocks": int(statistics.median(r["shared_hit_blocks"] for r in rs)),
                "shared_read_blocks": int(statistics.median(r["shared_read_blocks"] for r in rs)),
                "estimated_total_cost": rs[0]["estimated_total_cost"],
                "top_node": rs[0]["top_node"],
            })
    with (OUT / "benchmark_summary.csv").open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(summary[0]), lineterminator="\n")
        writer.writeheader()
        writer.writerows(summary)
    env["optimization_index"] = index_info
    (OUT / "environment.json").write_text(json.dumps(env, indent=2) + "\n")

    log("")
    log(f"{'query':<26}{'variant':<19}{'median ms':>10}{'IQR':>8}{'ratio':>7}{'rows':>6}"
        f"{'hit':>8}{'read':>6}{'est.cost':>11}")
    for s in summary:
        log(f"{s['query']:<26}{s['variant']:<19}{s['median_ms']:>10.2f}{s['iqr_ms']:>8.2f}"
            f"{s['ratio_vs_baseline']:>7.2f}{s['rows']:>6}{s['shared_hit_blocks']:>8}"
            f"{s['shared_read_blocks']:>6}{s['estimated_total_cost']:>11.0f}")
    (ROOT / "docs" / "evidence" / "benchmark.log").write_text("\n".join(log_lines) + "\n")


if __name__ == "__main__":
    main()
