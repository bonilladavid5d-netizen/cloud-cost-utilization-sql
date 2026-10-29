-- Cost model, tariff validity, conservation and no join duplication.
-- Expected: Alpha Jan 144, Feb 7.5, Mar 58 (209.5); Beta Jan 3, Mar 60 (63)
-- Total priced cost 272.5 USD (24 unpriced hours of s8 excluded).

SELECT assert_eq('s1 January cost',
    (SELECT SUM(cost_usd) FROM v_hourly_cost WHERE server_id = 1 AND hour_start < '2025-02-01'), 12);
SELECT assert_eq('s1 February cost across tariff change',
    (SELECT SUM(cost_usd) FROM v_hourly_cost
     WHERE server_id = 1 AND hour_start >= '2025-02-01' AND hour_start < '2025-03-01'), 5.5);
SELECT assert_eq('hour after change uses new tariff',
    (SELECT pricing_id FROM v_hourly_cost WHERE server_id = 1 AND hour_start = '2025-02-15 00:00+00'), 2);
SELECT assert_eq('hour before change uses old tariff',
    (SELECT pricing_id FROM v_hourly_cost WHERE server_id = 1 AND hour_start = '2025-02-14 23:00+00'), 1);

-- No duplication: the pricing join returns exactly one row per hour.
SELECT assert_eq('v_hourly_cost rows = server_hours rows',
    (SELECT COUNT(*) FROM v_hourly_cost), (SELECT COUNT(*) FROM server_hours));
SELECT assert_eq('total priced cost', (SELECT SUM(cost_usd) FROM v_hourly_cost), 272.5);

-- Analysis 2 breakdowns conserve the total.
SELECT assert_eq('a2 total', (SELECT SUM(compute_cost_usd) FROM a2_cost_by_department_region_environment), 272.5);
SELECT assert_eq('a2 Alpha / us-test / development / January',
    (SELECT compute_cost_usd FROM a2_cost_by_department_region_environment
     WHERE department_name = 'Alpha' AND region = 'us-test' AND environment = 'development' AND month = '2025-01-01'), 12);
SELECT assert_eq('a2 Alpha / eu-test / production / January',
    (SELECT compute_cost_usd FROM a2_cost_by_department_region_environment
     WHERE department_name = 'Alpha' AND region = 'eu-test' AND environment = 'production' AND month = '2025-01-01'), 132);
SELECT assert_eq('a2 January total',
    (SELECT SUM(compute_cost_usd) FROM a2_cost_by_department_region_environment WHERE month = '2025-01-01'), 147);
SELECT assert_eq('a2 February total',
    (SELECT SUM(compute_cost_usd) FROM a2_cost_by_department_region_environment WHERE month = '2025-02-01'), 7.5);
SELECT assert_eq('a2 March total',
    (SELECT SUM(compute_cost_usd) FROM a2_cost_by_department_region_environment WHERE month = '2025-03-01'), 118);
SELECT assert_eq('a2 Alpha total',
    (SELECT SUM(compute_cost_usd) FROM a2_cost_by_department_region_environment WHERE department_name = 'Alpha'), 209.5);
SELECT assert_eq('a2 Beta total',
    (SELECT SUM(compute_cost_usd) FROM a2_cost_by_department_region_environment WHERE department_name = 'Beta'), 63);

-- Joining metrics (analysis 4) must not multiply cost.
SELECT assert_eq('a4 one row per server', (SELECT COUNT(*) FROM a4_low_utilization), 8);
SELECT assert_eq('a4 cost total after metrics join', (SELECT SUM(compute_cost_usd) FROM a4_low_utilization), 272.5);
