-- Analysis 5: monthly evolution, ranking and concentration.

SELECT assert_eq('a5 grid 4 departments x 3 months', (SELECT COUNT(*) FROM a5_spend_trend_concentration), 12);
SELECT assert_eq('a5 total', (SELECT SUM(cost_usd) FROM a5_spend_trend_concentration), 272.5);
SELECT assert_eq('Beta February kept with 0',
    (SELECT cost_usd FROM a5_spend_trend_concentration WHERE department_name = 'Beta' AND month = '2025-02-01'), 0);
SELECT assert_eq('Alpha March change USD (58 - 7.5)',
    (SELECT mom_change_usd FROM a5_spend_trend_concentration WHERE department_name = 'Alpha' AND month = '2025-03-01'), 50.5);
SELECT assert_eq('Alpha March change % (50.5 / 7.5)',
    (SELECT ROUND(mom_change_pct, 4) FROM a5_spend_trend_concentration
     WHERE department_name = 'Alpha' AND month = '2025-03-01'), 673.3333);
SELECT assert_eq('Beta February change % (3 -> 0)',
    (SELECT mom_change_pct FROM a5_spend_trend_concentration WHERE department_name = 'Beta' AND month = '2025-02-01'), -100);
SELECT assert_true('Beta March change % undefined after a zero month',
    (SELECT mom_change_pct IS NULL FROM a5_spend_trend_concentration
     WHERE department_name = 'Beta' AND month = '2025-03-01'));
SELECT assert_true('first month has no previous month',
    (SELECT bool_and(prev_month_cost_usd IS NULL) FROM a5_spend_trend_concentration WHERE month = '2025-01-01'));

SELECT assert_eq('Alpha ranks first in January',
    (SELECT rank_in_month FROM a5_spend_trend_concentration WHERE department_name = 'Alpha' AND month = '2025-01-01'), 1);
SELECT assert_eq('tied zero departments share rank 3',
    (SELECT COUNT(*) FROM a5_spend_trend_concentration WHERE month = '2025-01-01' AND rank_in_month = 3), 2);
SELECT assert_eq('Alpha January share (144 / 147)',
    (SELECT ROUND(share_of_month, 6) FROM a5_spend_trend_concentration
     WHERE department_name = 'Alpha' AND month = '2025-01-01'), 0.979592);
SELECT assert_eq('January cumulative share reaches 1',
    (SELECT ROUND(MAX(cumulative_share_of_month), 10) FROM a5_spend_trend_concentration WHERE month = '2025-01-01'), 1);
SELECT assert_true('February month with a single spender is 100 %',
    (SELECT share_of_month = 1 FROM a5_spend_trend_concentration WHERE department_name = 'Alpha' AND month = '2025-02-01'));
