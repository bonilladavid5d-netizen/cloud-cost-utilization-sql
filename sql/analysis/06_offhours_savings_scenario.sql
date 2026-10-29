-- =====================================================================
-- Analysis 6 - Potential savings from an off-hours shutdown schedule
--
-- Scenario (assumptions, not a recommendation):
--   * Eligible servers: environment = 'development' AND NOT is_critical.
--   * Reference schedule in UTC: servers stay on Monday-Friday during
--     [workday_start_hour, workday_end_hour); every other hour (nights
--     and weekends) is the proposed shutdown window.
--   * Potential savings = cost of the running time that falls inside
--     the shutdown window, at the tariff valid at that hour.
-- The result is an upper bound under these assumptions. It is not a
-- measured saving, and shutting down any of these servers requires an
-- operational review (jobs, users in other time zones, dependencies).
-- Hours without a tariff count as running hours but add no cost.
-- =====================================================================

SET timezone = 'UTC';

-- Grain: eligible server.
CREATE OR REPLACE VIEW a6_offhours_savings_by_server AS
WITH eligible AS (
    SELECT s.server_id, s.hostname, s.department_id, s.instance_type, s.region
    FROM servers s
    WHERE s.environment = 'development'
      AND NOT s.is_critical
),
classified AS (
    SELECT
        hc.server_id,
        hc.seconds_on,
        hc.cost_usd,
        (   EXTRACT(ISODOW FROM hc.hour_start) IN (6, 7)
         OR EXTRACT(HOUR FROM hc.hour_start) <  cfg.workday_start_hour
         OR EXTRACT(HOUR FROM hc.hour_start) >= cfg.workday_end_hour
        ) AS in_shutdown_window
    FROM v_hourly_cost hc
    JOIN eligible e ON e.server_id = hc.server_id
    CROSS JOIN analysis_config cfg
),
per_server AS (
    SELECT
        server_id,
        SUM(seconds_on) / 3600                                   AS uptime_hours,
        COALESCE(SUM(seconds_on) FILTER (WHERE in_shutdown_window), 0) / 3600
                                                                 AS shutdown_window_hours,
        COALESCE(SUM(cost_usd), 0)                               AS eligible_cost_usd,
        COALESCE(SUM(cost_usd) FILTER (WHERE in_shutdown_window), 0)
                                                                 AS potential_savings_usd
    FROM classified
    GROUP BY server_id
)
SELECT
    e.server_id,
    e.hostname,
    d.department_name,
    e.instance_type,
    e.region,
    COALESCE(p.uptime_hours, 0)          AS uptime_hours,
    COALESCE(p.shutdown_window_hours, 0) AS shutdown_window_hours,
    COALESCE(p.eligible_cost_usd, 0)     AS eligible_cost_usd,
    COALESCE(p.potential_savings_usd, 0) AS potential_savings_usd
FROM eligible e
JOIN departments d ON d.department_id = e.department_id
LEFT JOIN per_server p ON p.server_id = e.server_id;


-- Grain: department, plus a total row (department_name = 'ALL').
CREATE OR REPLACE VIEW a6_offhours_savings_summary AS
SELECT
    COALESCE(department_name, 'ALL')       AS department_name,
    COUNT(*)                               AS eligible_servers,
    COUNT(*) FILTER (WHERE uptime_hours > 0) AS eligible_servers_with_activity,
    SUM(uptime_hours)                      AS uptime_hours,
    SUM(shutdown_window_hours)             AS shutdown_window_hours,
    SUM(eligible_cost_usd)                 AS eligible_cost_usd,
    SUM(potential_savings_usd)             AS potential_savings_usd,
    SUM(potential_savings_usd) / NULLIF(SUM(eligible_cost_usd), 0)
                                           AS savings_share_of_eligible
FROM a6_offhours_savings_by_server
GROUP BY ROLLUP (department_name);
