-- =====================================================================
-- Analysis 3 - Spend versus budget per department and month
--
-- Starts from every department x month (calendar), then LEFT JOINs the
-- budget and the spend, so areas without consumption and months without
-- budget are kept. Spend is aggregated to department x month BEFORE the
-- join, so the budget amount is never repeated per server-hour.
--
--   budget_status = 'no_budget'   no budget row     -> variance is NULL
--                 = 'zero_budget' budget row of 0   -> variance in USD,
--                                                      percentage NULL
--                 = 'budgeted'    budget > 0        -> both variances
-- Positive variance = spend above budget.
-- Grain: department x month.
-- =====================================================================

SET timezone = 'UTC';

CREATE OR REPLACE VIEW a3_budget_vs_actual AS
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
        SUM(cost_usd)                   AS actual_usd
    FROM v_hourly_cost
    GROUP BY department_id, date_trunc('month', hour_start)
)
SELECT
    d.department_name,
    d.cost_center,
    m.month_start::DATE                AS month,
    b.amount_usd                       AS budget_usd,
    COALESCE(sp.actual_usd, 0)         AS actual_usd,
    CASE
        WHEN b.department_id IS NULL THEN 'no_budget'
        WHEN b.amount_usd = 0        THEN 'zero_budget'
        ELSE 'budgeted'
    END                                AS budget_status,
    COALESCE(sp.actual_usd, 0) - b.amount_usd AS variance_usd,
    CASE WHEN b.amount_usd > 0
         THEN (COALESCE(sp.actual_usd, 0) - b.amount_usd) / b.amount_usd * 100
    END                                AS variance_pct,
    -- Distinguishes "no spend because the area owns no servers" from
    -- "servers exist but did not run".
    NOT EXISTS (
        SELECT 1 FROM servers s WHERE s.department_id = d.department_id
    )                                  AS has_no_servers
FROM departments d
CROSS JOIN months m
LEFT JOIN budgets b
  ON  b.department_id = d.department_id
  AND b.budget_month  = m.month_start::DATE
LEFT JOIN monthly_spend sp
  ON  sp.department_id = d.department_id
  AND sp.month_start   = m.month_start;
