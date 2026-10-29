# AWS Server Utilization SQL Analysis

A small PostgreSQL project that calculates the total uptime of a fleet of servers from a log of start/stop events.

This is an educational exercise based on the [Server Utilization Time](https://datalemur.com/questions/total-utilization-time) problem from DataLemur. It uses simulated data and does not represent work performed for AWS.

## Problem

Amazon Web Services (AWS) is powered by fleets of servers, and management wants data-driven insight into how much those servers are actually used.

Given a table of server events, calculate the **total time the fleet of servers was running**, expressed in **full days**.

Assumptions:

- Each server may start and stop several times.
- The total fleet uptime is the sum of each server's uptime.

## Assumptions and Limitations

- Sessions are complete: for each server, events alternate `start → stop`.
- There are no duplicate events and no timestamp ties within the same server.
- Events are ordered explicitly with `ORDER BY status_time`; the query does not depend on physical insertion order.
- The result adds time across servers: it is **cumulative server uptime in days**, not calendar days and not a utilization percentage.
- Handling incomplete or inconsistent records (e.g. a `start` without a `stop`, consecutive `start` events) is out of scope for this exercise.

## Dataset

Table: `server_utilization`

| Column           | Type          | Description                                 |
|------------------|---------------|---------------------------------------------|
| `server_id`      | `INTEGER`     | Server identifier                           |
| `status_time`    | `TIMESTAMP`   | When the event happened                     |
| `session_status` | `VARCHAR(5)`  | Event type: `'start'` or `'stop'` (CHECK constraint) |

The simulated dataset contains 3 servers, 5 sessions and 10 events:

| server_id | Sessions | Uptime    |
|----------:|---------:|----------:|
| 1         | 2        | 3.5 days  |
| 2         | 1        | 7.0 days  |
| 3         | 2        | 5.0 days  |
| **Total** | **5**    | **15.5 days** |

## Key SQL Concepts

- **CTEs** – `WITH sessions AS (...)` isolates the session-building step and keeps the final query readable.
- **Window functions** – compute values across related rows without collapsing them.
- **`LEAD()`** – reads a value from the next row in the window.
- **`PARTITION BY`** – restricts the window to a single server, so events from different servers are never mixed.
- **Timestamp arithmetic** – `stop_time - start_time` returns an `INTERVAL`.
- **`EXTRACT(EPOCH ...)`** – converts an interval to a number of seconds.
- **Aggregation** – `SUM()` combines all sessions; `FLOOR()` keeps only full days.

## Approach

1. **Order events per server.** Each server's events are sorted by `status_time`.
2. **Find the next event.** For every event, look up the timestamp of the following event of the same server:

   ```sql
   LEAD(status_time) OVER (
       PARTITION BY server_id
       ORDER BY status_time
   )
   ```

   `PARTITION BY server_id` makes each server its own independent sequence, and `ORDER BY status_time` makes "next" mean "chronologically next". Because events are logged in order and always alternate `start → stop`, the row immediately after a `start` is exactly the `stop` that closes that session.
3. **Keep only `start` rows.** After filtering, each row represents one complete session with a `start_time` and its `stop_time`. (For `stop` rows, `LEAD()` would point to the next `start`, which is downtime, so they are discarded.)
4. **Measure each session.** `EXTRACT(EPOCH FROM (stop_time - start_time))` gives the session length in seconds.
5. **Sum, then convert.** All session seconds are summed first, divided by `86400` (seconds per day) and floored **once** at the end.

Flooring each session individually would be wrong: with this dataset, `FLOOR` per session gives `2 + 1 + 7 + 2 + 2 = 14` days, losing the half-days that together make up a full extra day. Flooring the total gives the correct `FLOOR(15.5) = 15`.

## Solution

```sql
WITH sessions AS (
    SELECT
        session_status,
        status_time AS start_time,
        LEAD(status_time) OVER (
            PARTITION BY server_id
            ORDER BY status_time
        ) AS stop_time
    FROM server_utilization
)
SELECT
    FLOOR(
        SUM(EXTRACT(EPOCH FROM (stop_time - start_time))) / 86400
    )::INTEGER AS total_uptime_days
FROM sessions
WHERE session_status = 'start';
```

## Validation

`05_validation.sql` contains diagnostic queries whose results are inspected manually against the expected values written in its comments. They are not automated tests and contain no assertions. They show intermediate values so it is possible to confirm the final result is not a coincidence:

- total number of events (10) and distinct servers (3);
- `start` and `stop` counts per server (5 sessions in total);
- every `start` is immediately followed by a `stop` (the pairing query should return zero rows);
- duration of each individual session (2.0, 1.5, 7.0, 2.5, 2.5 days);
- accumulated uptime per server (84, 168, 120 hours = 3.5, 7.0, 5.0 days);
- total unrounded uptime (372 hours = 15.5 days);
- final result in full days (15), shown next to the incorrect per-session flooring (14).

The output of a real run on PostgreSQL 17 is recorded in [`docs/ejecucion_postgresql.txt`](docs/ejecucion_postgresql.txt).

## Expected Result

| total_uptime_days |
|------------------:|
| 15 |

This result corresponds to the simulated dataset included in this repository, not to the sample data shown on DataLemur.

## How to Run

Run the scripts in a **dedicated practice database**: `01_create_table.sql` drops and recreates `server_utilization`, and `02_insert_data.sql` empties it before loading the sample data.

```bash
psql -X -v ON_ERROR_STOP=1 -d <practice_database> -f 01_create_table.sql -f 02_insert_data.sql -f 03_exploration.sql -f 04_solution.sql -f 05_validation.sql
```

- `-X` skips any personal `~/.psqlrc`, so output is reproducible.
- `-v ON_ERROR_STOP=1` stops execution at the first SQL error and returns a non-zero exit code. It does not turn the diagnostic queries into assertions: their results still need to be reviewed manually.

## Repository Structure

| File                  | Purpose                                                        |
|-----------------------|----------------------------------------------------------------|
| `01_create_table.sql` | Drops and recreates `server_utilization` with a CHECK constraint |
| `02_insert_data.sql`  | Loads the simulated dataset (3 servers, 5 sessions)            |
| `03_exploration.sql`  | Step-by-step queries that build up to the solution             |
| `04_solution.sql`     | Final query returning `total_uptime_days`                      |
| `05_validation.sql`   | Diagnostic queries: counts, pairing, per-session and per-server uptime |
| `docs/ejecucion_postgresql.txt` | Execution record of all five scripts on PostgreSQL 17 (in Spanish) |

## Skills Demonstrated

- PostgreSQL
- SQL
- CTEs
- Window Functions
- Data Aggregation
- Timestamp Analysis
