-- =====================================================================
-- Analysis 1 - Running time per server and month
--
-- Builds on 02_transform.sql, where sessions are reconstructed with
-- LAG/LEAD over (PARTITION BY server_id ORDER BY event_time) and split
-- into UTC hours clipped to the analysis period. Here the hours are
-- rolled up to calendar months.
--
-- Every server appears in every month of the period (calendar CROSS
-- JOIN + LEFT JOIN), so idle servers and idle months show 0 instead of
-- disappearing.
-- Grain: server x month.
-- =====================================================================

SET timezone = 'UTC';

CREATE OR REPLACE VIEW a1_uptime_by_server_month AS
WITH months AS (
    SELECT gs AS month_start, gs + INTERVAL '1 month' AS month_end
    FROM analysis_config c
    CROSS JOIN LATERAL generate_series(
        c.period_start, c.period_end - INTERVAL '1 month', INTERVAL '1 month') AS gs
),
monthly_usage AS (
    SELECT
        server_id,
        date_trunc('month', hour_start) AS month_start,
        SUM(seconds_on)                 AS seconds_on,
        COUNT(*)                        AS active_hours
    FROM server_hours
    GROUP BY server_id, date_trunc('month', hour_start)
)
SELECT
    s.server_id,
    s.hostname,
    d.department_name,
    s.environment,
    m.month_start::DATE                     AS month,
    COALESCE(u.seconds_on, 0) / 3600        AS uptime_hours,
    COALESCE(u.active_hours, 0)             AS active_hours,
    COALESCE(u.seconds_on, 0)
        / EXTRACT(EPOCH FROM (m.month_end - m.month_start)) AS uptime_share_of_month
FROM servers s
JOIN departments d
  ON d.department_id = s.department_id
CROSS JOIN months m
LEFT JOIN monthly_usage u
  ON  u.server_id   = s.server_id
  AND u.month_start = m.month_start;
