#!/usr/bin/env python3
"""Deterministic generator for the simulated cloud cost dataset.

Everything produced here is fictitious: departments, servers, power
events, hourly metrics, tariffs and budgets. The generator only creates
raw inputs; every result reported by the project is computed in SQL.

Usage:
    python generator/generate_data.py --size small
    python generator/generate_data.py --size portfolio --seed 20250101

Output: data/generated/<size>/*.csv plus manifest.json (parameters,
counts, injected anomalies and SHA-256 of each file).
"""

import argparse
import csv
import hashlib
import json
import random
from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

UTC = timezone.utc
ROOT = Path(__file__).resolve().parents[1]

# Analysis period [start, end) in UTC: 90 days.
PERIOD_START = datetime(2025, 1, 1, tzinfo=UTC)
PERIOD_END = datetime(2025, 4, 1, tzinfo=UTC)
# The event extract is wider than the period so sessions that cross
# either boundary can be reconstructed (and then clipped in SQL).
EXTRACT_START = datetime(2024, 12, 25, tzinfo=UTC)
EXTRACT_END = datetime(2025, 4, 8, tzinfo=UTC)
TARIFF_CHANGE = datetime(2025, 2, 15, tzinfo=UTC)
PRICING_START = datetime(2024, 12, 1, tzinfo=UTC)
PRICING_END = datetime(2025, 5, 1, tzinfo=UTC)

DEFAULT_SEED = 20250101

SIZES = {
    "small": {"n_servers": 24, "n_unclosed_starts": 1, "n_missing_starts": 1},
    "portfolio": {"n_servers": 500, "n_unclosed_starts": 6, "n_missing_starts": 4},
}

# (id, name, cost center, slug, share of servers). Research Lab owns no
# servers but has a budget: it must survive every join.
DEPARTMENTS = [
    (1, "Platform Engineering", "CC-1010", "plat", 0.22),
    (2, "Data & Analytics", "CC-1020", "data", 0.20),
    (3, "Customer Applications", "CC-1030", "capp", 0.18),
    (4, "Payments", "CC-1040", "paym", 0.12),
    (5, "Marketing Technology", "CC-1050", "mktg", 0.10),
    (6, "Internal Tools", "CC-1060", "itls", 0.10),
    (7, "Security Operations", "CC-1070", "secu", 0.08),
    (8, "Research Lab", "CC-1080", "rlab", 0.00),
]

# Fictitious region names and price multipliers.
REGIONS = {"na-east": "1.00", "na-west": "1.04", "eu-central": "1.10", "sa-east": "1.22"}
REGION_WEIGHTS = {"na-east": 0.45, "na-west": 0.20, "eu-central": 0.25, "sa-east": 0.10}

# Fictitious hourly list prices (USD) before the tariff change.
INSTANCE_TYPES = {
    "gp.small": "0.050",
    "gp.medium": "0.100",
    "gp.large": "0.200",
    "mem.large": "0.270",
    "cpu.xlarge": "0.380",
}
TYPE_WEIGHTS = {"gp.small": 0.25, "gp.medium": 0.30, "gp.large": 0.20, "mem.large": 0.15, "cpu.xlarge": 0.10}


def tariff_factor(instance_type, region):
    """Price change effective 2025-02-15 00:00 UTC (mid-month)."""
    if instance_type.startswith("gp."):
        return Decimal("1.06")
    if instance_type == "mem.large" and region == "eu-central":
        return Decimal("0.95")
    return Decimal("1")


DEV_PATTERNS = {"office_hours": 0.50, "always_on": 0.15, "extended_hours": 0.15, "sporadic": 0.20}

# Utilization profiles: ranges for the server's base CPU and memory (%).
PROFILES = {
    "idle": ((2, 6), (15, 32)),
    "light": ((8, 20), (25, 50)),
    "moderate": ((20, 45), (40, 65)),
    "busy": ((45, 72), (55, 85)),
}
PROFILE_WEIGHTS = {
    "production": {"idle": 0.12, "light": 0.30, "moderate": 0.38, "busy": 0.20},
    "development": {"idle": 0.35, "light": 0.35, "moderate": 0.20, "busy": 0.10},
}

METRIC_MISSING_PROB = 0.02   # random missing hourly samples
AGENT_OUTAGE_PROB = 0.06     # share of servers with a multi-day metrics gap
INACTIVE_PROB = 0.03         # servers that never run in the extract


def weighted(rng, weights):
    keys = list(weights)
    return rng.choices(keys, weights=[weights[k] for k in keys], k=1)[0]


def ts(dt):
    return dt.strftime("%Y-%m-%d %H:%M:%S+00")


def at(day, rng, h_from, h_to):
    """Random whole-second instant on `day` between two decimal hours."""
    return day + timedelta(seconds=rng.randint(int(h_from * 3600), int(h_to * 3600)))


