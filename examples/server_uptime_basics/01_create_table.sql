-- =====================================================================
-- 01_create_table.sql
-- Creates the server_utilization table.
-- Each row is a single event: a server either starts or stops.
-- =====================================================================

DROP TABLE IF EXISTS server_utilization;

CREATE TABLE server_utilization (
    server_id      INTEGER     NOT NULL,
    status_time    TIMESTAMP   NOT NULL,
    session_status VARCHAR(5)  NOT NULL,
    CONSTRAINT chk_session_status CHECK (session_status IN ('start', 'stop'))
);
