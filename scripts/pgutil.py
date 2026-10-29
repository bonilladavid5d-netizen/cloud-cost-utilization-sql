"""Small helpers to run psql from Python without storing credentials.

Connection settings come from the environment only:
    CCU_PSQL       command used to start psql (default: "psql").
                   Example for a Docker lab:
                   CCU_PSQL="docker exec -i <container> psql -U <user>"
    CCU_ADMIN_DB   database used to create/drop project databases
                   (default: "postgres")
    CCU_DB_PREFIX  prefix of the dedicated databases
                   (default: "cloud_cost_utilization")
Standard libpq variables (PGHOST, PGPORT, PGUSER, ~/.pgpass ...) work as
usual when CCU_PSQL is a local psql. SQL scripts are sent through stdin,
so the same code works with a local psql or one inside a container.
"""

import hashlib
import os
import shlex
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class PsqlError(RuntimeError):
    pass


def psql_command():
    return shlex.split(os.environ.get("CCU_PSQL", "psql"))


def admin_db():
    return os.environ.get("CCU_ADMIN_DB", "postgres")


def db_name(suffix):
    return f"{os.environ.get('CCU_DB_PREFIX', 'cloud_cost_utilization')}_{suffix}"


def psql(db, sql=None, script=None, stdin_file=None, tuples=False, check=True):
    """Run one psql call. `sql` uses -c, `script` (a path) is piped as the
    script, `stdin_file` feeds COPY ... FROM STDIN for a -c command."""
    cmd = psql_command() + ["-X", "-q", "-v", "ON_ERROR_STOP=1", "-d", db]
    if tuples:
        cmd += ["-A", "-t"]
    if sql is not None:
        cmd += ["-c", sql]
    source = script or stdin_file
    with (open(source, "rb") if source else open(os.devnull, "rb")) as stdin:
        proc = subprocess.run(cmd, stdin=stdin, capture_output=True)
    out = proc.stdout.decode()
    err = proc.stderr.decode()
    if check and proc.returncode != 0:
        where = Path(script).relative_to(ROOT) if script else (sql or "")[:80]
        raise PsqlError(f"psql exited with {proc.returncode} on {where}:\n{err.strip()}")
    return proc.returncode, out, err


def scalar(db, sql):
    return psql(db, sql=sql, tuples=True)[1].strip()


def recreate_database(db):
    psql(admin_db(), sql=f'DROP DATABASE IF EXISTS "{db}" WITH (FORCE)')
    psql(admin_db(), sql=f'CREATE DATABASE "{db}"')
    psql(admin_db(), sql=f"ALTER DATABASE \"{db}\" SET timezone TO 'UTC'")


def code_fingerprint():
    """SHA-256 over the code that produces the analysis results."""
    files = sorted(
        [*ROOT.glob("sql/**/*.sql"), *ROOT.glob("generator/*.py"),
         ROOT / "scripts" / "run_pipeline.py", ROOT / "scripts" / "pgutil.py"]
    )
    digest = hashlib.sha256()
    for path in files:
        digest.update(str(path.relative_to(ROOT)).encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()
