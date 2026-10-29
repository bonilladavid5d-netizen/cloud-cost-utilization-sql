#!/usr/bin/env python3
"""Automated SQL tests against dedicated, disposable test databases.

    python tests/run_tests.py

Each suite has its own fixture and its own database, so fixtures never
mix with each other or with the generated analysis data:
    core           tests/fixtures/fixture_core.sql           -> <prefix>_test
    partial_hours  tests/fixtures/fixture_partial_hours.sql  -> <prefix>_test_partial_hours
For each suite: recreate the database, load the schema and the fixture,
build the same derived tables, views and analyses used by the pipeline,
then run its test files with ON_ERROR_STOP=1. A failed assertion raises
an exception, so psql exits non-zero for that file. A negative control
(an assertion that must fail) proves that failures are detected.
Exit code: 0 only if every test file passes and the negative control fails.
"""

import re
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from pgutil import ROOT, PsqlError, db_name, psql, recreate_database, scalar  # noqa: E402

TESTS = ROOT / "tests"
SUITES = [
    ("core", "test", "fixture_core.sql", "test_[0-9]*.sql"),
    ("partial_hours", "test_partial_hours", "fixture_partial_hours.sql", "test_partial_hours_*.sql"),
]


def setup_scripts(fixture):
    return [
        ROOT / "sql" / "01_schema.sql",
        TESTS / "fixtures" / fixture,
        ROOT / "sql" / "02_transform.sql",
        ROOT / "sql" / "03_views.sql",
        *sorted((ROOT / "sql" / "analysis").glob("*.sql")),
        TESTS / "sql" / "00_helpers.sql",
    ]


def main():
    lines = []

    def log(msg=""):
        print(msg, flush=True)
        lines.append(msg)

    log(f"Test run {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}")
    failures = files = total_assertions = 0
    control_detected = False
    for suite, suffix, fixture, pattern in SUITES:
        db = db_name(suffix)
        try:
            recreate_database(db)
            for path in setup_scripts(fixture):
                psql(db, script=path)
        except PsqlError as exc:
            log(f"SETUP FAILED for suite {suite}: {exc}")
            sys.exit(2)
        log("")
        log(f"Suite {suite}: fixture {fixture}, database {db}")
        if suite == SUITES[0][0]:
            log(scalar(db, "SELECT version()"))
        for path in sorted((TESTS / "sql").glob(pattern)):
            n = len(re.findall(r"^SELECT assert_", path.read_text(), re.M))
            files += 1
            total_assertions += n
            rc, _, err = psql(db, script=path, check=False)
            if rc == 0:
                log(f"PASS  {path.name:<48} {n:>3} assertions")
            else:
                failures += 1
                message = next((ln for ln in err.splitlines() if "FAIL" in ln or "ERROR" in ln), err.strip())
                log(f"FAIL  {path.name:<48} exit={rc}  {message}")
        if suite == SUITES[0][0]:
            rc, _, err = psql(db, sql="SELECT assert_eq('negative control', 1, 2)", check=False)
            control_detected = rc != 0 and "FAIL [negative control]" in err
            log(f"Negative control (assertion that must fail): exit={rc} -> "
                f"{'detected' if control_detected else 'NOT DETECTED'}")

    log("")
    log(f"Result: {files - failures}/{files} test files passed, {total_assertions} assertions in total")
    ok = failures == 0 and control_detected
    log("ALL TESTS PASSED" if ok else "TESTS FAILED")

    evidence = ROOT / "docs" / "evidence" / "tests.log"
    evidence.parent.mkdir(parents=True, exist_ok=True)
    evidence.write_text("\n".join(lines) + "\n")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
