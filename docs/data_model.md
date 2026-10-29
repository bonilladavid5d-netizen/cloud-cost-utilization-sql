# Data model and dictionary

All data is simulated. Source tables are created in [`sql/01_schema.sql`](../sql/01_schema.sql); derived tables in [`sql/02_transform.sql`](../sql/02_transform.sql).

## Relationship diagram

```mermaid
erDiagram
    departments ||--o{ servers : owns
    departments ||--o{ budgets : "budget per month"
    servers ||--o{ server_events : "power events"
    servers ||--o{ server_metrics : "hourly metrics"
    servers }o--|{ pricing : "instance_type + region + valid hour (logical, no FK)"
    server_events ||--|| event_validation : "pairing status"
    servers ||--o{ server_sessions : "valid sessions"
    servers ||--o{ server_hours : "running seconds per hour"

    departments {
        smallint department_id PK
        text department_name UK
        text cost_center UK
    }
    servers {
        integer server_id PK
        text hostname UK
        smallint department_id FK
        text region
        text instance_type
        text environment "production | development"
        boolean is_critical
    }
    server_events {
        bigint event_id PK
        integer server_id FK "UNIQUE (server_id, event_time)"
        timestamptz event_time
        text event_type "start | stop"
    }
    server_metrics {
        integer server_id PK,FK
        timestamptz hour_start PK "aligned to the hour"
        numeric cpu_avg_pct "0-100"
        numeric mem_avg_pct "0-100"
    }
    pricing {
        integer pricing_id PK
        text instance_type "EXCLUDE overlap per type+region"
        text region
        timestamptz valid_from "00:00 UTC"
        timestamptz valid_to "exclusive"
        numeric hourly_rate_usd
    }
    budgets {
        smallint department_id PK,FK
        date budget_month PK "first day of month"
        numeric amount_usd ">= 0"
    }
    event_validation {
        bigint event_id PK,FK
        text status "paired or exclusion reason"
    }
    server_sessions {
        bigint session_id PK
        integer server_id FK
        bigint start_event_id UK
        bigint stop_event_id UK
        timestamptz session_start
        timestamptz session_stop
    }
    server_hours {
        integer server_id PK,FK
        timestamptz hour_start PK
        numeric seconds_on "0 < s <= 3600"
    }
```

`pricing` is not linked to `servers` by a foreign key: a server needs the tariff that is valid at each hour, which is a range lookup on `(instance_type, region)` plus time. Overlaps are impossible (exclusion constraint) and gaps are reported by `dq_pricing_gaps`.

## Source tables

| Table | Grain (one row per…) | Key | Notes |
|---|---|---|---|
| `departments` | business area | `department_id` | `cost_center` unique, format `CC-0000`. |
| `servers` | server | `server_id` | Department, region and type are constant during the period (simplification). `environment` ∈ production/development; `is_critical` marks servers excluded from shutdown scenarios. |
| `server_events` | power event | `event_id`; unique `(server_id, event_time)` | The unique key rejects exact duplicates and same-instant start/stop ties at load time. |
| `server_metrics` | server × UTC clock hour | `(server_id, hour_start)` | Average CPU and memory over the part of that hour in which the server ran. A missing row = not observed (unknown), never 0 %. |
| `pricing` | tariff version | `pricing_id`; exclusion on `(instance_type, region, [valid_from, valid_to))` | Fictitious USD per running hour. Changes take effect at 00:00 UTC (check constraint). |
| `budgets` | department × month | `(department_id, budget_month)` | `amount_usd = 0` is an explicit zero budget; a missing row means no budget defined. |
| `analysis_config` | single row | `config_id` (always `TRUE`) | Analysis period and the parameters of analyses 4 and 6. |

## Derived tables and views

| Object | Grain | Built from | Purpose |
|---|---|---|---|
| `event_validation` | event | `server_events` + `LAG`/`LEAD` | `paired` or one explicit exclusion reason. |
| `server_sessions` | valid session | paired events | One start with its immediately following stop. |
| `server_hours` | server × UTC hour | sessions clipped to the period | Running seconds per hour; base grain for cost, metrics and schedules. |
| `v_hourly_cost` | server × UTC hour | `server_hours` + `servers` + `pricing` | Cost model: `seconds_on / 3600 × hourly_rate_usd`. |
| `dq_*` views | various | all of the above | Event status, pricing gaps, unpriced hours, coverage counts. |
| `a1`–`a6` views | see each file | `sql/analysis/` | The six analyses. |
| `a4_low_utilization` | server | `server_hours`, `server_metrics`, `v_hourly_cost` | Bin counts (`active_hour_bins`, `observed_hour_bins`) are kept apart from durations (`running_seconds`, `observed_seconds`, `observed_running_hours`). `metric_coverage` = observed / running seconds. Full definitions: [methodology](methodology.md#units-in-analysis-4). |

## Column types

- Instants: `TIMESTAMPTZ`, always interpreted in UTC (`timezone` is set to UTC on the database and in every script).
- Money: `NUMERIC` (exact). Rates keep 4 decimals, budgets 2; intermediate costs keep full precision and are rounded only in exported CSV files.
- Percentages: `NUMERIC(5,2)` with `CHECK` 0–100.
