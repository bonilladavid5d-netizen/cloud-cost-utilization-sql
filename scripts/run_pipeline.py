#!/usr/bin/env python3
"""Run the full pipeline from scratch for one dataset size.

    python scripts/run_pipeline.py --size small
    python scripts/run_pipeline.py --size portfolio

Steps: generate CSVs -> recreate the dedicated database -> schema ->
load -> transform -> views and analyses -> indexes -> quality gate ->
export aggregated results to results/<size>/ -> run summary.
Exits with a non-zero code if any SQL step or quality check fails.
Connection settings: see scripts/pgutil.py (environment variables only).
"""

import argparse
import csv
import io
import json
import subprocess
import sys
import time
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pgutil import ROOT, PsqlError, code_fingerprint, db_name, psql, recreate_database, scalar  # noqa: E402

LOAD_ORDER = [
    ("departments", "department_id, department_name, cost_center"),
    ("servers", "server_id, hostname, department_id, region, instance_type, environment, is_critical"),
    ("pricing", "pricing_id, instance_type, region, valid_from, valid_to, hourly_rate_usd"),
    ("budgets", "department_id, budget_month, amount_usd"),
    ("server_events", "event_id, server_id, event_time, event_type"),
    ("server_metrics", "server_id, hour_start, cpu_avg_pct, mem_avg_pct"),
]

EXPORTS = [
    ("a1_uptime_by_server_month", "server_id, month"),
    ("a2_cost_by_department_region_environment", "month, department_name, region, environment"),
    ("a3_budget_vs_actual", "department_name, month"),
    ("a4_low_utilization", "server_id"),
    ("a5_spend_trend_concentration", "month, rank_in_month, department_name"),
    ("a6_offhours_savings_by_server", "server_id"),
    ("a6_offhours_savings_summary", "department_name = 'ALL', department_name"),
    ("dq_summary", "check_name"),
    ("dq_event_status", "status, event_type"),
]

# Presentation rounding applied only when writing CSV files.
ROUNDING = [("_usd", 2), ("_pct", 2), ("_hours", 2), ("_seconds", 0), ("share", 4), ("coverage", 4)]


class Log:
    def __init__(self, path):
        self.path = path
        self.lines = []

    def __call__(self, msg=""):
        line = f"[{datetime.now(timezone.utc).strftime('%H:%M:%S')}] {msg}" if msg else ""
        print(line, flush=True)
        self.lines.append(line)

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text("\n".join(self.lines) + "\n")


def round_value(column, value):
    if "." not in value:
        return value
    for suffix, places in ROUNDING:
        if column.endswith(suffix) or (suffix in ("share", "coverage") and suffix in column):
            q = Decimal(1).scaleb(-places)
            return str(Decimal(value).quantize(q, rounding=ROUND_HALF_UP))
    return value


def export_view(db, view, order_by, out_path):
    _, out, _ = psql(db, sql=f"COPY (SELECT * FROM {view} ORDER BY {order_by}) "
                             "TO STDOUT WITH (FORMAT csv, HEADER true)")
    reader = csv.reader(io.StringIO(out))
    header = next(reader)
    with out_path.open("w", newline="") as fh:
        writer = csv.writer(fh, lineterminator="\n")
        writer.writerow(header)
        rows = 0
        for row in reader:
            writer.writerow([round_value(c, v) for c, v in zip(header, row)])
            rows += 1
    return rows


def main():
    parser = argparse.ArgumentParser(description="Run the cloud cost pipeline.")
    parser.add_argument("--size", choices=["small", "portfolio"], required=True)
    parser.add_argument("--seed", type=int, default=20250101)
    args = parser.parse_args()

    db = db_name(args.size)
    data_dir = ROOT / "data" / "generated" / args.size
    results_dir = ROOT / "results" / args.size
    log = Log(ROOT / "docs" / "evidence" / f"run_{args.size}.log")
    timings = {}

    def step(name, fn):
        t0 = time.perf_counter()
        log(f"{name} ...")
        result = fn()
        timings[name] = round(time.perf_counter() - t0, 2)
        log(f"{name} done in {timings[name]} s")
        return result

    log(f"Pipeline size={args.size} seed={args.seed} database={db}")
    log(f"Code fingerprint: {code_fingerprint()}")
    try:
        step("generate", lambda: subprocess.run(
            [sys.executable, str(ROOT / "generator" / "generate_data.py"),
             "--size", args.size, "--seed", str(args.seed)], check=True, capture_output=True))
        manifest = json.loads((data_dir / "manifest.json").read_text())

        step("recreate database", lambda: recreate_database(db))
        step("schema", lambda: psql(db, script=ROOT / "sql" / "01_schema.sql"))

        def load():
            for table, columns in LOAD_ORDER:
                psql(db, sql=f"COPY {table} ({columns}) FROM STDIN WITH (FORMAT csv, HEADER true)",
                     stdin_file=data_dir / f"{table}.csv")
            psql(db, sql="ANALYZE")
        step("load", load)
        step("transform", lambda: psql(db, script=ROOT / "sql" / "02_transform.sql"))

        def views():
            psql(db, script=ROOT / "sql" / "03_views.sql")
            for path in sorted((ROOT / "sql" / "analysis").glob("*.sql")):
                psql(db, script=path)
        step("views and analyses", views)
        step("indexes", lambda: psql(db, script=ROOT / "sql" / "05_indexes.sql"))
        step("vacuum analyze", lambda: psql(db, sql="VACUUM ANALYZE"))
        gate = step("quality gate", lambda: psql(db, script=ROOT / "sql" / "04_quality_gate.sql"))
        log(gate[2].strip().replace("NOTICE:  ", ""))

        def export():
            results_dir.mkdir(parents=True, exist_ok=True)
            return {view: export_view(db, view, order, results_dir / f"{view}.csv")
                    for view, order in EXPORTS}
        exported = step("export", export)
    except (PsqlError, subprocess.CalledProcessError) as exc:
        log(f"FAILED: {exc}")
        log.save()
        sys.exit(1)

    loaded = {table: int(scalar(db, f"SELECT COUNT(*) FROM {table}")) for table, _ in LOAD_ORDER}
    generated = {name.removesuffix(".csv"): info["rows"] for name, info in manifest["files"].items()}
    dq = dict(line.split("|") for line in
              scalar(db, "SELECT check_name, value FROM dq_summary ORDER BY check_name").splitlines())
    summary = {
        "size": args.size,
        "seed": args.seed,
        "run_date_utc": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "postgres_version": scalar(db, "SELECT version()"),
        "code_fingerprint": code_fingerprint(),
        "generated_rows": generated,
        "loaded_rows": loaded,
        "generated_equals_loaded": generated == loaded,
        "server_patterns": manifest["server_patterns"],
        "injected_anomalies": manifest["anomalies"],
        "data_quality": dq,
        "exported_rows": exported,
        "timings_seconds": timings,
    }
    (results_dir / "run_summary.json").write_text(json.dumps(summary, indent=2) + "\n")

    log("Rows generated vs loaded:")
    for table in loaded:
        log(f"  {table:<16} generated={generated[table]:>9,} loaded={loaded[table]:>9,}")
    log("Data quality summary:")
    for name, value in dq.items():
        log(f"  {name:<40} {value}")
    if not summary["generated_equals_loaded"]:
        log("FAILED: loaded row counts differ from generated row counts")
        log.save()
        sys.exit(1)
    log(f"Results written to results/{args.size}/")
    log("Pipeline finished OK")
    log.save()


if __name__ == "__main__":
    main()
