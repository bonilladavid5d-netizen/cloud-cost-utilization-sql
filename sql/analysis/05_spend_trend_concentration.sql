-- =====================================================================
-- Analysis 5 - Monthly evolution and concentration of spend
--
-- Department x month grid (months without spend show 0), then window
-- functions on top of it:
--   LAG          month-over-month change (percentage NULL when the
--                previous month was 0)
--   RANK         position of the department inside each month
--   SUM OVER     share of the month and cumulative share in rank order
--                (ties broken by department name so the running total
--                is deterministic)
-- Grain: department x month.
-- =====================================================================

SET timezone = 'UTC';

CREATE OR REPLACE VIEW a5_spend_trend_concentration AS
WITH months AS (
    SELECT gs AS month_start
    FROM analysis_config c
    CROSS JOIN LATERAL generate_series(
        c.period_start, c.period_end - INTERVAL '1 month', INTERVAL '1 month') AS gs
),
monthly_spend AS (
    SELECT
        department_id,
        date_trunc('month', hour_start) AS month_start,
        SUM(cost_usd)                   AS cost_usd
    FROM v_hourly_cost
    GROUP BY department_id, date_trunc('month', hour_start)
),
grid AS (
    SELECT
        d.department_id,
        d.department_name,
        m.month_start,
        COALESCE(sp.cost_usd, 0) AS cost_usd
    FROM departments d
    CROSS JOIN months m
    LEFT JOIN monthly_spend sp
      ON  sp.department_id = d.department_id
      AND sp.month_start   = m.month_start
),
with_previous AS (
    SELECT
        g.*,
        LAG(g.cost_usd) OVER (PARTITION BY g.department_id ORDER BY g.month_start)
            AS prev_month_cost_usd
    FROM grid g
)
SELECT
    department_name,
    month_start::DATE                                       AS month,
    cost_usd,
    prev_month_cost_usd,
    cost_usd - prev_month_cost_usd                          AS mom_change_usd,
    CASE WHEN prev_month_cost_usd > 0
         THEN (cost_usd - prev_month_cost_usd) / prev_month_cost_usd * 100
    END                                                     AS mom_change_pct,
    RANK() OVER (PARTITION BY month_start ORDER BY cost_usd DESC) AS rank_in_month,
    cost_usd / NULLIF(SUM(cost_usd) OVER (PARTITION BY month_start), 0)
                                                            AS share_of_month,
    SUM(cost_usd) OVER (
        PARTITION BY month_start
        ORDER BY cost_usd DESC, department_name
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) / NULLIF(SUM(cost_usd) OVER (PARTITION BY month_start), 0)
                                                            AS cumulative_share_of_month
FROM with_previous;
