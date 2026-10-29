-- Hourly split, period clipping and analysis 1 (fixture_core.sql).

-- Running hours: s1 16, s2 56, s3 3, s5 10, s6 10, s7 10, s8 28 = 133 h
-- in 17 + 56 + 3 + 10 + 10 + 10 + 28 = 134 clock-hour rows.
SELECT assert_eq('total running hours', (SELECT SUM(seconds_on) / 3600 FROM server_hours), 133);
SELECT assert_eq('server_hours rows', (SELECT COUNT(*) FROM server_hours), 134);
SELECT assert_eq('partial hour before tariff change',
    (SELECT seconds_on FROM server_hours WHERE server_id = 1 AND hour_start = '2025-02-14 23:00+00'), 1800);

-- Analysis 1: complete grid of 8 servers x 3 months.
SELECT assert_eq('a1 rows', (SELECT COUNT(*) FROM a1_uptime_by_server_month), 24);
SELECT assert_eq('s1 January (month-end split)',
    (SELECT uptime_hours FROM a1_uptime_by_server_month WHERE server_id = 1 AND month = '2025-01-01'), 12);
SELECT assert_eq('s1 February',
    (SELECT uptime_hours FROM a1_uptime_by_server_month WHERE server_id = 1 AND month = '2025-02-01'), 4);
SELECT assert_eq('s1 March is zero, not missing',
    (SELECT uptime_hours FROM a1_uptime_by_server_month WHERE server_id = 1 AND month = '2025-03-01'), 0);
SELECT assert_eq('s2 January clipped at period start',
    (SELECT uptime_hours FROM a1_uptime_by_server_month WHERE server_id = 2 AND month = '2025-01-01'), 44);
SELECT assert_eq('s2 March clipped at period end',
    (SELECT uptime_hours FROM a1_uptime_by_server_month WHERE server_id = 2 AND month = '2025-03-01'), 12);
SELECT assert_eq('s8 March (crosses month and pricing gap)',
    (SELECT uptime_hours FROM a1_uptime_by_server_month WHERE server_id = 8 AND month = '2025-03-01'), 26);
SELECT assert_eq('server without activity keeps 3 zero rows',
    (SELECT COUNT(*) FROM a1_uptime_by_server_month WHERE server_id = 4 AND uptime_hours = 0), 3);
SELECT assert_eq('a1 total equals running hours',
    (SELECT SUM(uptime_hours) FROM a1_uptime_by_server_month), 133);
