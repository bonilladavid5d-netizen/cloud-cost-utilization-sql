-- Analysis 3: spend vs budget, areas without consumption, zero vs missing budget.

SELECT assert_eq('a3 complete grid 4 departments x 3 months', (SELECT COUNT(*) FROM a3_budget_vs_actual), 12);
SELECT assert_eq('a3 spend total', (SELECT SUM(actual_usd) FROM a3_budget_vs_actual), 272.5);

SELECT assert_eq('Alpha Jan variance USD',
    (SELECT variance_usd FROM a3_budget_vs_actual WHERE department_name = 'Alpha' AND month = '2025-01-01'), 44);
SELECT assert_eq('Alpha Jan variance %',
    (SELECT variance_pct FROM a3_budget_vs_actual WHERE department_name = 'Alpha' AND month = '2025-01-01'), 44);
SELECT assert_eq('Alpha Feb variance %',
    (SELECT variance_pct FROM a3_budget_vs_actual WHERE department_name = 'Alpha' AND month = '2025-02-01'), -92.5);
SELECT assert_eq('Beta Feb has no spend but keeps its row',
    (SELECT variance_pct FROM a3_budget_vs_actual WHERE department_name = 'Beta' AND month = '2025-02-01'), -100);
SELECT assert_eq('Beta Mar over budget',
    (SELECT variance_pct FROM a3_budget_vs_actual WHERE department_name = 'Beta' AND month = '2025-03-01'), 20);

-- Area with budget and no servers.
SELECT assert_eq('Gamma rows kept', (SELECT COUNT(*) FROM a3_budget_vs_actual WHERE department_name = 'Gamma'), 3);
SELECT assert_eq('Gamma spend is 0',
    (SELECT SUM(actual_usd) FROM a3_budget_vs_actual WHERE department_name = 'Gamma'), 0);
SELECT assert_true('Gamma flagged as owning no servers',
    (SELECT bool_and(has_no_servers) FROM a3_budget_vs_actual WHERE department_name = 'Gamma'));
SELECT assert_true('Delta owns an idle server',
    (SELECT NOT bool_or(has_no_servers) FROM a3_budget_vs_actual WHERE department_name = 'Delta'));

-- Zero budget versus missing budget.
SELECT assert_text('Delta Jan zero budget',
    (SELECT budget_status FROM a3_budget_vs_actual WHERE department_name = 'Delta' AND month = '2025-01-01'), 'zero_budget');
SELECT assert_eq('Delta Jan variance USD is 0',
    (SELECT variance_usd FROM a3_budget_vs_actual WHERE department_name = 'Delta' AND month = '2025-01-01'), 0);
SELECT assert_true('Delta Jan variance % undefined',
    (SELECT variance_pct IS NULL FROM a3_budget_vs_actual WHERE department_name = 'Delta' AND month = '2025-01-01'));
SELECT assert_text('Delta Feb no budget',
    (SELECT budget_status FROM a3_budget_vs_actual WHERE department_name = 'Delta' AND month = '2025-02-01'), 'no_budget');
SELECT assert_true('Delta Feb budget and variance are NULL',
    (SELECT budget_usd IS NULL AND variance_usd IS NULL AND variance_pct IS NULL
     FROM a3_budget_vs_actual WHERE department_name = 'Delta' AND month = '2025-02-01'));
