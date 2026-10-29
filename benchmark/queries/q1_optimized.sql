-- Q1 optimized: same week as a half-open timestamp range. Both columns of
-- the primary key (server_id, hour_start) become index conditions, so
-- only the 168 matching entries are read. No new index is needed.
SELECT hour_start, cpu_avg_pct, mem_avg_pct
FROM server_metrics
WHERE server_id = 42
  AND hour_start >= TIMESTAMPTZ '2025-02-10 00:00:00+00'
  AND hour_start <  TIMESTAMPTZ '2025-02-17 00:00:00+00'
ORDER BY hour_start
