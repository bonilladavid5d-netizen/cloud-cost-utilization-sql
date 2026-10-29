-- fixture_partial_hours.sql, s11: many observed bins, little running time.
-- The first assertion uses only columns that also existed before the
-- unit correction, so it fails on the old bin-count logic.

SELECT assert_text('s11: 10 observed bins of 6 min do not meet a 4 h minimum',
    (SELECT utilization_class FROM a4_low_utilization WHERE server_id = 11), 'insufficient_data');

SELECT assert_eq('s11 observed hour bins', (SELECT observed_hour_bins FROM a4_low_utilization WHERE server_id = 11), 10);
SELECT assert_eq('s11 active hour bins', (SELECT active_hour_bins FROM a4_low_utilization WHERE server_id = 11), 10);
SELECT assert_eq('s11 observed seconds', (SELECT observed_seconds FROM a4_low_utilization WHERE server_id = 11), 3600);
SELECT assert_eq('s11 observed running hours', (SELECT observed_running_hours FROM a4_low_utilization WHERE server_id = 11), 1);
SELECT assert_eq('s11 coverage (all running time observed)', (SELECT metric_coverage FROM a4_low_utilization WHERE server_id = 11), 1);
