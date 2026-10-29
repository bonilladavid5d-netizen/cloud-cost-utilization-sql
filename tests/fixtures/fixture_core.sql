-- =====================================================================
-- fixture_core.sql
-- Small hand-built dataset with known answers. Expected values in the
-- tests were computed by hand from the comments below, independently
-- of the SQL under test. Loaded only into the dedicated test database.
--
-- Rates: t.small/us-test  1.00 USD/h until 2025-02-15, 2.00 USD/h after
--        t.large/eu-test  3.00 USD/h
--        t.gap/us-test    1.00 USD/h, NO tariff on 2025-03-01 (gap)
-- Calendar: 2025-01-01 is a Wednesday. Shutdown window = weekends and
--           weekdays outside [07:00, 20:00) UTC.
-- =====================================================================

SET timezone = 'UTC';

-- Low-utilization minimum observed hours lowered for a tiny fixture.
UPDATE analysis_config SET low_min_observed_hours = 6;

INSERT INTO departments VALUES
    (1, 'Alpha', 'CC-0001'),
    (2, 'Beta',  'CC-0002'),
    (3, 'Gamma', 'CC-0003'),   -- budget, no servers
    (4, 'Delta', 'CC-0004');   -- one server that never runs

INSERT INTO servers VALUES
    (1, 's1', 1, 'us-test', 't.small', 'development', FALSE),
    (2, 's2', 1, 'eu-test', 't.large', 'production',  TRUE),
    (3, 's3', 2, 'us-test', 't.small', 'development', FALSE),
    (4, 's4', 4, 'us-test', 't.small', 'development', FALSE),
    (5, 's5', 2, 'eu-test', 't.large', 'development', FALSE),
    (6, 's6', 2, 'eu-test', 't.large', 'production',  FALSE),
    (7, 's7', 1, 'us-test', 't.small', 'development', FALSE),
    (8, 's8', 1, 'us-test', 't.gap',   'development', FALSE);

INSERT INTO pricing VALUES
    (1, 't.small', 'us-test', '2024-12-01', '2025-02-15', 1.0000),
    (2, 't.small', 'us-test', '2025-02-15', '2025-05-01', 2.0000),
    (3, 't.large', 'eu-test', '2024-12-01', '2025-05-01', 3.0000),
    (4, 't.gap',   'us-test', '2024-12-01', '2025-03-01', 1.0000),
    (5, 't.gap',   'us-test', '2025-03-02', '2025-05-01', 1.0000);

