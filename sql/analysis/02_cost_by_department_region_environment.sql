-- =====================================================================
-- Analysis 2 - Monthly compute cost by department, region, environment
--
-- v_hourly_cost already holds one row per server-hour with the tariff
-- valid at that hour (servers -> pricing on type, region and validity).
-- Joining departments is an INNER JOIN on purpose: this view describes
-- consumption, so only combinations with priced usage appear. Areas
-- without consumption are kept in analysis 3 (budget comparison).
-- Hours without a tariff are excluded here and reported by
-- dq_unpriced_hours.
-- Grain: month x department x region x environment.
-- =====================================================================

SET timezone = 'UTC';

CREATE OR REPLACE VIEW a2_cost_by_department_region_environment AS
SELECT
    date_trunc('month', hc.hour_start)::DATE AS month,
    d.department_name,
    d.cost_center,
    hc.region,
    hc.environment,
    COUNT(DISTINCT hc.server_id)             AS active_servers,
    SUM(hc.seconds_on) / 3600                AS billed_hours,
    SUM(hc.cost_usd)                         AS compute_cost_usd
FROM v_hourly_cost hc
JOIN departments d
  ON d.department_id = hc.department_id
WHERE hc.cost_usd IS NOT NULL
GROUP BY
    date_trunc('month', hc.hour_start),
    d.department_name,
    d.cost_center,
    hc.region,
    hc.environment;
