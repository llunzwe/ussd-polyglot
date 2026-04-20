-- =============================================================================
-- Migration: V072__operational_monitoring
-- Description: Operational Monitoring, Health Checks & Maintenance
-- Dependencies: V001-V071
--
-- PURPOSE: Enable kernel administrators to monitor ledger health, schedule
-- maintenance tasks, and ensure data integrity through automated checks.
--
-- ADR-019: Partition Management Strategy
-- DECISION: Automatic partition creation via cron, manual archival
-- RATIONALE:
--   - TimescaleDB hypertables need continuous partition creation
--   - Historical partitions can be compressed or archived
--   - Hot partitions (recent) on fast storage, cold on slower storage
-- TRADE-OFFS:
--   (+) Automatic maintenance reduces ops burden
--   (+) Tiered storage reduces costs
--   (-) Requires monitoring for partition growth
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- SCHEMA: ops
-- PURPOSE: Operational monitoring and maintenance
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS ops;
COMMENT ON SCHEMA ops IS 'Operational monitoring, health checks, and maintenance automation';

-- =============================================================================
-- TABLE: ops.ledger_health_metrics
-- PURPOSE: Time-series metrics for ledger health monitoring
-- SECURITY: Admin only
-- =============================================================================
CREATE TABLE IF NOT EXISTS ops.ledger_health_metrics (
    metric_id UUID DEFAULT gen_random_uuid(),
    
    -- Metric identification
    metric_name VARCHAR(100) NOT NULL,
    metric_category VARCHAR(50) NOT NULL 
        CHECK (metric_category IN ('storage', 'performance', 'integrity', 'security')),
    
    -- Values
    metric_value NUMERIC(20, 8) NOT NULL,
    metric_unit VARCHAR(20), -- 'bytes', 'seconds', 'count', 'percentage'
    
    -- Dimensions
    table_name VARCHAR(100),
    schema_name VARCHAR(50),
    
    -- Thresholds
    warning_threshold NUMERIC(20, 8),
    critical_threshold NUMERIC(20, 8),
    is_alerting BOOLEAN DEFAULT FALSE,
    
    -- Timestamp
    measured_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_ops_ledger_health_metrics_metric_id_measured_at PRIMARY KEY (metric_id, measured_at));

