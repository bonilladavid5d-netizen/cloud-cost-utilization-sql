-- Analysis 6: off-hours shutdown scenario.
-- Eligible (development, not critical): s1, s3, s4, s5, s7, s8.
-- Eligible cost 17.5 + 3 + 0 + 30 + 20 + 4 = 74.5; savings 7.5 + 0 + 0 + 3 + 0 + 4 = 14.5.

SELECT assert_eq('eligible servers', (SELECT COUNT(*) FROM a6_offhours_savings_by_server), 6);
SELECT assert_true('production servers excluded',
    NOT EXISTS (SELECT 1 FROM a6_offhours_savings_by_server WHERE server_id IN (2, 6)));
SELECT assert_eq('s1 savings', (SELECT potential_savings_usd FROM a6_offhours_savings_by_server WHERE server_id = 1), 7.5);
SELECT assert_eq('s1 shutdown-window hours', (SELECT shutdown_window_hours FROM a6_offhours_savings_by_server WHERE server_id = 1), 6);
SELECT assert_eq('s5 savings (06:00-07:00)', (SELECT potential_savings_usd FROM a6_offhours_savings_by_server WHERE server_id = 5), 3);
SELECT assert_eq('s7 savings inside workday = 0', (SELECT potential_savings_usd FROM a6_offhours_savings_by_server WHERE server_id = 7), 0);
SELECT assert_eq('s8 savings only on priced hours', (SELECT potential_savings_usd FROM a6_offhours_savings_by_server WHERE server_id = 8), 4);
SELECT assert_eq('s8 shutdown-window hours incl. unpriced', (SELECT shutdown_window_hours FROM a6_offhours_savings_by_server WHERE server_id = 8), 28);
SELECT assert_eq('s4 idle server listed with 0', (SELECT eligible_cost_usd FROM a6_offhours_savings_by_server WHERE server_id = 4), 0);

SELECT assert_eq('total eligible cost', (SELECT eligible_cost_usd FROM a6_offhours_savings_summary WHERE department_name = 'ALL'), 74.5);
SELECT assert_eq('total potential savings', (SELECT potential_savings_usd FROM a6_offhours_savings_summary WHERE department_name = 'ALL'), 14.5);
SELECT assert_eq('Alpha savings', (SELECT potential_savings_usd FROM a6_offhours_savings_summary WHERE department_name = 'Alpha'), 11.5);
SELECT assert_eq('Beta eligible cost', (SELECT eligible_cost_usd FROM a6_offhours_savings_summary WHERE department_name = 'Beta'), 33);
SELECT assert_true('savings between 0 and eligible cost for every server',
    (SELECT bool_and(potential_savings_usd BETWEEN 0 AND eligible_cost_usd) FROM a6_offhours_savings_by_server));
