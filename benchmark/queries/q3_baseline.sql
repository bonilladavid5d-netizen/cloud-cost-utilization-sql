-- Q3 baseline: weekly utilization profile (day of week x hour of day) of
-- development servers during March, about one third of server_metrics.
-- The month filter wraps the column in date_trunc(), so it is evaluated
-- on every row of the table.
SELECT
    EXTRACT(ISODOW FROM m.hour_start) AS iso_dow,
    EXTRACT(HOUR FROM m.hour_start)   AS hour_of_day,
    COUNT(*)                          AS samples,
    AVG(m.cpu_avg_pct)                AS cpu_avg_pct,
    AVG(m.mem_avg_pct)                AS mem_avg_pct
FROM server_metrics m
JOIN servers s
  ON s.server_id = m.server_id
WHERE s.environment = 'development'
  AND date_trunc('month', m.hour_start) = TIMESTAMPTZ '2025-03-01 00:00:00+00'
GROUP BY 1, 2
