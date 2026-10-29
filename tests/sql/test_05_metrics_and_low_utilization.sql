-- Analysis 4: missing metrics, coverage, classification (fixture_core.sql).

SELECT assert_eq('s5 coverage 8 of 10 hours',
    (SELECT metric_coverage FROM a4_low_utilization WHERE server_id = 5), 0.8);
SELECT assert_eq('s5 average CPU ignores missing hours (5, not 4)',
    (SELECT cpu_avg_pct FROM a4_low_utilization WHERE server_id = 5), 5);
SELECT assert_eq('s5 p95 CPU', (SELECT cpu_p95_pct FROM a4_low_utilization WHERE server_id = 5), 6);
SELECT assert_text('s5 low utilization',
    (SELECT utilization_class FROM a4_low_utilization WHERE server_id = 5), 'low_utilization');

SELECT assert_eq('s6 sample taken while off is ignored',
    (SELECT cpu_avg_pct FROM a4_low_utilization WHERE server_id = 6), 60);
SELECT assert_text('s6 normal', (SELECT utilization_class FROM a4_low_utilization WHERE server_id = 6), 'normal');
SELECT assert_text('s7 insufficient data (3 observed hours)',
    (SELECT utilization_class FROM a4_low_utilization WHERE server_id = 7), 'insufficient_data');
SELECT assert_eq('s1 coverage 0 without metrics',
    (SELECT metric_coverage FROM a4_low_utilization WHERE server_id = 1), 0);
SELECT assert_text('s1 insufficient data',
    (SELECT utilization_class FROM a4_low_utilization WHERE server_id = 1), 'insufficient_data');
SELECT assert_text('s4 no activity', (SELECT utilization_class FROM a4_low_utilization WHERE server_id = 4), 'no_activity');

SELECT assert_eq('metrics outside reconstructed uptime',
    (SELECT value FROM dq_summary WHERE check_name = 'metrics_outside_reconstructed_uptime'), 1);
SELECT assert_eq('running hours without metrics (134 - 21)',
    (SELECT value FROM dq_summary WHERE check_name = 'running_hours_without_metrics'), 113);
