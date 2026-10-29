-- =====================================================================
-- 03_views.sql
-- Cost model and data-quality views shared by the analyses.
-- =====================================================================

SET client_min_messages = warning;
SET timezone = 'UTC';


-- ---------------------------------------------------------------------
-- v_hourly_cost: billing model at its natural grain (server x hour).
--   cost = seconds_on / 3600 * hourly rate valid at that hour.
--   Only compute time is billed: no storage, transfer, taxes or
--   discounts. Rates change at 00:00 UTC, so one hour has one rate.
--   The exclusion constraint on pricing guarantees at most one match,
--   so this join cannot duplicate hours. Hours without a valid rate keep
--   cost_usd = NULL and are reported by dq_unpriced_hours instead of
--   being priced with a guess.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_hourly_cost AS
SELECT
    h.server_id,
    h.hour_start,
    h.seconds_on,
    s.department_id,
    s.region,
    s.instance_type,
    s.environment,
    s.is_critical,
    p.pricing_id,
    p.hourly_rate_usd,
    h.seconds_on * p.hourly_rate_usd / 3600 AS cost_usd
FROM server_hours h
JOIN servers s
  ON s.server_id = h.server_id
LEFT JOIN pricing p
  ON  p.instance_type = s.instance_type
  AND p.region        = s.region
  AND h.hour_start >= p.valid_from
  AND h.hour_start <  p.valid_to;


-- ---------------------------------------------------------------------
-- dq_event_status: events by pairing status (see 02_transform.sql).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW dq_event_status AS
SELECT
    status,
    event_type,
    COUNT(*)                  AS events,
    COUNT(DISTINCT server_id) AS servers
FROM event_validation
GROUP BY status, event_type;


-- ---------------------------------------------------------------------
-- dq_pricing_gaps: parts of the analysis period without a tariff for a
-- type/region combination that is actually used by some server.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW dq_pricing_gaps AS
WITH used_combinations AS (
    SELECT DISTINCT instance_type, region
    FROM servers
),
coverage AS (
    SELECT
        u.instance_type,
        u.region,
        tstzmultirange(tstzrange(c.period_start, c.period_end, '[)'))
          - COALESCE(
                range_agg(tstzrange(p.valid_from, p.valid_to, '[)'))
                    FILTER (WHERE p.pricing_id IS NOT NULL),
                '{}'::tstzmultirange
            ) AS missing
    FROM used_combinations u
    CROSS JOIN analysis_config c
    LEFT JOIN pricing p
      ON p.instance_type = u.instance_type
     AND p.region        = u.region
    GROUP BY u.instance_type, u.region, c.period_start, c.period_end
)
SELECT
    instance_type,
    region,
    lower(gap) AS gap_start,
    upper(gap) AS gap_end
FROM coverage
CROSS JOIN LATERAL unnest(missing) AS gap;


-- ---------------------------------------------------------------------
-- dq_unpriced_hours: running hours that fall inside a pricing gap.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW dq_unpriced_hours AS
SELECT
    server_id,
    COUNT(*)              AS unpriced_hours,
    SUM(seconds_on) / 3600 AS unpriced_running_hours
FROM v_hourly_cost
WHERE pricing_id IS NULL
GROUP BY server_id;


-- ---------------------------------------------------------------------
-- dq_summary: one row per check, used by the quality gate and the
-- run summary.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW dq_summary AS
SELECT 'events_total' AS check_name, COUNT(*)::NUMERIC AS value FROM event_validation
UNION ALL
SELECT 'events_excluded', COUNT(*) FROM event_validation WHERE status <> 'paired'
UNION ALL
SELECT 'sessions', COUNT(*) FROM server_sessions
UNION ALL
SELECT 'server_hours_rows', COUNT(*) FROM server_hours
UNION ALL
SELECT 'servers_without_events', COUNT(*)
FROM servers s
WHERE NOT EXISTS (SELECT 1 FROM server_events e WHERE e.server_id = s.server_id)
UNION ALL
SELECT 'pricing_gaps', COUNT(*) FROM dq_pricing_gaps
UNION ALL
SELECT 'unpriced_server_hours', COALESCE(SUM(unpriced_hours), 0) FROM dq_unpriced_hours
UNION ALL
-- Metrics reported for an hour in which no valid session was running
-- (e.g. sessions excluded by event validation). They are not used.
SELECT 'metrics_outside_reconstructed_uptime', COUNT(*)
FROM server_metrics m
WHERE NOT EXISTS (
    SELECT 1 FROM server_hours h
    WHERE h.server_id = m.server_id AND h.hour_start = m.hour_start
)
UNION ALL
SELECT 'running_hours_without_metrics', COUNT(*)
FROM server_hours h
WHERE NOT EXISTS (
    SELECT 1 FROM server_metrics m
    WHERE m.server_id = h.server_id AND m.hour_start = h.hour_start
);
