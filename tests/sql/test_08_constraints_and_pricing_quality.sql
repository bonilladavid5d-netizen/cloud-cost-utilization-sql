-- Invalid inputs are rejected by constraints; pricing gaps are detected.
-- Every rejected statement runs in a rolled-back subtransaction.

SELECT assert_rejected('exact duplicate event',
    $$INSERT INTO server_events VALUES (999, 1, '2025-01-10 08:00', 'start')$$, '23505');
SELECT assert_rejected('start and stop at the same instant',
    $$INSERT INTO server_events VALUES (999, 1, '2025-01-10 08:00', 'stop')$$, '23505');
SELECT assert_rejected('unknown event type',
    $$INSERT INTO server_events VALUES (999, 1, '2025-01-11 08:00', 'reboot')$$, '23514');
SELECT assert_rejected('event for unknown server',
    $$INSERT INTO server_events VALUES (999, 99, '2025-01-11 08:00', 'start')$$, '23503');
SELECT assert_rejected('overlapping tariff',
    $$INSERT INTO pricing VALUES (99, 't.small', 'us-test', '2025-02-01', '2025-03-01', 5)$$, '23P01');
SELECT assert_rejected('tariff not starting at 00:00 UTC',
    $$INSERT INTO pricing VALUES (99, 't.new', 'us-test', '2025-02-01 06:00', '2025-03-01', 5)$$, '23514');
SELECT assert_rejected('negative budget',
    $$INSERT INTO budgets VALUES (4, '2025-02-01', -1)$$, '23514');
SELECT assert_rejected('budget month not on day 1',
    $$INSERT INTO budgets VALUES (4, '2025-02-15', 10)$$, '23514');
SELECT assert_rejected('metric not aligned to the hour',
    $$INSERT INTO server_metrics VALUES (1, '2025-01-10 08:30', 5, 5)$$, '23514');
SELECT assert_rejected('CPU above 100 %',
    $$INSERT INTO server_metrics VALUES (1, '2025-01-10 09:00', 120, 5)$$, '23514');

-- Nothing was left behind by the rejected statements.
SELECT assert_eq('events unchanged', (SELECT COUNT(*) FROM server_events), 25);
SELECT assert_eq('pricing unchanged', (SELECT COUNT(*) FROM pricing), 5);

-- Pricing gap: t.gap/us-test has no tariff on 2025-03-01.
SELECT assert_eq('one pricing gap', (SELECT COUNT(*) FROM dq_pricing_gaps), 1);
SELECT assert_true('gap is exactly [2025-03-01, 2025-03-02)',
    (SELECT instance_type = 't.gap' AND gap_start = '2025-03-01 00:00+00' AND gap_end = '2025-03-02 00:00+00'
     FROM dq_pricing_gaps));
SELECT assert_eq('24 unpriced running hours on s8',
    (SELECT unpriced_hours FROM dq_unpriced_hours WHERE server_id = 8), 24);
SELECT assert_eq('no other server has unpriced hours', (SELECT COUNT(*) FROM dq_unpriced_hours), 1);
SELECT assert_eq('servers without events', (SELECT value FROM dq_summary WHERE check_name = 'servers_without_events'), 1);
SELECT assert_eq('excluded events in summary', (SELECT value FROM dq_summary WHERE check_name = 'events_excluded'), 5);
