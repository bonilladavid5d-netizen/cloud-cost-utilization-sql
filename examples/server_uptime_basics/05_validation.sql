-- =====================================================================
-- 05_validation.sql
-- Diagnostic queries. Results are inspected manually against the
-- expected values in the comments; there are no automated assertions.
-- =====================================================================


-- 1. Total number of events. Expected: 10
SELECT COUNT(*) AS total_events
FROM server_utilization;


-- 2. Number of distinct servers. Expected: 3
SELECT COUNT(DISTINCT server_id) AS distinct_servers
FROM server_utilization;


-- 3. Start and stop events per server. Every server should have
--    matching counts (Expected: 1 -> 2/2, 2 -> 1/1, 3 -> 2/2).
SELECT
    server_id,
    COUNT(*) FILTER (WHERE session_status = 'start') AS start_events,
    COUNT(*) FILTER (WHERE session_status = 'stop')  AS stop_events
FROM server_utilization
GROUP BY server_id
ORDER BY server_id;


-- 3b. Pairing check: the event following each start must be a stop.
--     Expected: 0 rows.
WITH ordered_events AS (
    SELECT
        server_id,
        status_time,
        session_status,
        LEAD(session_status) OVER (
            PARTITION BY server_id
            ORDER BY status_time
        ) AS next_status
    FROM server_utilization
)
SELECT *
FROM ordered_events
WHERE session_status = 'start'
  AND (next_status IS DISTINCT FROM 'stop');


-- 4. Duration of each session.
--    Expected (days): 2.0, 1.5 | 7.0 | 2.5, 2.5
WITH sessions AS (
    SELECT
        server_id,
        session_status,
        status_time AS start_time,
        LEAD(status_time) OVER (
            PARTITION BY server_id
            ORDER BY status_time
        ) AS stop_time
    FROM server_utilization
)
SELECT
    server_id,
    start_time,
    stop_time,
    stop_time - start_time                                    AS session_interval,
    EXTRACT(EPOCH FROM (stop_time - start_time)) / 3600       AS session_hours,
    EXTRACT(EPOCH FROM (stop_time - start_time)) / 86400      AS session_days
FROM sessions
WHERE session_status = 'start'
ORDER BY server_id, start_time;


-- 5. Accumulated uptime per server.
--    Expected (days): 1 -> 3.5, 2 -> 7.0, 3 -> 5.0
WITH sessions AS (
    SELECT
        server_id,
        session_status,
        status_time AS start_time,
        LEAD(status_time) OVER (
            PARTITION BY server_id
            ORDER BY status_time
        ) AS stop_time
    FROM server_utilization
)
SELECT
    server_id,
    COUNT(*)                                                  AS session_count,
    SUM(EXTRACT(EPOCH FROM (stop_time - start_time))) / 3600  AS uptime_hours,
    SUM(EXTRACT(EPOCH FROM (stop_time - start_time))) / 86400 AS uptime_days
FROM sessions
WHERE session_status = 'start'
GROUP BY server_id
ORDER BY server_id;


-- 6. Total fleet uptime, unrounded. Expected: 372 hours = 15.5 days
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
    SUM(EXTRACT(EPOCH FROM (stop_time - start_time)))         AS total_seconds,
    SUM(EXTRACT(EPOCH FROM (stop_time - start_time))) / 3600  AS total_hours,
    SUM(EXTRACT(EPOCH FROM (stop_time - start_time))) / 86400 AS total_days
FROM sessions
WHERE session_status = 'start';


-- 7. Final result in full days, compared with the incorrect approach
--    of flooring each session before summing.
--    Expected: total_uptime_days = 15, floor_per_session_days = 14
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
    FLOOR(SUM(EXTRACT(EPOCH FROM (stop_time - start_time))) / 86400)::INTEGER
        AS total_uptime_days,
    SUM(FLOOR(EXTRACT(EPOCH FROM (stop_time - start_time)) / 86400))::INTEGER
        AS floor_per_session_days
FROM sessions
WHERE session_status = 'start';
