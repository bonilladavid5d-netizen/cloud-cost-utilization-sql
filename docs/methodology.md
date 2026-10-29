# Methodology and calculation rules

Everything here applies to simulated data. The rules are design decisions for this case study, written down so each result can be traced back to them.

## Time conventions

- **Period:** `[2025-01-01 00:00 UTC, 2025-04-01 00:00 UTC)`, 90 days, stored in `analysis_config`.
- **Half-open intervals everywhere:** a session `[start, stop)`, an hour `[hour_start, hour_start + 1 h)`, a tariff `[valid_from, valid_to)`, the period itself. An instant at a boundary belongs to exactly one interval, so nothing is counted twice or lost.
- **UTC only.** Months, days, hours and weekdays are UTC calendar units. Local business hours of real teams are out of scope.

## From events to running time

1. **Order, don't trust insertion.** Events are ordered by `event_time` within each server using window functions (`PARTITION BY server_id ORDER BY event_time`).
2. **Pairing rule.** A session is a `start` immediately followed by a `stop`, where that `start` is not itself preceded by another `start`. Everything else is excluded and counted with a reason (`dq_event_status`):

   | Status | Meaning | Example |
   |---|---|---|
   | `start_followed_by_start` | start whose next event is another start | lost stop |
   | `start_preceded_by_start` | start right after an unclosed start | second start of the same ambiguity |
   | `stop_after_ambiguous_start` | stop that closes such a start | — |
   | `stop_without_start` | stop whose previous event is not a start | lost start |
   | `open_start` | start with no later event in the extract | incomplete session |

   The conservative choice is deliberate: in `start, start, stop` we cannot know which start the stop belongs to, so none of the three is paired. Running time is under-counted rather than invented, and the number of excluded events is reported.
3. **Rejected at load time.** Exact duplicates and a start and stop at the same instant break the unique key `(server_id, event_time)` and never enter the table.
4. **Period boundaries.** The event extract starts before and ends after the period (Dec 25 – Apr 8). Sessions are reconstructed from the whole extract **before** any date filter, then clipped to the period. A session from Dec 31 20:00 to Jan 2 20:00 contributes 44 hours, not 0 and not 48. In the generated data every server's history ends with a stop inside the extract; an `open_start` therefore only appears as an injected anomaly.
5. **Hourly split.** Each clipped session is cut into UTC clock hours (`server_hours`). This is what makes sessions that cross midnight, month ends and tariff changes allocate correctly: every later step works on hours.

## Cost model

- Cost of a server-hour = `seconds_on / 3600 × hourly_rate_usd`, using the tariff valid at `hour_start`.
- Tariffs change only at 00:00 UTC, so one hour always has one tariff. In the data, the `gp.*` types become 6 % more expensive and `mem.large` in `eu-central` 5 % cheaper on 2025-02-15 (mid-month).
- Only compute time is billed. Storage, data transfer, taxes, commitments and discounts are excluded.
- Hours without a valid tariff keep `cost_usd = NULL`, are listed in `dq_unpriced_hours`, and are never priced with a guess. The pipeline's quality gate fails if generated data has any.

## Metrics

- One `server_metrics` row describes one UTC clock hour: the average CPU and memory over the part of that hour in which the server ran.
- Metrics are used only for hours with reconstructed running time (inner join with `server_hours`). Samples for hours without a valid session are counted in `dq_summary` and ignored.
- A missing row is unknown, not 0 %.

### Units in analysis 4

A `server_hours` row is a clock-hour **bin**. It can hold anything from 1 second to 3,600 seconds of running time. Bins are therefore reported only as counts, and every duration threshold uses seconds:

| Column | Definition |
|---|---|
| `active_hour_bins` | bins with any running time |
| `observed_hour_bins` | bins with running time and a metric row |
| `running_seconds` | `SUM(seconds_on)` over all bins |
| `observed_seconds` | `SUM(seconds_on)` over bins with a metric row |
| `observed_running_hours` | `observed_seconds / 3600` |
| `metric_coverage` | `observed_seconds / running_seconds` (time-based, not a ratio of bin counts) |
| `cpu_avg_pct`, `mem_avg_pct` | averages of the observed hourly values, weighted by running seconds |
| `cpu_p95_pct` | 95th percentile (continuous) of the observed hourly CPU averages, unweighted |

Example: eight observed bins with 1 running second each, plus two unobserved full hours, give `metric_coverage` = 8 / 7,208 (about 0.1 %), not 8 / 10. The tests in [`tests/sql/test_partial_hours_*.sql`](../tests/sql/) cover this case, the "many short bins" case and the exact minimum.
- The simulator drops about 2 % of samples at random and gives about 6 % of servers a 2–12 day monitoring outage.

## Avoiding fan-out

Every analysis aggregates each source to its natural grain before combining them: spend per department and month before joining budgets (a3), running time, metrics and cost per server before classifying (a4). The automated tests and the pipeline's quality gate check that totals are conserved across breakdowns and that the pricing join returns exactly one row per server-hour.

## Analysis parameters

| Parameter | Value | Why this value (project choice, not a standard) |
|---|---|---|
| `low_cpu_avg_max_pct` | 10 | Average CPU at this level leaves most of the instance unused. |
| `low_cpu_p95_max_pct` | 30 | Guards against servers that are quiet on average but have real peaks. |
| `low_mem_avg_max_pct` | 40 | Avoids flagging servers that are memory-bound with low CPU. |
| `low_min_observed_hours` | 168 | At least one week of observed running time before judging, applied as `observed_seconds >= 168 × 3600`. |
| `low_min_coverage` | 0.80 | At least 80 % of running time (in seconds) must be observed. |
| `workday_start_hour` / `workday_end_hour` | 7 / 20 | Reference schedule: Monday–Friday 07:00–20:00 UTC stays on; nights and weekends form the proposed shutdown window. |

The test fixtures lower `low_min_observed_hours` (to 6 in `fixture_core.sql` and 4 in `fixture_partial_hours.sql`) because they cover only a few hours. "Low utilization" in this project always means low utilization **observed during the 90-day analysis period** under these thresholds. It says nothing about longer-term behavior.

## Savings scenario (analysis 6)

- Eligible servers: `environment = 'development'` and `NOT is_critical`.
- Potential savings = cost of running time inside the shutdown window.
- It is an upper bound under these assumptions: it ignores jobs scheduled at night, users in other time zones, start-up time, dependencies and any cost of restarting. It describes what could be reviewed, not a saving that was achieved or a change that is safe to make.

## Simulation

[`generator/generate_data.py`](../generator/generate_data.py) uses a fixed seed (`20250101`), fixed dates and an independent random stream per server, so the same parameters always produce byte-identical CSV files (SHA-256 recorded in each `manifest.json`).

- **Production servers:** always on, with occasional Sunday maintenance restarts.
- **Development servers:** office hours (some sessions forgotten overnight or over the weekend), extended hours, sporadic use, always on, or inactive.
- **Utilization profiles:** idle, light, moderate or busy, with a weekday business-hours pattern.
- **Budgets:** follow a simple planning rule (list price × planned hours × a department factor), independent of the simulated usage. Special cases: Research Lab has a budget and no servers; Internal Tools has a zero budget in March; Marketing Technology has no budget row for February.
- **Injected log damage:** a few lost `stop` and lost `start` events, so event validation has something real to catch.

The analyses only see the CSV inputs. No result is computed in the generator.
