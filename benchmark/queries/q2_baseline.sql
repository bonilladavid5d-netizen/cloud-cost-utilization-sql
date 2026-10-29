-- Q2 baseline: monthly compute cost by department, region and environment,
-- joining every server-hour (about 0.7 million rows) to servers,
-- departments and the tariff valid at that hour.
SELECT
    date_trunc('month', h.hour_start) AS month,
    d.department_name,
    s.region,
    s.environment,
    SUM(h.seconds_on * p.hourly_rate_usd) / 3600 AS compute_cost_usd
FROM server_hours h
JOIN servers s
  ON s.server_id = h.server_id
JOIN departments d
  ON d.department_id = s.department_id
JOIN pricing p
  ON  p.instance_type = s.instance_type
  AND p.region        = s.region
  AND h.hour_start >= p.valid_from
  AND h.hour_start <  p.valid_to
GROUP BY 1, 2, 3, 4
