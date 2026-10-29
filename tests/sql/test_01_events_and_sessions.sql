-- Event validation and session reconstruction (fixture_core.sql).

-- 25 events: 20 paired, 5 excluded (all on s3).
SELECT assert_eq('events total', (SELECT COUNT(*) FROM event_validation), 25);
SELECT assert_eq('paired events', (SELECT COUNT(*) FROM event_validation WHERE status = 'paired'), 20);
SELECT assert_eq('excluded events', (SELECT COUNT(*) FROM event_validation WHERE status <> 'paired'), 5);

-- Each invalid s3 event gets its explicit reason.
SELECT assert_text('301 start then start', (SELECT status FROM event_validation WHERE event_id = 301), 'start_followed_by_start');
SELECT assert_text('302 start after start', (SELECT status FROM event_validation WHERE event_id = 302), 'start_preceded_by_start');
SELECT assert_text('303 stop of ambiguous start', (SELECT status FROM event_validation WHERE event_id = 303), 'stop_after_ambiguous_start');
SELECT assert_text('304 orphan stop', (SELECT status FROM event_validation WHERE event_id = 304), 'stop_without_start');
SELECT assert_text('307 incomplete session', (SELECT status FROM event_validation WHERE event_id = 307), 'open_start');
SELECT assert_text('305 valid start', (SELECT status FROM event_validation WHERE event_id = 305), 'paired');

-- Sessions: s1 3, s2 2, s3 1, s5-s8 1 each = 10.
SELECT assert_eq('sessions total', (SELECT COUNT(*) FROM server_sessions), 10);
SELECT assert_eq('s1 has several sessions', (SELECT COUNT(*) FROM server_sessions WHERE server_id = 1), 3);
SELECT assert_eq('s3 keeps only the clean pair', (SELECT COUNT(*) FROM server_sessions WHERE server_id = 3), 1);
SELECT assert_true('s3 pair is 305 -> 306',
    EXISTS (SELECT 1 FROM server_sessions WHERE start_event_id = 305 AND stop_event_id = 306));
SELECT assert_true('no session uses an excluded event',
    NOT EXISTS (SELECT 1 FROM server_sessions s
                JOIN event_validation v ON v.event_id IN (s.start_event_id, s.stop_event_id)
                WHERE v.status <> 'paired'));

-- The start before the period (2024-12-31) is kept to rebuild the session.
SELECT assert_true('session starting before the period is reconstructed',
    EXISTS (SELECT 1 FROM server_sessions
            WHERE server_id = 2 AND session_start = '2024-12-31 20:00+00'));
