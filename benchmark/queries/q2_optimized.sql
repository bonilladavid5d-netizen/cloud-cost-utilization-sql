-- Q2 optimized: aggregate running seconds to server x day first, then
-- join. Valid because tariffs can only change at 00:00 UTC (CHECK
-- constraint chk_pricing_midnight_utc), so a whole day has one rate.
-- The multiplication by the rate moves after the daily sum; with exact
-- NUMERIC arithmetic the totals are identical.
WITH daily AS (
    SELECT
        server_id,
        date_trunc('day', hour_start) AS day_start,
        SUM(seconds_on)               AS seconds_on
    FROM server_hours
    GROUP BY server_id, date_trunc('day', hour_start)
)
SELECT
    date_trunc('month', dl.day_start) AS month,
    d.department_name,
    s.region,
    s.environment,
    SUM(dl.seconds_on * p.hourly_rate_usd) / 3600 AS compute_cost_usd
FROM daily dl
JOIN servers s
  ON s.server_id = dl.server_id
JOIN departments d
  ON d.department_id = s.department_id
JOIN pricing p
  ON  p.instance_type = s.instance_type
  AND p.region        = s.region
  AND dl.day_start >= p.valid_from
  AND dl.day_start <  p.valid_to
GROUP BY 1, 2, 3, 4
