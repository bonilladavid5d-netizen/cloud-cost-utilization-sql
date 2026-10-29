-- =====================================================================
-- fixture_partial_hours.sql
-- Isolated fixture (own test database) for analysis 4 units: hour bins
-- that hold only part of an hour of running time. Expected values are
-- computed by hand below. All servers report CPU 2 % and memory 10 %,
-- so whenever the data is sufficient the class is low_utilization.
--
-- Configured minimum for this fixture: 4 observed running hours
-- (14,400 s); minimum coverage stays at the default 0.80.
-- =====================================================================

SET timezone = 'UTC';

UPDATE analysis_config SET low_min_observed_hours = 4;

INSERT INTO departments VALUES (1, 'Partial', 'CC-0101');

INSERT INTO servers VALUES
    (11, 'p-many-short-bins',   1, 'us-test', 't.small', 'development', FALSE),
    (12, 'p-coverage-1s-bins',  1, 'us-test', 't.small', 'development', FALSE),
    (13, 'p-coverage-half-bins', 1, 'us-test', 't.small', 'development', FALSE),
    (14, 'p-minimum-exact',     1, 'us-test', 't.small', 'development', FALSE),
    (15, 'p-minimum-below',     1, 'us-test', 't.small', 'development', FALSE);

INSERT INTO pricing VALUES
    (1, 't.small', 'us-test', '2024-12-01', '2025-05-01', 1.0000);

-- s11: 10 sessions of 6 minutes (08:00-08:06 ... 17:00-17:06), all observed.
--      10 observed bins (above the minimum of 4 as a count) but only
--      10 x 360 s = 3,600 s = 1 observed running hour -> insufficient_data.
INSERT INTO server_events
SELECT 1100 + 2 * h,     11, TIMESTAMPTZ '2025-01-06 00:00+00' + make_interval(hours => h),             'start'
FROM generate_series(8, 17) AS h
UNION ALL
SELECT 1100 + 2 * h + 1, 11, TIMESTAMPTZ '2025-01-06 00:00+00' + make_interval(hours => h, mins => 6),  'stop'
FROM generate_series(8, 17) AS h;
INSERT INTO server_metrics
SELECT 11, TIMESTAMPTZ '2025-01-06 00:00+00' + make_interval(hours => h), 2, 10
FROM generate_series(8, 17) AS h;

-- s12: 8 sessions of 1 second (08:00:00-08:00:01 ... 15:00:00-15:00:01),
--      all observed, plus 18:00-20:00 (2 full bins) without metrics.
--      Count coverage 8 / 10 = 0.80; time coverage 8 / 7,208 s -> insufficient_data.
INSERT INTO server_events
SELECT 1200 + 2 * h,     12, TIMESTAMPTZ '2025-01-07 00:00+00' + make_interval(hours => h),            'start'
FROM generate_series(8, 15) AS h
UNION ALL
SELECT 1200 + 2 * h + 1, 12, TIMESTAMPTZ '2025-01-07 00:00+00' + make_interval(hours => h, secs => 1), 'stop'
FROM generate_series(8, 15) AS h
UNION ALL
SELECT 1298, 12, '2025-01-07 18:00+00', 'start'
UNION ALL
SELECT 1299, 12, '2025-01-07 20:00+00', 'stop';
INSERT INTO server_metrics
SELECT 12, TIMESTAMPTZ '2025-01-07 00:00+00' + make_interval(hours => h), 2, 10
FROM generate_series(8, 15) AS h;

-- s13: 8 sessions of 30 minutes (08:00-08:30 ... 15:00-15:30), all
--      observed = 14,400 s = exactly 4 h (meets the minimum), plus
--      18:00-20:00 without metrics. Count coverage 8 / 10 = 0.80;
--      time coverage 14,400 / 21,600 = 2/3 < 0.80 -> insufficient_data
--      because of coverage alone.
INSERT INTO server_events
SELECT 1300 + 2 * h,     13, TIMESTAMPTZ '2025-01-08 00:00+00' + make_interval(hours => h),             'start'
FROM generate_series(8, 15) AS h
UNION ALL
SELECT 1300 + 2 * h + 1, 13, TIMESTAMPTZ '2025-01-08 00:00+00' + make_interval(hours => h, mins => 30), 'stop'
FROM generate_series(8, 15) AS h
UNION ALL
SELECT 1398, 13, '2025-01-08 18:00+00', 'start'
UNION ALL
SELECT 1399, 13, '2025-01-08 20:00+00', 'stop';
INSERT INTO server_metrics
SELECT 13, TIMESTAMPTZ '2025-01-08 00:00+00' + make_interval(hours => h), 2, 10
FROM generate_series(8, 15) AS h;

-- s14: 10:00:00-14:00:00, 4 observed bins = 14,400 s, exactly the minimum
--      -> low_utilization.
-- s15: 10:00:00-13:59:59, 4 observed bins = 14,399 s, one second below
--      -> insufficient_data (a bin count of 4 would wrongly pass).
INSERT INTO server_events VALUES
    (1401, 14, '2025-01-09 10:00:00+00', 'start'), (1402, 14, '2025-01-09 14:00:00+00', 'stop'),
    (1501, 15, '2025-01-10 10:00:00+00', 'start'), (1502, 15, '2025-01-10 13:59:59+00', 'stop');
INSERT INTO server_metrics
SELECT s, d + make_interval(hours => h), 2, 10
FROM (VALUES (14, TIMESTAMPTZ '2025-01-09 00:00+00'), (15, TIMESTAMPTZ '2025-01-10 00:00+00')) AS v(s, d)
CROSS JOIN generate_series(10, 13) AS h;
