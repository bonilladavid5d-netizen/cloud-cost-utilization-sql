-- =====================================================================
-- 02_insert_data.sql
-- Loads a small simulated dataset.
--
-- Expected uptime per server:
--   Server 1: 48h + 36h = 84h  = 3.5 days
--   Server 2: 168h          = 168h = 7.0 days
--   Server 3: 60h + 60h     = 120h = 5.0 days
--   Fleet total              = 372h = 15.5 days -> 15 full days
-- =====================================================================

TRUNCATE TABLE server_utilization;

INSERT INTO server_utilization (server_id, status_time, session_status) VALUES
    -- Server 1: two sessions (2 days, then 1.5 days)
    (1, '2022-08-02 10:00:00', 'start'),
    (1, '2022-08-04 10:00:00', 'stop'),
    (1, '2022-08-05 08:00:00', 'start'),
    (1, '2022-08-06 20:00:00', 'stop'),

    -- Server 2: one session (7 days)
    (2, '2022-08-17 10:00:00', 'start'),
    (2, '2022-08-24 10:00:00', 'stop'),

    -- Server 3: two sessions (2.5 days each)
    (3, '2022-08-01 00:00:00', 'start'),
    (3, '2022-08-03 12:00:00', 'stop'),
    (3, '2022-08-10 06:00:00', 'start'),
    (3, '2022-08-12 18:00:00', 'stop');
