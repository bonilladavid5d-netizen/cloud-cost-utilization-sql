-- =====================================================================
-- Analysis 4 - Low utilization observed during the analysis period
--
-- Each source is aggregated to one row per server before joining
-- (running time, observed metrics, cost), so no source multiplies
-- another.
--
-- Units. A server-hour row (server_hours) is a UTC clock-hour bin that
-- may hold only a few running seconds. Bins are reported as counts
-- (active_hour_bins, observed_hour_bins) but every duration threshold
-- uses real running time:
--   running_seconds        SUM(seconds_on) over all bins
--   observed_seconds       SUM(seconds_on) over bins that have a metric
--   observed_running_hours observed_seconds / 3600
--   metric_coverage        observed_seconds / running_seconds
-- Metrics are only used for bins with a valid session (INNER JOIN with
-- server_hours). A missing metric is unknown: it lowers coverage and is
-- never treated as 0 % CPU.
--
-- Statistics over observed bins:
--   cpu_avg_pct, mem_avg_pct  averages weighted by running seconds
--   cpu_p95_pct               95th percentile (continuous) of the
--                             observed hourly CPU averages, unweighted
--
-- Classification (thresholds in analysis_config, chosen for this
-- simulated case):
--   no_activity        no running time in the period
--   insufficient_data  observed_seconds < low_min_observed_hours * 3600
--                      or metric_coverage < low_min_coverage
--   low_utilization    avg CPU, p95 CPU and avg memory all at or below
--                      their thresholds
--   normal             everything else
-- Grain: server.
-- =====================================================================

SET timezone = 'UTC';

CREATE OR REPLACE VIEW a4_low_utilization AS
WITH running AS (
    SELECT
        server_id,
        COUNT(*)        AS active_hour_bins,
        SUM(seconds_on) AS running_seconds
    FROM server_hours
    GROUP BY server_id
),
observed AS (
    SELECT
        h.server_id,
        COUNT(*)                                              AS observed_hour_bins,
        SUM(h.seconds_on)                                     AS observed_seconds,
        SUM(m.cpu_avg_pct * h.seconds_on) / SUM(h.seconds_on) AS cpu_avg_pct,
        percentile_cont(0.95) WITHIN GROUP (ORDER BY m.cpu_avg_pct)::NUMERIC
                                                              AS cpu_p95_pct,
        SUM(m.mem_avg_pct * h.seconds_on) / SUM(h.seconds_on) AS mem_avg_pct
    FROM server_hours h
    JOIN server_metrics m
      ON  m.server_id  = h.server_id
      AND m.hour_start = h.hour_start
    GROUP BY h.server_id
),
server_cost AS (
    SELECT server_id, SUM(cost_usd) AS compute_cost_usd
    FROM v_hourly_cost
    GROUP BY server_id
),
measured AS (
    SELECT
        s.server_id,
        s.hostname,
        d.department_name,
        s.environment,
        s.is_critical,
        s.instance_type,
        s.region,
        COALESCE(r.active_hour_bins, 0)          AS active_hour_bins,
        COALESCE(o.observed_hour_bins, 0)        AS observed_hour_bins,
        COALESCE(r.running_seconds, 0)           AS running_seconds,
        COALESCE(o.observed_seconds, 0)          AS observed_seconds,
        COALESCE(r.running_seconds, 0) / 3600    AS uptime_hours,
        COALESCE(o.observed_seconds, 0) / 3600   AS observed_running_hours,
        COALESCE(o.observed_seconds, 0) / NULLIF(r.running_seconds, 0)
                                                 AS metric_coverage,
        o.cpu_avg_pct,
        o.cpu_p95_pct,
        o.mem_avg_pct,
        COALESCE(c.compute_cost_usd, 0)          AS compute_cost_usd
    FROM servers s
    JOIN departments d ON d.department_id = s.department_id
    LEFT JOIN running     r ON r.server_id = s.server_id
    LEFT JOIN observed    o ON o.server_id = s.server_id
    LEFT JOIN server_cost c ON c.server_id = s.server_id
)
SELECT
    m.*,
    CASE
        WHEN m.running_seconds = 0 THEN 'no_activity'
        WHEN m.observed_seconds < cfg.low_min_observed_hours * 3600
          OR m.metric_coverage  < cfg.low_min_coverage THEN 'insufficient_data'
        WHEN m.cpu_avg_pct <= cfg.low_cpu_avg_max_pct
         AND m.cpu_p95_pct <= cfg.low_cpu_p95_max_pct
         AND m.mem_avg_pct <= cfg.low_mem_avg_max_pct THEN 'low_utilization'
        ELSE 'normal'
    END AS utilization_class
FROM measured m
CROSS JOIN analysis_config cfg;
