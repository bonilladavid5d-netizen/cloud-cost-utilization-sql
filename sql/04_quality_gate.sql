-- =====================================================================
-- 04_quality_gate.sql
-- Invariants that must hold for any generated dataset. Each failed
-- check raises an exception, so psql (with ON_ERROR_STOP=1) exits with
-- a non-zero code and the pipeline stops before exporting results.
-- Cost comparisons on NUMERIC are exact; the only tolerance is noted
-- at the a1 hours check.
-- =====================================================================

SET client_min_messages = notice;
SET timezone = 'UTC';

DO $$
DECLARE
    failures      TEXT[] := '{}';
    total_cost    NUMERIC;
    total_seconds NUMERIC;
    n_months      INTEGER;
    v             NUMERIC;
BEGIN
    SELECT SUM(cost_usd), SUM(seconds_on) INTO total_cost, total_seconds FROM v_hourly_cost;
    SELECT COUNT(*) INTO n_months FROM a3_budget_vs_actual WHERE department_name =
        (SELECT department_name FROM departments ORDER BY department_id LIMIT 1);

    -- Pricing must cover every used type/region for the whole period.
    IF (SELECT COUNT(*) FROM dq_pricing_gaps) > 0 THEN
        failures := failures || 'pricing gaps found';
    END IF;
    IF EXISTS (SELECT 1 FROM dq_unpriced_hours) THEN
        failures := failures || 'running hours without tariff';
    END IF;

    -- The pricing join must not add or drop server-hours.
    IF (SELECT COUNT(*) FROM v_hourly_cost) <> (SELECT COUNT(*) FROM server_hours) THEN
        failures := failures || 'v_hourly_cost row count differs from server_hours';
    END IF;

    -- Hourly split conserves the clipped session time.
    SELECT SUM(EXTRACT(EPOCH FROM LEAST(s.session_stop, c.period_end)
                                - GREATEST(s.session_start, c.period_start)))
      INTO v
      FROM server_sessions s CROSS JOIN analysis_config c
     WHERE s.session_start < c.period_end AND s.session_stop > c.period_start;
    IF v IS DISTINCT FROM total_seconds THEN
        failures := failures || format('session seconds %s <> hourly seconds %s', v, total_seconds);
    END IF;

    -- Analysis 1: one row per server and month; total time conserved.
    IF (SELECT COUNT(*) FROM a1_uptime_by_server_month)
       <> (SELECT COUNT(*) FROM servers) * n_months THEN
        failures := failures || 'a1 is not a complete server x month grid';
    END IF;
    -- a1 converts seconds to hours per row (division by 3600 is not
    -- exact in decimal), so this one check compares at 1e-6 hours.
    IF ROUND((SELECT SUM(uptime_hours) FROM a1_uptime_by_server_month), 6)
       IS DISTINCT FROM ROUND(total_seconds / 3600, 6) THEN
        failures := failures || 'a1 total uptime differs from server_hours';
    END IF;

    -- Analyses 2, 3, 4, 5: the total cost is conserved by every breakdown.
    IF (SELECT SUM(compute_cost_usd) FROM a2_cost_by_department_region_environment)
       IS DISTINCT FROM total_cost THEN
        failures := failures || 'a2 total cost differs from v_hourly_cost';
    END IF;
    IF (SELECT SUM(actual_usd) FROM a3_budget_vs_actual) IS DISTINCT FROM total_cost THEN
        failures := failures || 'a3 total spend differs from v_hourly_cost';
    END IF;
    IF (SELECT COUNT(*) FROM a3_budget_vs_actual)
       <> (SELECT COUNT(*) FROM departments) * n_months THEN
        failures := failures || 'a3 is not a complete department x month grid';
    END IF;
    IF (SELECT SUM(compute_cost_usd) FROM a4_low_utilization) IS DISTINCT FROM total_cost
       OR (SELECT COUNT(*) FROM a4_low_utilization) <> (SELECT COUNT(*) FROM servers) THEN
        failures := failures || 'a4 duplicates or drops servers or cost';
    END IF;
    IF (SELECT SUM(cost_usd) FROM a5_spend_trend_concentration) IS DISTINCT FROM total_cost THEN
        failures := failures || 'a5 total spend differs from v_hourly_cost';
    END IF;

    -- Analysis 6: savings bounded by eligible cost; summary = detail.
    IF EXISTS (SELECT 1 FROM a6_offhours_savings_by_server
               WHERE potential_savings_usd < 0
                  OR potential_savings_usd > eligible_cost_usd) THEN
        failures := failures || 'a6 savings outside [0, eligible cost]';
    END IF;
    IF (SELECT potential_savings_usd FROM a6_offhours_savings_summary WHERE department_name = 'ALL')
       IS DISTINCT FROM (SELECT SUM(potential_savings_usd) FROM a6_offhours_savings_by_server) THEN
        failures := failures || 'a6 summary total differs from detail';
    END IF;

    IF cardinality(failures) > 0 THEN
        RAISE EXCEPTION 'Quality gate failed: %', array_to_string(failures, '; ');
    END IF;
    RAISE NOTICE 'Quality gate passed (13 invariants).';
END
$$;
