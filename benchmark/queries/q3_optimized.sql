-- Q3 optimized: the month as a half-open range on the raw column. Run
-- without and with the BRIN index on hour_start (sql/05_indexes.sql) to
-- separate the effect of the rewrite from the effect of the index.
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
  AND m.hour_start >= TIMESTAMPTZ '2025-03-01 00:00:00+00'
  AND m.hour_start <  TIMESTAMPTZ '2025-04-01 00:00:00+00'
GROUP BY 1, 2