def days(start, end):
    d = start
    while d < end:
        yield d
        d += timedelta(days=1)


def merge(intervals, min_gap=timedelta(minutes=1)):
    """Sort and merge overlapping or nearly touching intervals."""
    out = []
    for start, stop in sorted(intervals):
        if out and start <= out[-1][1] + min_gap:
            out[-1][1] = max(out[-1][1], stop)
        else:
            out.append([start, stop])
    return [(a, b) for a, b in out if a < b]


def always_on_intervals(rng, maintenance_prob):
    """Continuous running with occasional Sunday maintenance restarts.
    Each history starts between Dec 25 and Dec 28 and ends with a
    maintenance stop between Apr 2 and Apr 7, inside the extract."""
    t = EXTRACT_START + timedelta(seconds=rng.randint(0, 3 * 86400))
    intervals = []
    for day in days(EXTRACT_START + timedelta(days=4), datetime(2025, 4, 1, tzinfo=UTC)):
        if day.isoweekday() == 7 and rng.random() < maintenance_prob:
            stop = at(day, rng, 2, 4)
            if stop > t:
                intervals.append((t, stop))
                t = stop + timedelta(seconds=rng.randint(600, 5400))
    final_stop = at(datetime(2025, 4, 2, tzinfo=UTC), rng, 0, 5 * 24 + 22)
    intervals.append((t, final_stop))
    return intervals


def office_hours_intervals(rng):
    """Weekday sessions; ~7 % are left running until the next workday."""
    intervals = []
    for day in days(EXTRACT_START, datetime(2025, 4, 7, tzinfo=UTC)):
        if day.isoweekday() > 5 or rng.random() < 0.05:
            continue
        start = at(day, rng, 7.5, 9.75)
        stop = at(day, rng, 17.0, 19.5)
        if rng.random() < 0.07:
            next_day = day + timedelta(days=3 if day.isoweekday() == 5 else 1)
            stop = at(next_day, rng, 8.0, 10.0)
        intervals.append((start, stop))
    return intervals


def extended_hours_intervals(rng):
    intervals = []
    for day in days(EXTRACT_START, datetime(2025, 4, 7, tzinfo=UTC)):
        dow = day.isoweekday()
        if dow <= 5:
            intervals.append((at(day, rng, 5.5, 6.5), at(day, rng, 22.0, 23.5)))
        elif dow == 6 and rng.random() < 0.3:
            intervals.append((at(day, rng, 9, 11), at(day, rng, 14, 18)))
    return intervals


def sporadic_intervals(rng):
    intervals = []
    for day in days(EXTRACT_START, datetime(2025, 4, 7, tzinfo=UTC)):
        if rng.random() < 0.35:
            start = at(day, rng, 6, 20)
            intervals.append((start, start + timedelta(seconds=rng.randint(3600, 6 * 3600))))
    return intervals


def build_servers(n_servers, seed):
    servers = []
    for sid in range(1, n_servers + 1):
        rng = random.Random(f"{seed}:server:{sid}")
        # The first seven servers cover departments 1-7 so that even the
        # small dataset has every server-owning department.
        if sid <= 7:
            dept = DEPARTMENTS[sid - 1]
        else:
            dept = rng.choices(DEPARTMENTS, weights=[d[4] for d in DEPARTMENTS], k=1)[0]
        environment = "production" if rng.random() < 0.40 else "development"
        is_critical = rng.random() < (0.60 if environment == "production" else 0.10)
        instance_type = weighted(rng, TYPE_WEIGHTS)
        region = weighted(rng, REGION_WEIGHTS)
        if sid == n_servers:
            # The last server is always an idle development server, so
            # every dataset contains a server without any activity.
            environment, is_critical, pattern = "development", False, "inactive"
        elif environment == "production":
            pattern = "always_on"
        elif rng.random() < INACTIVE_PROB:
            pattern = "inactive"
        else:
            pattern = weighted(rng, DEV_PATTERNS)
        profile = weighted(rng, PROFILE_WEIGHTS[environment])
        cpu_range, mem_range = PROFILES[profile]
        servers.append({
            "server_id": sid,
            "hostname": f"{'prd' if environment == 'production' else 'dev'}-{dept[3]}-{sid:04d}",
            "department_id": dept[0],
            "region": region,
            "instance_type": instance_type,
            "environment": environment,
            "is_critical": "true" if is_critical else "false",
            "_pattern": pattern,
            "_profile": profile,
            "_cpu_base": rng.uniform(*cpu_range),
            "_mem_base": rng.uniform(*mem_range),
            "_rng": rng,
        })
    return servers


