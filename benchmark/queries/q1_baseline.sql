-- Q1 baseline: hourly metrics of one server for one week (Feb 10-16).
-- Correct, but the cast hour_start::date hides the column from the
-- primary-key range condition: the index can only use server_id, so all
-- of the server's rows are visited and filtered one by one.
SELECT hour_start, cpu_avg_pct, mem_avg_pct
FROM server_metrics
WHERE server_id = 42
  AND hour_start::date BETWEEN DATE '2025-02-10' AND DATE '2025-02-16'
ORDER BY hour_start
