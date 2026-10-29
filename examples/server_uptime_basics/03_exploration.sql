-- =====================================================================
-- 03_exploration.sql
-- Step-by-step queries that build up to the final solution.
-- =====================================================================


-- ---------------------------------------------------------------------
-- A. Raw events ordered per server.
--    Under the exercise assumptions, events alternate start -> stop.
-- ---------------------------------------------------------------------
SELECT
    server_id,
    status_time,
    session_status
FROM server_utilization
ORDER BY server_id, status_time;


-- ---------------------------------------------------------------------
-- B. LEAD() returns the timestamp of the next event of the same server.
--    PARTITION BY keeps servers independent; ORDER BY makes "next"
--    mean "chronologically next". The last event of each server has
--    no next event, so LEAD() returns NULL there.
-- ---------------------------------------------------------------------
SELECT
    server_id,
    status_time,
    session_status,
    LEAD(status_time) OVER (
        PARTITION BY server_id
        ORDER BY status_time
    ) AS next_status_time
FROM server_utilization
ORDER BY server_id, status_time;


-- ---------------------------------------------------------------------
-- C + D. Wrap the window query in a CTE and keep only 'start' rows.
--        For a start event, the next event is its matching stop,
--        so each remaining row is one complete session.
-- ---------------------------------------------------------------------
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
    stop_time
FROM sessions
WHERE session_status = 'start'
ORDER BY server_id, start_time;


-- ---------------------------------------------------------------------
-- E. Subtracting two TIMESTAMPs returns an INTERVAL.
-- ---------------------------------------------------------------------
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
    stop_time - start_time AS session_duration
FROM sessions
WHERE session_status = 'start'
ORDER BY server_id, start_time;


-- ---------------------------------------------------------------------
-- F + G. EXTRACT(EPOCH FROM interval) gives the duration in seconds,
--        which can then be divided by 86400 (seconds per day).
--        Note the fractional days (e.g. 1.5, 2.5): flooring here,
--        per session, would lose time. Rounding happens only at the end.
-- ---------------------------------------------------------------------
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
    EXTRACT(EPOCH FROM (stop_time - start_time))           AS session_seconds,
    EXTRACT(EPOCH FROM (stop_time - start_time)) / 86400   AS session_days
FROM sessions
WHERE session_status = 'start'
ORDER BY server_id, start_time;