def true_intervals(server):
    rng = server["_rng"]
    pattern = server["_pattern"]
    if pattern == "inactive":
        return []
    if pattern == "always_on":
        prob = 0.40 if server["environment"] == "production" else 0.25
        raw = always_on_intervals(rng, prob)
    elif pattern == "office_hours":
        raw = office_hours_intervals(rng)
    elif pattern == "extended_hours":
        raw = extended_hours_intervals(rng)
    else:
        raw = sporadic_intervals(rng)
    return [(a, b) for a, b in merge(raw) if a >= EXTRACT_START and b <= EXTRACT_END]


def running_hours(intervals):
    """UTC clock hours inside the analysis period that overlap a session."""
    hours = set()
    for start, stop in intervals:
        start, stop = max(start, PERIOD_START), min(stop, PERIOD_END)
        h = start.replace(minute=0, second=0, microsecond=0)
        while h < stop:
            hours.add(h)
            h += timedelta(hours=1)
    return sorted(hours)


def metric_values(server, hour, rng):
    dow = hour.isoweekday()
    if dow <= 5 and 8 <= hour.hour < 18:
        factor = 1.4
    elif dow > 5:
        factor = 0.8
    else:
        factor = 0.7
    cpu = server["_cpu_base"] * factor * (1 + rng.gauss(0, 0.15))
    mem = server["_mem_base"] + rng.gauss(0, 3)
    return round(min(max(cpu, 0.5), 99.5), 2), round(min(max(mem, 1.0), 99.0), 2)


def money(value):
    return value.quantize(Decimal("0.0001"), rounding=ROUND_HALF_UP)


def build_pricing():
    rows, pid = [], 1
    for instance_type, base in INSTANCE_TYPES.items():
        for region, mult in REGIONS.items():
            rate = money(Decimal(base) * Decimal(mult))
            factor = tariff_factor(instance_type, region)
            if factor == 1:
                rows.append((pid, instance_type, region, ts(PRICING_START), ts(PRICING_END), rate))
                pid += 1
            else:
                rows.append((pid, instance_type, region, ts(PRICING_START), ts(TARIFF_CHANGE), rate))
                rows.append((pid + 1, instance_type, region, ts(TARIFF_CHANGE), ts(PRICING_END),
                             money(rate * factor)))
                pid += 2
    return rows


def build_budgets(servers, seed):
    """Budgets follow a simple planning rule, independent of the simulated
    usage: list price x planned hours (production: all hours of the month,
    development: 35 %) x a department factor x small monthly noise."""
    rng = random.Random(f"{seed}:budgets")
    months = [(datetime(2025, 1, 1, tzinfo=UTC), 744), (datetime(2025, 2, 1, tzinfo=UTC), 672),
              (datetime(2025, 3, 1, tzinfo=UTC), 744)]
    rows = []
    for dept_id, *_ in DEPARTMENTS:
        dept_factor = Decimal(str(round(rng.uniform(0.85, 1.20), 3)))
        for month, hours in months:
            noise = Decimal(str(round(rng.uniform(0.95, 1.05), 3)))
            if dept_id == 8:
                amount = Decimal("1200")          # budget, no servers
            elif dept_id == 6 and month.month == 3:
                amount = Decimal("0")             # explicit zero budget (freeze)
            elif dept_id == 5 and month.month == 2:
                continue                          # budget never defined
            else:
                planned = Decimal("0")
                for s in servers:
                    if s["department_id"] != dept_id:
                        continue
                    share = Decimal("1") if s["environment"] == "production" else Decimal("0.35")
                    rate = Decimal(INSTANCE_TYPES[s["instance_type"]]) * Decimal(REGIONS[s["region"]])
                    planned += rate * hours * share
                amount = (planned * dept_factor * noise / 10).quantize(Decimal("1"), ROUND_HALF_UP) * 10
            rows.append((dept_id, month.strftime("%Y-%m-%d"), f"{amount:.2f}"))
    return rows


def inject_anomalies(servers, events_by_server, params, seed):
    """Remove single events from the log to create invalid sequences that
    the SQL validation must detect: a lost stop (start -> start) and a
    lost start (stop -> stop). The real running time (and therefore the
    metrics) is unchanged: only the event log is damaged."""
    rng = random.Random(f"{seed}:anomalies")
    candidates = [s["server_id"] for s in servers
                  if s["_pattern"] in ("office_hours", "extended_hours", "sporadic")
                  and len(events_by_server[s["server_id"]]) >= 20]
    rng.shuffle(candidates)
    anomalies = []
    n_a, n_b = params["n_unclosed_starts"], params["n_missing_starts"]
    for kind, sids in (("lost_stop", candidates[:n_a]), ("lost_start", candidates[n_a:n_a + n_b])):
        for sid in sids:
            events = events_by_server[sid]
            wanted = "stop" if kind == "lost_stop" else "start"
            # pick an event of the wanted type inside the analysis period
            options = [i for i, (t, typ) in enumerate(events)
                       if typ == wanted and PERIOD_START + timedelta(days=10) <= t < PERIOD_END - timedelta(days=10)]
            idx = rng.choice(options)
            removed = events.pop(idx)
            anomalies.append({"server_id": sid, "kind": kind, "removed_event_time": ts(removed[0])})
    return anomalies


