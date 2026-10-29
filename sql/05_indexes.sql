-- =====================================================================
-- 05_indexes.sql
-- Indexes added after the benchmark (benchmark/README.md). Constraint
-- indexes (primary keys, unique, exclusion) are created by the schema
-- and are present in every benchmark variant.
-- =====================================================================

-- server_metrics is loaded in time order (as an ingestion pipeline would
-- write it), so hour_start is strongly correlated with the physical row
-- order. A BRIN index stores one min/max summary per block range: it is
-- very small and lets broad time-range scans skip unrelated blocks.
CREATE INDEX IF NOT EXISTS brin_server_metrics_hour
    ON server_metrics USING brin (hour_start);
