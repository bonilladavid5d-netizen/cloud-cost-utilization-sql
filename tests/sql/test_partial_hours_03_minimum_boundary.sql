-- fixture_partial_hours.sql, s14 and s15: exact minimum and one second below.
-- Minimum configured for this fixture: 4 h = 14,400 s.

SELECT assert_text('s14 exactly 14,400 observed seconds meets the minimum',
    (SELECT utilization_class FROM a4_low_utilization WHERE server_id = 14), 'low_utilization');
SELECT assert_text('s15 14,399 observed seconds is below the minimum',
    (SELECT utilization_class FROM a4_low_utilization WHERE server_id = 15), 'insufficient_data');

SELECT assert_eq('s14 observed seconds', (SELECT observed_seconds FROM a4_low_utilization WHERE server_id = 14), 14400);
SELECT assert_eq('s15 observed seconds', (SELECT observed_seconds FROM a4_low_utilization WHERE server_id = 15), 14399);
SELECT assert_eq('both use 4 observed bins',
    (SELECT COUNT(*) FROM a4_low_utilization WHERE server_id IN (14, 15) AND observed_hour_bins = 4), 2);
SELECT assert_eq('s15 coverage is still complete', (SELECT metric_coverage FROM a4_low_utilization WHERE server_id = 15), 1);