def write_csv(path, header, rows):
    with path.open("w", newline="") as fh:
        writer = csv.writer(fh, lineterminator="\n")
        writer.writerow(header)
        writer.writerows(rows)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def generate(size, seed, out_dir):
    params = SIZES[size]
    out_dir.mkdir(parents=True, exist_ok=True)
    servers = build_servers(params["n_servers"], seed)

    intervals = {s["server_id"]: true_intervals(s) for s in servers}
    events_by_server = {
        sid: [e for a, b in iv for e in ((a, "start"), (b, "stop"))]
        for sid, iv in intervals.items()
    }
    anomalies = inject_anomalies(servers, events_by_server, params, seed)

    # Metrics follow the real running time, in ingestion (time) order.
    metric_rows = []
    for s in servers:
        rng = random.Random(f"{seed}:metrics:{s['server_id']}")
        hours = running_hours(intervals[s["server_id"]])
        outage = None
        if hours and rng.random() < AGENT_OUTAGE_PROB:
            o_start = PERIOD_START + timedelta(days=rng.randint(0, 80))
            outage = (o_start, o_start + timedelta(days=rng.randint(2, 12)))
        for h in hours:
            if outage and outage[0] <= h < outage[1]:
                continue
            if rng.random() < METRIC_MISSING_PROB:
                continue
            cpu, mem = metric_values(s, h, rng)
            metric_rows.append((h, s["server_id"], cpu, mem))
    metric_rows.sort(key=lambda r: (r[0], r[1]))

    all_events = sorted(
        (t, sid, typ) for sid, evs in events_by_server.items() for t, typ in evs)
    event_rows = [(i, sid, ts(t), typ) for i, (t, sid, typ) in enumerate(all_events, start=1)]

    files = {
        "departments.csv": (["department_id", "department_name", "cost_center"],
                            [(d[0], d[1], d[2]) for d in DEPARTMENTS]),
        "servers.csv": (["server_id", "hostname", "department_id", "region", "instance_type",
                         "environment", "is_critical"],
                        [(s["server_id"], s["hostname"], s["department_id"], s["region"],
                          s["instance_type"], s["environment"], s["is_critical"]) for s in servers]),
        "pricing.csv": (["pricing_id", "instance_type", "region", "valid_from", "valid_to",
                         "hourly_rate_usd"], build_pricing()),
        "budgets.csv": (["department_id", "budget_month", "amount_usd"], build_budgets(servers, seed)),
        "server_events.csv": (["event_id", "server_id", "event_time", "event_type"], event_rows),
        "server_metrics.csv": (["server_id", "hour_start", "cpu_avg_pct", "mem_avg_pct"],
                               [(sid, ts(h), f"{c:.2f}", f"{m:.2f}") for h, sid, c, m in metric_rows]),
    }
    manifest = {
        "size": size,
        "seed": seed,
        "parameters": {
            **params,
            "period": [ts(PERIOD_START), ts(PERIOD_END)],
            "event_extract": [ts(EXTRACT_START), ts(EXTRACT_END)],
            "tariff_change": ts(TARIFF_CHANGE),
            "metric_missing_prob": METRIC_MISSING_PROB,
            "agent_outage_prob": AGENT_OUTAGE_PROB,
            "inactive_prob": INACTIVE_PROB,
        },
        "server_patterns": {},
        "anomalies": anomalies,
        "files": {},
    }
    for s in servers:
        key = f"{s['environment']}/{s['_pattern']}"
        manifest["server_patterns"][key] = manifest["server_patterns"].get(key, 0) + 1
    manifest["server_patterns"] = dict(sorted(manifest["server_patterns"].items()))
    for name, (header, rows) in files.items():
        path = out_dir / name
        write_csv(path, header, rows)
        manifest["files"][name] = {"rows": len(rows), "sha256": sha256(path)}
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--size", choices=sorted(SIZES), required=True)
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--out", type=Path, default=None,
                        help="output directory (default: data/generated/<size>)")
    args = parser.parse_args()
    out_dir = args.out or ROOT / "data" / "generated" / args.size
    manifest = generate(args.size, args.seed, out_dir)
    for name, info in manifest["files"].items():
        print(f"{name:<20} {info['rows']:>9,} rows")


if __name__ == "__main__":
    main()