INSERT INTO server_events VALUES
    -- s1: three valid sessions
    --   Jan 10 (Fri) 08:00-18:00  10 h x 1 = 10.0   all inside workday
    --   Jan 31 (Fri) 22:00 -> Feb 1 (Sat) 02:00   crosses month end
    --        Jan 2 h + Feb 2 h, x 1 = 4.0           all in shutdown window
    --   Feb 14 (Fri) 23:30 -> Feb 15 (Sat) 01:30  crosses tariff change
    --        0.5 h x 1 + 1.5 h x 2 = 3.5            all in shutdown window
    --   s1: Jan 12 h / 12.0 USD, Feb 4 h / 5.5 USD, savings 7.5 USD (6 h)
    (101, 1, '2025-01-10 08:00', 'start'), (102, 1, '2025-01-10 18:00', 'stop'),
    (103, 1, '2025-01-31 22:00', 'start'), (104, 1, '2025-02-01 02:00', 'stop'),
    (105, 1, '2025-02-14 23:30', 'start'), (106, 1, '2025-02-15 01:30', 'stop'),
    -- s2: sessions crossing both period boundaries (production)
    --   Dec 31 20:00 -> Jan 2 20:00: 44 h inside the period = 132 USD
    --   Mar 31 12:00 -> Apr 1 12:00: 12 h inside the period =  36 USD
    (201, 2, '2024-12-31 20:00', 'start'), (202, 2, '2025-01-02 20:00', 'stop'),
    (203, 2, '2025-03-31 12:00', 'start'), (204, 2, '2025-04-01 12:00', 'stop'),
    -- s3: invalid sequences + one valid session
    --   301 start, 302 start, 303 stop -> all three excluded
    --   304 stop after a stop          -> excluded (stop_without_start)
    --   305/306 Jan 7 (Tue) 09:00-12:00 -> 3 h = 3 USD, no shutdown hours
    --   307 start with no later event  -> excluded (open_start)
    (301, 3, '2025-01-05 10:00', 'start'), (302, 3, '2025-01-05 12:00', 'start'),
    (303, 3, '2025-01-05 14:00', 'stop'),  (304, 3, '2025-01-06 10:00', 'stop'),
    (305, 3, '2025-01-07 09:00', 'start'), (306, 3, '2025-01-07 12:00', 'stop'),
    (307, 3, '2025-03-20 10:00', 'start'),
    -- s4: no events at all
    -- s5: Mar 3 (Mon) 06:00-16:00 = 10 h x 3 = 30 USD; 06-07 in window = 3 USD
    (501, 5, '2025-03-03 06:00', 'start'), (502, 5, '2025-03-03 16:00', 'stop'),
    -- s6: Mar 3 00:00-10:00 = 10 h x 3 = 30 USD (production)
    (601, 6, '2025-03-03 00:00', 'start'), (602, 6, '2025-03-03 10:00', 'stop'),
    -- s7: Mar 10 (Mon) 08:00-18:00 = 10 h x 2 = 20 USD
    (701, 7, '2025-03-10 08:00', 'start'), (702, 7, '2025-03-10 18:00', 'stop'),
    -- s8: Feb 28 (Fri) 22:00 -> Mar 2 (Sun) 02:00 = 28 h
    --   Feb 28 22-24 = 2 h x 1, Mar 1 = 24 h WITHOUT tariff, Mar 2 00-02 = 2 h x 1
    --   priced cost 4 USD, all 28 h in shutdown window, savings 4 USD
    (801, 8, '2025-02-28 22:00', 'start'), (802, 8, '2025-03-02 02:00', 'stop');

INSERT INTO server_metrics VALUES
    -- s5: 8 of 10 running hours observed (10:00 and 11:00 missing)
    --   CPU 4,6,4,6,4,6,4,6 -> average 5 (it would be 4 if missing = 0)
    --   p95 (continuous) of {4,4,4,4,6,6,6,6} = 6; memory 20
    (5, '2025-03-03 06:00', 4, 20), (5, '2025-03-03 07:00', 6, 20),
    (5, '2025-03-03 08:00', 4, 20), (5, '2025-03-03 09:00', 6, 20),
    (5, '2025-03-03 12:00', 4, 20), (5, '2025-03-03 13:00', 6, 20),
    (5, '2025-03-03 14:00', 4, 20), (5, '2025-03-03 15:00', 6, 20),
    -- s6: 10 of 10 hours at CPU 60 / memory 70, plus one sample at 12:00
    --   when the server was off (must be ignored and counted)
    (6, '2025-03-03 00:00', 60, 70), (6, '2025-03-03 01:00', 60, 70),
    (6, '2025-03-03 02:00', 60, 70), (6, '2025-03-03 03:00', 60, 70),
    (6, '2025-03-03 04:00', 60, 70), (6, '2025-03-03 05:00', 60, 70),
    (6, '2025-03-03 06:00', 60, 70), (6, '2025-03-03 07:00', 60, 70),
    (6, '2025-03-03 08:00', 60, 70), (6, '2025-03-03 09:00', 60, 70),
    (6, '2025-03-03 12:00', 1, 1),
    -- s7: only 3 of 10 hours observed -> insufficient data
    (7, '2025-03-10 08:00', 2, 10), (7, '2025-03-10 09:00', 2, 10),
    (7, '2025-03-10 10:00', 2, 10);

INSERT INTO budgets VALUES
    (1, '2025-01-01', 100), (1, '2025-02-01', 100), (1, '2025-03-01', 100),
    (2, '2025-01-01',  50), (2, '2025-02-01',  50), (2, '2025-03-01',  50),
    (3, '2025-01-01',  20), (3, '2025-02-01',  20), (3, '2025-03-01',  20),
    (4, '2025-01-01',   0),                         (4, '2025-03-01',  10);
    -- Delta: zero budget in January, no budget row in February
