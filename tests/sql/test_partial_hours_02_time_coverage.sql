-- fixture_partial_hours.sql, s12 and s13: coverage by running time,
-- not by number of samples. The first assertion fails on the old
-- bin-count logic (which gives 8 / 10 = 0.80).

SELECT assert_eq('s12 coverage is 8 s / 7,208 s, not 8 / 10 bins',
    (SELECT ROUND(metric_coverage, 10) FROM a4_low_utilization WHERE server_id = 12),
    ROUND(8::NUMERIC / 7208, 10));
SELECT assert_text('s12 insufficient data',
    (SELECT utilization_class FROM a4_low_utilization WHERE server_id = 12), 'insufficient_data');
SELECT assert_eq('s12 observed seconds', (SELECT observed_seconds FROM a4_low_utilization WHERE server_id = 12), 8);
SELECT assert_eq('s12 running seconds', (SELECT running_seconds FROM a4_low_utilization WHERE server_id = 12), 7208);
SELECT assert_eq('s12 observed / active bins',
    (SELECT observed_hour_bins * 100 + active_hour_bins FROM a4_low_utilization WHERE server_id = 12), 810);

-- s13 meets the 4 h minimum exactly, so only coverage (2/3) rejects it.
SELECT assert_eq('s13 coverage 14,400 / 21,600',
    (SELECT ROUND(metric_coverage, 10) FROM a4_low_utilization WHERE server_id = 13), ROUND(2::NUMERIC / 3, 10));
SELECT assert_eq('s13 observed running hours meet the minimum',
    (SELECT observed_running_hours FROM a4_low_utilization WHERE server_id = 13), 4);
SELECT assert_text('s13 insufficient data because of coverage',
    (SELECT utilization_class FROM a4_low_utilization WHERE server_id = 13), 'insufficient_data');
