-- =====================================================================
-- 01_schema.sql
-- Core relational model: six source tables plus one configuration row.
-- All data loaded into this schema is simulated (fictitious servers,
-- measurements, budgets and prices).
--
-- Conventions
--   * Every instant is TIMESTAMPTZ and every session runs in UTC.
--   * Intervals are half-open: [start, end).
--   * Money is NUMERIC (exact). Values are rounded only for presentation.
-- Expects an empty database (the pipeline creates a dedicated one).
-- =====================================================================

SET client_min_messages = warning;
SET timezone = 'UTC';

-- Needed so the pricing exclusion constraint can combine "=" on text
-- columns with "&&" (overlap) on a time range.
CREATE EXTENSION IF NOT EXISTS btree_gist;


-- ---------------------------------------------------------------------
-- departments: one row per business area / cost center.
-- ---------------------------------------------------------------------
CREATE TABLE departments (
    department_id   SMALLINT PRIMARY KEY,
    department_name TEXT     NOT NULL UNIQUE,
    cost_center     TEXT     NOT NULL UNIQUE
        CHECK (cost_center ~ '^CC-[0-9]{4}$')
);


-- ---------------------------------------------------------------------
-- servers: one row per server. Department, region and instance type are
-- constant during the analysis period (simplifying assumption).
-- ---------------------------------------------------------------------
CREATE TABLE servers (
    server_id     INTEGER  PRIMARY KEY,
    hostname      TEXT     NOT NULL UNIQUE,
    department_id SMALLINT NOT NULL REFERENCES departments (department_id),
    region        TEXT     NOT NULL,
    instance_type TEXT     NOT NULL,
    environment   TEXT     NOT NULL
        CHECK (environment IN ('production', 'development')),
    is_critical   BOOLEAN  NOT NULL
);

CREATE INDEX idx_servers_department ON servers (department_id);


-- ---------------------------------------------------------------------
-- server_events: one row per power event (start or stop).
-- A server cannot record two events at the same instant: this rejects
-- exact duplicates and ambiguous start/stop ties at load time.
-- ---------------------------------------------------------------------
CREATE TABLE server_events (
    event_id   BIGINT      PRIMARY KEY,
    server_id  INTEGER     NOT NULL REFERENCES servers (server_id),
    event_time TIMESTAMPTZ NOT NULL,
    event_type TEXT        NOT NULL CHECK (event_type IN ('start', 'stop')),
    CONSTRAINT uq_server_events_server_time UNIQUE (server_id, event_time)
);


-- ---------------------------------------------------------------------
-- server_metrics: one row per server and UTC clock hour
-- [hour_start, hour_start + 1 hour). Values are the average CPU and
-- memory utilization over the part of that hour in which the server was
-- running. A missing row means "not observed" (unknown), never 0 %.
-- ---------------------------------------------------------------------
CREATE TABLE server_metrics (
    server_id   INTEGER      NOT NULL REFERENCES servers (server_id),
    hour_start  TIMESTAMPTZ  NOT NULL
        CHECK (EXTRACT(EPOCH FROM hour_start) % 3600 = 0),
    cpu_avg_pct NUMERIC(5,2) NOT NULL CHECK (cpu_avg_pct BETWEEN 0 AND 100),
    mem_avg_pct NUMERIC(5,2) NOT NULL CHECK (mem_avg_pct BETWEEN 0 AND 100),
    PRIMARY KEY (server_id, hour_start)
);


-- ---------------------------------------------------------------------
-- pricing: fictitious hourly compute rate per instance type and region,
-- valid during [valid_from, valid_to). Rate changes take effect at
-- 00:00 UTC. Overlapping validity for the same type/region is rejected
-- by the exclusion constraint; gaps are detected by dq_pricing_gaps.
-- ---------------------------------------------------------------------
CREATE TABLE pricing (
    pricing_id      INTEGER       PRIMARY KEY,
    instance_type   TEXT          NOT NULL,
    region          TEXT          NOT NULL,
    valid_from      TIMESTAMPTZ   NOT NULL,
    valid_to        TIMESTAMPTZ   NOT NULL,
    hourly_rate_usd NUMERIC(10,4) NOT NULL CHECK (hourly_rate_usd > 0),
    CONSTRAINT chk_pricing_valid_range CHECK (valid_from < valid_to),
    CONSTRAINT chk_pricing_midnight_utc CHECK (
        EXTRACT(EPOCH FROM valid_from) % 86400 = 0
        AND EXTRACT(EPOCH FROM valid_to) % 86400 = 0
    ),
    CONSTRAINT ex_pricing_no_overlap EXCLUDE USING gist (
        instance_type WITH =,
        region        WITH =,
        tstzrange(valid_from, valid_to, '[)') WITH &&
    )
);


-- ---------------------------------------------------------------------
-- budgets: compute budget per department and calendar month.
-- A row with amount 0 is an explicit zero budget; a missing row means
-- no budget was defined. The two cases are reported differently.
-- ---------------------------------------------------------------------
CREATE TABLE budgets (
    department_id SMALLINT      NOT NULL REFERENCES departments (department_id),
    budget_month  DATE          NOT NULL CHECK (EXTRACT(DAY FROM budget_month) = 1),
    amount_usd    NUMERIC(12,2) NOT NULL CHECK (amount_usd >= 0),
    PRIMARY KEY (department_id, budget_month)
);


-- ---------------------------------------------------------------------
-- analysis_config: single row of explicit analysis parameters.
-- Thresholds are project choices for this simulated case, not
-- universal standards (see docs/methodology.md).
-- ---------------------------------------------------------------------
CREATE TABLE analysis_config (
    config_id              BOOLEAN      PRIMARY KEY DEFAULT TRUE CHECK (config_id),
    period_start           TIMESTAMPTZ  NOT NULL,
    period_end             TIMESTAMPTZ  NOT NULL,
    -- Low utilization (analysis 4)
    low_cpu_avg_max_pct    NUMERIC(5,2) NOT NULL,
    low_cpu_p95_max_pct    NUMERIC(5,2) NOT NULL,
    low_mem_avg_max_pct    NUMERIC(5,2) NOT NULL,
    low_min_observed_hours INTEGER      NOT NULL CHECK (low_min_observed_hours > 0),
    low_min_coverage       NUMERIC(4,3) NOT NULL CHECK (low_min_coverage BETWEEN 0 AND 1),
    -- Off-hours scenario (analysis 6): servers stay on Monday-Friday
    -- during [workday_start_hour, workday_end_hour) UTC; every other
    -- hour belongs to the proposed shutdown window.
    workday_start_hour     SMALLINT     NOT NULL CHECK (workday_start_hour BETWEEN 0 AND 23),
    workday_end_hour       SMALLINT     NOT NULL CHECK (workday_end_hour BETWEEN 1 AND 24),
    CHECK (period_start < period_end),
    CHECK (workday_start_hour < workday_end_hour)
);

INSERT INTO analysis_config VALUES (
    TRUE,
    '2025-01-01 00:00:00+00',   -- period_start (inclusive)
    '2025-04-01 00:00:00+00',   -- period_end   (exclusive) -> 90 days
    10.00,                      -- average CPU at or below 10 %
    30.00,                      -- 95th percentile CPU at or below 30 %
    40.00,                      -- average memory at or below 40 %
    168,                        -- at least one week of observed hours
    0.800,                      -- at least 80 % of running hours observed
    7,                          -- workday starts 07:00 UTC
    20                          -- workday ends   20:00 UTC
);