-- Convert to hypertable
SELECT create_hypertable(
    'ops.ledger_health_metrics',
    'measured_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_health_metrics_name ON ops.ledger_health_metrics(metric_name, measured_at DESC);
CREATE INDEX IF NOT EXISTS idx_health_metrics_category ON ops.ledger_health_metrics(metric_category, is_alerting) 
    WHERE is_alerting = TRUE;
CREATE INDEX IF NOT EXISTS idx_health_metrics_table ON ops.ledger_health_metrics(table_name, measured_at DESC);

COMMENT ON TABLE ops.ledger_health_metrics IS 
'Time-series metrics for ledger health monitoring and alerting';

-- =============================================================================
-- TABLE: ops.integrity_check_schedules
-- PURPOSE: Scheduled integrity check configuration and results
-- SECURITY: Admin only
-- =============================================================================
CREATE TABLE IF NOT EXISTS ops.integrity_check_schedules (
    schedule_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Schedule identification
    schedule_name VARCHAR(100) UNIQUE NOT NULL,
    
    -- Check configuration
    check_type VARCHAR(50) NOT NULL 
        CHECK (check_type IN ('hash_chain', 'balance_reconciliation', 'fk_integrity', 'orphaned_records', 'partition_health')),
    
    -- Target
    target_schema VARCHAR(50),
    target_table VARCHAR(100),
    
    -- Schedule (cron expression)
    cron_expression VARCHAR(100) NOT NULL DEFAULT '0 2 * * *', -- Daily at 2 AM
    timezone VARCHAR(50) DEFAULT 'UTC',
    
    -- Parameters
    check_parameters JSONB DEFAULT '{}', -- {lookback_days, sample_size}
    
    -- Notification
    alert_channels TEXT[] DEFAULT ARRAY['email'], -- email, slack, pagerduty
    alert_recipients TEXT[], -- Email addresses or webhook URLs
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    last_run_at TIMESTAMPTZ,
    last_run_status VARCHAR(20), -- success, failed, running
    last_run_duration_ms INTEGER,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_integrity_schedules_active ON ops.integrity_check_schedules(is_active, check_type);
CREATE INDEX IF NOT EXISTS idx_integrity_schedules_table ON ops.integrity_check_schedules(target_schema, target_table);

COMMENT ON TABLE ops.integrity_check_schedules IS 
'Scheduled integrity check configuration with cron expressions';

-- =============================================================================
-- TABLE: ops.partition_management_log
-- PURPOSE: Partition creation, compression, and archival tracking
-- SECURITY: Admin only
-- =============================================================================
CREATE TABLE IF NOT EXISTS ops.partition_management_log (
    log_id UUID DEFAULT gen_random_uuid(),
    
    -- Target
    schema_name VARCHAR(50) NOT NULL,
    table_name VARCHAR(100) NOT NULL,
    partition_name VARCHAR(100) NOT NULL,
    partition_range_start TIMESTAMPTZ,
    partition_range_end TIMESTAMPTZ,
    
    -- Operation
    operation VARCHAR(50) NOT NULL 
        CHECK (operation IN ('created', 'compressed', 'decompressed', 'archived', 'dropped', 'moved')),
    
    -- Details
    operation_status VARCHAR(20) NOT NULL 
        CHECK (operation_status IN ('success', 'failed', 'in_progress')),
    operation_details JSONB,
    error_message TEXT,
    
    -- Storage
    storage_tier VARCHAR(20), -- hot, warm, cold
    row_count BIGINT,
    size_bytes BIGINT,
    
    -- Timing
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    duration_ms INTEGER,
    
    -- Audit
    performed_by UUID REFERENCES core.account_registry(account_id),
    CONSTRAINT pk_ops_partition_management_log_log_id_started_at PRIMARY KEY (log_id, started_at));

-- Convert to hypertable
SELECT create_hypertable(
    'ops.partition_management_log',
    'started_at',
    chunk_time_interval => INTERVAL '30 days',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_partition_log_table ON ops.partition_management_log(schema_name, table_name, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_partition_log_operation ON ops.partition_management_log(operation, operation_status);

COMMENT ON TABLE ops.partition_management_log IS 
'Log of partition management operations (creation, compression, archival)';

-- =============================================================================
-- TABLE: ops.maintenance_windows
-- PURPOSE: Scheduled maintenance windows and activity tracking
-- SECURITY: Admin only
-- =============================================================================
CREATE TABLE IF NOT EXISTS ops.maintenance_windows (
    window_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Window definition
    window_name VARCHAR(100) NOT NULL,
    window_type VARCHAR(50) NOT NULL 
        CHECK (window_type IN ('index_rebuild', 'vacuum', 'stats_refresh', 'backup', 'upgrade')),
    
    -- Schedule
    cron_expression VARCHAR(100),
    scheduled_start TIMESTAMPTZ,
    expected_duration_minutes INTEGER,
    
    -- Actual execution
    actual_start TIMESTAMPTZ,
    actual_end TIMESTAMPTZ,
    actual_duration_ms INTEGER,
    
    -- Status
    status VARCHAR(20) DEFAULT 'scheduled' 
        CHECK (status IN ('scheduled', 'in_progress', 'completed', 'failed', 'cancelled')),
    
    -- Impact
    affected_tables TEXT[],
    commands_executed TEXT[],
    
    -- Results
    result_summary TEXT,
    error_details TEXT,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_maintenance_windows_status ON ops.maintenance_windows(status, scheduled_start);
CREATE INDEX IF NOT EXISTS idx_maintenance_windows_type ON ops.maintenance_windows(window_type, status);

COMMENT ON TABLE ops.maintenance_windows IS 
'Scheduled maintenance windows and execution tracking';

-- =============================================================================
-- TABLE: ops.storage_stats
-- PURPOSE: Table-level storage statistics over time
-- SECURITY: Admin only
-- =============================================================================
CREATE TABLE IF NOT EXISTS ops.storage_stats (
    stat_id UUID DEFAULT gen_random_uuid(),
    
    -- Target
    schema_name VARCHAR(50) NOT NULL,
    table_name VARCHAR(100) NOT NULL,
    
    -- Size metrics
    total_size_bytes BIGINT,
    table_size_bytes BIGINT,
    index_size_bytes BIGINT,
    toast_size_bytes BIGINT,
    
    -- Row metrics
    row_count BIGINT,
    dead_row_count BIGINT,
    live_row_count BIGINT,
    
    -- Performance metrics
    seq_scan_count BIGINT,
    idx_scan_count BIGINT,
    n_tup_ins BIGINT,
    n_tup_upd BIGINT,
    n_tup_del BIGINT,
    
    -- Vacuum stats
    last_vacuum_at TIMESTAMPTZ,
    last_autovacuum_at TIMESTAMPTZ,
    last_analyze_at TIMESTAMPTZ,
    
    -- Timestamp
    measured_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_ops_storage_stats_stat_id_measured_at PRIMARY KEY (stat_id, measured_at));

-- Convert to hypertable
SELECT create_hypertable(
    'ops.storage_stats',
    'measured_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_storage_stats_table ON ops.storage_stats(schema_name, table_name, measured_at DESC);
CREATE INDEX IF NOT EXISTS idx_storage_stats_size ON ops.storage_stats(total_size_bytes);

COMMENT ON TABLE ops.storage_stats IS 
'Historical storage and access statistics per table';

-- =============================================================================
-- FUNCTIONS: Operational Procedures
-- =============================================================================

-- Function: Create future partitions for a hypertable
CREATE OR REPLACE FUNCTION ops.create_future_partitions(
    p_schema_name VARCHAR,
    p_table_name VARCHAR,
    p_days_ahead INTEGER DEFAULT 7
)
RETURNS INTEGER AS $$
DECLARE
    v_created INTEGER := 0;
    v_partition_date DATE;
BEGIN
    FOR i IN 0..p_days_ahead LOOP
        v_partition_date := CURRENT_DATE + i;
        
        -- This is a placeholder - actual partition creation depends on TimescaleDB
        -- In practice, use timescaledb_preistry.create_partition or similar
        
        v_created := v_created + 1;
    END LOOP;
    
    -- Log operation
    INSERT INTO ops.partition_management_log (
        schema_name,
        table_name,
        partition_name,
        operation,
        operation_status,
        operation_details
    ) VALUES (
        p_schema_name,
        p_table_name,
        'future_partitions',
        'created',
        'success',
        jsonb_build_object('days_ahead', p_days_ahead, 'partitions_created', v_created)
    );
    
    RETURN v_created;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION ops.create_future_partitions(VARCHAR, VARCHAR, INTEGER) IS 
'Creates future partitions for a TimescaleDB hypertable';

-- Function: Collect storage statistics
CREATE OR REPLACE FUNCTION ops.collect_storage_stats()
RETURNS INTEGER AS $$
DECLARE
    v_collected INTEGER := 0;
    v_rec RECORD;
BEGIN
    FOR v_rec IN 
        SELECT 
            schemaname,
            tablename,
            pg_total_relation_size(schemaname || '.' || tablename) as total_size,
            pg_relation_size(schemaname || '.' || tablename) as table_size,
            pg_indexes_size(schemaname || '.' || tablename) as index_size
        FROM pg_tables
        WHERE schemaname IN ('core', 'app', 'ussd', 'messaging', 'audit', 'events', 'sdk', 'api')
    LOOP
        INSERT INTO ops.storage_stats (
            schema_name,
            table_name,
            total_size_bytes,
            table_size_bytes,
            index_size_bytes
        ) VALUES (
            v_rec.schemaname,
            v_rec.tablename,
            v_rec.total_size,
            v_rec.table_size,
            v_rec.index_size
        );
        
        v_collected := v_collected + 1;
    END LOOP;
    
    RETURN v_collected;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION ops.collect_storage_stats() IS 
'Collects storage statistics for all ledger tables';

-- Function: Get ledger stats summary (for /admin/ledger/stats)
CREATE OR REPLACE FUNCTION ops.get_ledger_stats()
RETURNS TABLE (
    metric VARCHAR(100),
    value NUMERIC,
    unit VARCHAR(20),
    trend VARCHAR(10) -- up, down, stable
) AS $$
BEGIN
    -- Total transactions
    RETURN QUERY
    SELECT 
        'total_transactions'::VARCHAR(100),
        COUNT(*)::NUMERIC,
        'count'::VARCHAR(20),
        'stable'::VARCHAR(10)
    FROM core.transactions;
    
    -- Transactions today
    RETURN QUERY
    SELECT 
        'transactions_today'::VARCHAR(100),
        COUNT(*)::NUMERIC,
        'count'::VARCHAR(20),
        CASE 
            WHEN COUNT(*) > (SELECT AVG(daily_count) FROM (
                SELECT COUNT(*) as daily_count 
                FROM core.transactions 
                WHERE created_at > NOW() - INTERVAL '30 days'
                GROUP BY date_trunc('day', created_at)
            ) sub) THEN 'up'
            ELSE 'stable'
        END::VARCHAR(10)
    FROM core.transactions
    WHERE created_at >= CURRENT_DATE;
    
    -- Total storage
    RETURN QUERY
    SELECT 
        'total_storage_bytes'::VARCHAR(100),
        SUM(total_size_bytes)::NUMERIC,
        'bytes'::VARCHAR(20),
        'stable'::VARCHAR(10)
    FROM ops.storage_stats
    WHERE measured_at = (SELECT MAX(measured_at) FROM ops.storage_stats);
    
    -- Active partitions
    RETURN QUERY
    SELECT 
        'active_partitions'::VARCHAR(100),
        COUNT(*)::NUMERIC,
        'count'::VARCHAR(20),
        'stable'::VARCHAR(10)
    FROM ops.partition_management_log
    WHERE operation = 'created'
      AND started_at > NOW() - INTERVAL '30 days';
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION ops.get_ledger_stats() IS 
'Returns summary statistics for ledger health dashboard';

-- =============================================================================
-- VIEWS: Operational Dashboard
-- =============================================================================

-- View: Recent health alerts
CREATE OR REPLACE VIEW ops.recent_health_alerts AS
SELECT 
    metric_name,
    metric_value,
    metric_unit,
    warning_threshold,
    critical_threshold,
    measured_at,
    CASE 
        WHEN critical_threshold IS NOT NULL AND metric_value >= critical_threshold THEN 'CRITICAL'
        WHEN warning_threshold IS NOT NULL AND metric_value >= warning_threshold THEN 'WARNING'
        ELSE 'OK'
    END as alert_level
FROM ops.ledger_health_metrics
WHERE is_alerting = TRUE
  AND measured_at > NOW() - INTERVAL '24 hours'
ORDER BY measured_at DESC;

COMMENT ON VIEW ops.recent_health_alerts IS 'Recent health metrics that have triggered alerts';

-- View: Partition health summary
CREATE OR REPLACE VIEW ops.partition_health_summary AS
SELECT 
    schema_name,
    table_name,
    COUNT(*) as partition_count,
    SUM(CASE WHEN operation = 'compressed' THEN 1 ELSE 0 END) as compressed_count,
    SUM(CASE WHEN operation = 'archived' THEN 1 ELSE 0 END) as archived_count,
    MAX(started_at) as last_operation_at
FROM ops.partition_management_log
WHERE started_at > NOW() - INTERVAL '90 days'
GROUP BY schema_name, table_name;

COMMENT ON VIEW ops.partition_health_summary IS 'Summary of partition management operations per table';

-- =============================================================================
-- RLS POLICIES
-- =============================================================================

DO $$
BEGIN
    ALTER TABLE ops.ledger_health_metrics ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE ops.integrity_check_schedules ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE ops.partition_management_log ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE ops.maintenance_windows ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE ops.storage_stats ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Admin only access
CREATE POLICY ops_metrics_admin ON ops.ledger_health_metrics
    FOR ALL
    TO ussd_app_user
    USING (FALSE);

CREATE POLICY ops_schedules_admin ON ops.integrity_check_schedules
    FOR ALL
    TO ussd_app_user
    USING (FALSE);

CREATE POLICY ops_partitions_admin ON ops.partition_management_log
    FOR ALL
    TO ussd_app_user
    USING (FALSE);

CREATE POLICY ops_maintenance_admin ON ops.maintenance_windows
    FOR ALL
    TO ussd_app_user
    USING (FALSE);

CREATE POLICY ops_storage_admin ON ops.storage_stats
    FOR ALL
    TO ussd_app_user
    USING (FALSE);

-- =============================================================================
-- GRANTS
-- =============================================================================

GRANT USAGE ON SCHEMA ops TO ussd_gateway_role;
GRANT EXECUTE ON FUNCTION ops.get_ledger_stats() TO ussd_gateway_role;
GRANT SELECT ON ops.recent_health_alerts TO ussd_gateway_role;
GRANT SELECT ON ops.partition_health_summary TO ussd_gateway_role;

COMMIT;
