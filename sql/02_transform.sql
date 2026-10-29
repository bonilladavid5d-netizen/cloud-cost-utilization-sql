-- =====================================================================
-- 02_transform.sql
-- Rebuilds the derived tables from server_events:
--   event_validation -> pairing status of every event
--   server_sessions  -> one row per valid start/stop pair
--   server_hours     -> running seconds per server and UTC clock hour,
--                       clipped to the analysis period
-- Re-runnable: drops and recreates the derived tables (and any views
-- that depend on them; run 03_views.sql and sql/analysis/ afterwards).
-- =====================================================================

SET client_min_messages = warning;
SET timezone = 'UTC';

DROP TABLE IF EXISTS server_hours, server_sessions, event_validation CASCADE;


-- ---------------------------------------------------------------------
-- 1. Event validation.
--    Events are ordered by event_time inside each server (never by
--    insertion order). A session is accepted only when a start is
--    immediately followed by a stop AND is not itself preceded by
--    another start. Every other event is excluded with a reason, so
--    ambiguous sequences are never paired silently:
--      start_followed_by_start    start whose next event is a start
--      open_start                 start with no later event in the extract
--      start_preceded_by_start    start right after an unclosed start
--      stop_without_start         stop whose previous event is not a start
--      stop_after_ambiguous_start stop that closes an excluded start
--    The full event history is used (no date filter), so sessions that
--    began before the analysis period are still reconstructed.
-- ---------------------------------------------------------------------
CREATE TABLE event_validation (
    event_id   BIGINT      PRIMARY KEY REFERENCES server_events (event_id),
    server_id  INTEGER     NOT NULL,
    event_time TIMESTAMPTZ NOT NULL,
    event_type TEXT        NOT NULL,
    status     TEXT        NOT NULL CHECK (status IN (
        'paired', 'start_followed_by_start', 'open_start',
        'start_preceded_by_start', 'stop_without_start',
        'stop_after_ambiguous_start'))
);

INSERT INTO event_validation (event_id, server_id, event_time, event_type, status)
WITH ordered_events AS (
    SELECT
        e.event_id,
        e.server_id,
        e.event_time,
        e.event_type,
        LAG(e.event_type, 1) OVER w AS prev_type,
        LAG(e.event_type, 2) OVER w AS prev2_type,
        LEAD(e.event_type)   OVER w AS next_type
    FROM server_events e
    WINDOW w AS (PARTITION BY e.server_id ORDER BY e.event_time)
)
SELECT
    event_id,
    server_id,
    event_time,
    event_type,
    CASE
        WHEN event_type = 'start' AND next_type = 'start'            THEN 'start_followed_by_start'
        WHEN event_type = 'start' AND next_type IS NULL              THEN 'open_start'
        WHEN event_type = 'start' AND prev_type = 'start'            THEN 'start_preceded_by_start'
        WHEN event_type = 'start'                                    THEN 'paired'
        WHEN prev_type IS DISTINCT FROM 'start'                      THEN 'stop_without_start'
        WHEN prev2_type = 'start'                                    THEN 'stop_after_ambiguous_start'
        ELSE 'paired'
    END
FROM ordered_events;


-- ---------------------------------------------------------------------
-- 2. Sessions: each paired start with its immediately following stop.
-- ---------------------------------------------------------------------
CREATE TABLE server_sessions (
    session_id     BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    server_id      INTEGER     NOT NULL REFERENCES servers (server_id),
    start_event_id BIGINT      NOT NULL UNIQUE REFERENCES server_events (event_id),
    stop_event_id  BIGINT      NOT NULL UNIQUE REFERENCES server_events (event_id),
    session_start  TIMESTAMPTZ NOT NULL,
    session_stop   TIMESTAMPTZ NOT NULL,
    CHECK (session_start < session_stop)
);

INSERT INTO server_sessions (server_id, start_event_id, stop_event_id, session_start, session_stop)
WITH paired AS (
    SELECT
        server_id,
        event_id,
        event_type,
        event_time,
        LEAD(event_id)   OVER w AS next_event_id,
        LEAD(event_time) OVER w AS next_event_time
    FROM event_validation
    WHERE status = 'paired'
    WINDOW w AS (PARTITION BY server_id ORDER BY event_time)
)
SELECT server_id, event_id, next_event_id, event_time, next_event_time
FROM paired
WHERE event_type = 'start'
ORDER BY server_id, event_time;


-- ---------------------------------------------------------------------
-- 3. Hourly split. Each session is clipped to [period_start, period_end)
--    and divided into UTC clock hours, so sessions that cross midnight,
--    month ends or tariff changes are allocated to the correct hour.
--    Two sessions inside the same hour are summed (they never overlap).
-- ---------------------------------------------------------------------
CREATE TABLE server_hours (
    server_id  INTEGER     NOT NULL REFERENCES servers (server_id),
    hour_start TIMESTAMPTZ NOT NULL,
    seconds_on NUMERIC     NOT NULL CHECK (seconds_on > 0 AND seconds_on <= 3600),
    PRIMARY KEY (server_id, hour_start)
);

INSERT INTO server_hours (server_id, hour_start, seconds_on)
SELECT
    s.server_id,
    h.hour_start,
    SUM(EXTRACT(EPOCH FROM
        LEAST(clip.stop_at, h.hour_start + INTERVAL '1 hour')
        - GREATEST(clip.start_at, h.hour_start)
    ))
FROM server_sessions s
CROSS JOIN analysis_config c
CROSS JOIN LATERAL (
    SELECT
        GREATEST(s.session_start, c.period_start) AS start_at,
        LEAST(s.session_stop, c.period_end)       AS stop_at
) clip
CROSS JOIN LATERAL generate_series(
    date_trunc('hour', clip.start_at),
    clip.stop_at,
    INTERVAL '1 hour'
) AS h(hour_start)
WHERE clip.start_at < clip.stop_at
  AND h.hour_start < clip.stop_at
GROUP BY s.server_id, h.hour_start
ORDER BY s.server_id, h.hour_start;

ANALYZE event_validation;
ANALYZE server_sessions;
ANALYZE server_hours;
