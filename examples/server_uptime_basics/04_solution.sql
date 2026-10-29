-- =====================================================================
-- 04_solution.sql
-- Total fleet uptime in full days.
--
-- 1. Order each server's events chronologically.
-- 2. LEAD() fetches the next event's timestamp (the matching stop).
-- 3. Keep only start events: one row per session.
-- 4. Session duration = stop_time - start_time, in seconds.
-- 5. Sum all sessions first, then convert to days and floor once.
-- =====================================================================

WITH sessions AS (
    SELECT
        session_status,
        status_time AS start_time,
        LEAD(status_time) OVER (
            PARTITION BY server_id
            ORDER BY status_time
        ) AS stop_time
    FROM server_utilization
)
SELECT
    FLOOR(
        SUM(EXTRACT(EPOCH FROM (stop_time - start_time))) / 86400
    )::INTEGER AS total_uptime_days
FROM sessions
WHERE session_status = 'start';
