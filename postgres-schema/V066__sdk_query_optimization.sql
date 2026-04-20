-- =============================================================================
-- Migration: V066__sdk_query_optimization
-- Description: SDK Query Optimization & Export Support
-- Dependencies: V001-V065
-- 
-- PURPOSE: Enable performant ledger queries and data exports for business apps
-- via the SDK. Includes materialized views, query optimization tables, and
-- async export job management.
--
-- ADR-010: Materialized Views for Common Aggregations
-- DECISION: Pre-compute daily/hourly aggregates vs real-time calculation
-- RATIONALE: 
--   - 90% of SDK queries are aggregates (daily totals, per-app stats)
--   - Real-time SUM() on hypertables with billions of rows is too slow
--   - Materialized views with concurrent refresh provide <100ms response
-- TRADE-OFFS:
--   (+) Sub-second query response for SDK list_transactions()
--   (+) Reduced database load during peak hours
--   (-) Data is eventually consistent (max 5 min lag)
--   (-) Additional storage for aggregated data (~10% overhead)
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- SCHEMA: sdk
-- PURPOSE: SDK-specific tables and views isolated from core ledger
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS sdk;
COMMENT ON SCHEMA sdk IS 'SDK and API support tables for external application integration';

-- =============================================================================
-- TABLE: sdk.query_patterns
-- PURPOSE: Track common query patterns for index optimization
-- SECURITY: Internal SDK analytics only
-- =============================================================================
CREATE TABLE IF NOT EXISTS sdk.query_patterns (
    pattern_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Query classification
    query_type VARCHAR(50) NOT NULL 
        CHECK (query_type IN ('transaction_list', 'balance_summary', 'audit_trail', 'verification')),
    
    -- Filter pattern (normalized)
    filter_pattern JSONB NOT NULL, -- {filters: ['app_id', 'date_range'], sorts: ['created_at DESC']}
    
    -- Usage metrics
    execution_count INTEGER DEFAULT 1,
    avg_execution_ms INTEGER,
    last_executed_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- Optimization status
    is_optimized BOOLEAN DEFAULT FALSE,
    optimization_notes TEXT,
    materialized_view_ref VARCHAR(100), -- Reference to supporting materialized view
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_query_patterns_type ON sdk.query_patterns(query_type, is_optimized);
CREATE INDEX IF NOT EXISTS idx_query_patterns_filters ON sdk.query_patterns USING GIN(filter_pattern);

COMMENT ON TABLE sdk.query_patterns IS 
'Tracks API query patterns to optimize indexes and materialized views for SDK performance';

-- =============================================================================
-- TABLE: sdk.export_jobs
-- PURPOSE: Async export job management for CSV/JSON/Excel downloads
-- SECURITY: Application-scoped via RLS
-- =============================================================================
CREATE TABLE IF NOT EXISTS sdk.export_jobs (
    job_id UUID DEFAULT gen_random_uuid(),
    
    -- Job identification
    job_reference VARCHAR(100),
    CONSTRAINT uq_sdk_export_jobs_job_reference UNIQUE (job_reference, created_at), NOT NULL, -- External reference for status polling
    
    -- Application context
    application_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    requested_by UUID NOT NULL REFERENCES core.account_registry(account_id),
    
    -- Export configuration
    export_type VARCHAR(30) NOT NULL 
        CHECK (export_type IN ('transactions', 'audit_trail', 'reconciliation', 'compliance')),
    export_format VARCHAR(10) NOT NULL 
        CHECK (export_format IN ('csv', 'json', 'xlsx', 'parquet')),
    
    -- Query parameters (stored for reproducibility)
    filter_criteria JSONB NOT NULL, -- {date_from, date_to, account_ids, status}
    sort_order JSONB, -- [{field, direction}]
    
    -- Status tracking
    status VARCHAR(20) DEFAULT 'pending'
        CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'cancelled')),
    
    -- Progress
    total_records INTEGER,
    processed_records INTEGER DEFAULT 0,
    progress_percent INTEGER DEFAULT 0,
    
    -- Result
    file_location VARCHAR(500), -- S3/MinIO path
    file_size_bytes BIGINT,
    checksum_sha256 VARCHAR(64),
    download_url VARCHAR(1000), -- Presigned URL (encrypted)
    download_url_expires_at TIMESTAMPTZ,
    
    -- Timing
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '7 days'),
    
    -- Error handling
    error_message TEXT,
    retry_count INTEGER DEFAULT 0,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_sdk_export_jobs_job_id_created_at PRIMARY KEY (job_id, created_at));

-- Convert to hypertable for time-series cleanup
SELECT create_hypertable(
    'sdk.export_jobs',
    'created_at',
    chunk_time_interval => INTERVAL '7 days',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_export_jobs_app ON sdk.export_jobs(application_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_export_jobs_ref ON sdk.export_jobs(job_reference);
CREATE INDEX IF NOT EXISTS idx_export_jobs_pending ON sdk.export_jobs(status, created_at) 
    WHERE status = 'pending';

COMMENT ON TABLE sdk.export_jobs IS 
'Async export job queue for CSV/JSON/Excel downloads via SDK client.ledger.export()';

-- =============================================================================
-- TABLE: sdk.custom_tags
-- PURPOSE: Allow business apps to attach searchable tags to ledger entries
-- SECURITY: Application-scoped via RLS
-- =============================================================================
CREATE TABLE IF NOT EXISTS sdk.custom_tags (
    tag_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Target reference (polymorphic)
    target_type VARCHAR(50) NOT NULL 
        CHECK (target_type IN ('transaction', 'account', 'session', 'payment')),
    target_id UUID NOT NULL,
    
    -- Application context
    application_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    
    -- Tag data
    tag_key VARCHAR(100) NOT NULL, -- e.g., 'order_id', 'customer_tier'
    tag_value TEXT NOT NULL,
    tag_value_type VARCHAR(20) DEFAULT 'string' 
        CHECK (tag_value_type IN ('string', 'number', 'boolean', 'date', 'json')),
    
    -- Search optimization
    tag_value_normalized TEXT, -- Lowercase, trimmed for search
    
    -- Scope
    is_searchable BOOLEAN DEFAULT TRUE,
    is_encrypted BOOLEAN DEFAULT FALSE, -- For sensitive tags
    
    -- Audit
    created_by UUID REFERENCES core.account_registry(account_id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    UNIQUE (target_type, target_id, tag_key)
);

CREATE INDEX IF NOT EXISTS idx_custom_tags_target ON sdk.custom_tags(target_type, target_id);
CREATE INDEX IF NOT EXISTS idx_custom_tags_app ON sdk.custom_tags(application_id, tag_key, tag_value_normalized);
CREATE INDEX IF NOT EXISTS idx_custom_tags_search ON sdk.custom_tags USING GIN(tag_value_normalized gin_trgm_ops);

COMMENT ON TABLE sdk.custom_tags IS 
'Custom tag storage for business apps to attach searchable metadata to ledger entries';

-- =============================================================================
-- MATERIALIZED VIEW: sdk.daily_transaction_summary
-- PURPOSE: Pre-aggregated daily stats per application for fast SDK queries
-- REFRESH: Every 5 minutes via cron or trigger
-- PRODUCTION FIX (PERF-002): Corrected column names to match actual schema
-- =============================================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS sdk.daily_transaction_summary AS
SELECT 
    date_trunc('day', t.committed_at)::date as summary_date,  -- Was created_at, actual is committed_at
    t.application_id,
    t.currency as currency_code,  -- Was currency_code, actual column is currency
    
    -- Counts
    COUNT(*) as total_transactions,
    COUNT(*) FILTER (WHERE t.status = 'completed') as completed_count,
    COUNT(*) FILTER (WHERE t.status = 'failed') as failed_count,
    COUNT(*) FILTER (WHERE t.status = 'pending') as pending_count,
    
    -- Amounts
    SUM(t.amount) as total_amount,
    SUM(t.amount) FILTER (WHERE t.status = 'completed') as completed_amount,
    0::NUMERIC as total_fees,  -- fee_amount doesn't exist in transaction_log
    
    -- Volume metrics
    AVG(t.amount) as avg_transaction_amount,
    MAX(t.amount) as max_transaction_amount,
    MIN(t.amount) as min_transaction_amount,
    
    -- Timing (use committed_at and client_timestamp for duration estimate)
    AVG(extract(epoch from (t.committed_at - COALESCE(t.client_timestamp, t.committed_at)))) as avg_completion_seconds,
    
    -- Last update
    MAX(t.committed_at) as last_transaction_at
FROM core.transactions t
GROUP BY 
    date_trunc('day', t.committed_at)::date,
    t.application_id,
    t.currency
WITH NO DATA;

-- Create indexes on materialized view
-- PRODUCTION FIX: Changed currency_code to currency to match corrected column name
CREATE UNIQUE INDEX IF NOT EXISTS idx_daily_summary_pk 
    ON sdk.daily_transaction_summary(summary_date, application_id, currency);
CREATE INDEX IF NOT EXISTS idx_daily_summary_app ON sdk.daily_transaction_summary(application_id, summary_date DESC);

COMMENT ON MATERIALIZED VIEW sdk.daily_transaction_summary IS 
'Daily aggregated transaction statistics per application for fast SDK queries. 
Refresh: REFRESH MATERIALIZED VIEW CONCURRENTLY sdk.daily_transaction_summary;';

-- =============================================================================
-- MATERIALIZED VIEW: sdk.hourly_transaction_volume
-- PURPOSE: Hourly volume patterns for analytics dashboards
-- PRODUCTION FIX (PERF-002): Corrected column names to match actual schema
-- =============================================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS sdk.hourly_transaction_volume AS
SELECT 
    date_trunc('hour', t.committed_at) as hour_bucket,  -- Was created_at, actual is committed_at
    t.application_id,
    t.transaction_type_id as transaction_type,  -- Was transaction_type, actual is transaction_type_id
    
    COUNT(*) as transaction_count,
    SUM(t.amount) as volume_amount,
    COUNT(DISTINCT t.initiator_account_id) as unique_payers,  -- Was source_account_id, actual is initiator_account_id
    COUNT(DISTINCT t.beneficiary_account_id) as unique_payees  -- Was destination_account_id, actual is beneficiary_account_id
FROM core.transactions t
GROUP BY 
    date_trunc('hour', t.committed_at),
    t.application_id,
    t.transaction_type_id
WITH NO DATA;

CREATE UNIQUE INDEX IF NOT EXISTS idx_hourly_volume_pk 
    ON sdk.hourly_transaction_volume(hour_bucket, application_id, transaction_type);
CREATE INDEX IF NOT EXISTS idx_hourly_volume_app ON sdk.hourly_transaction_volume(application_id, hour_bucket DESC);

COMMENT ON MATERIALIZED VIEW sdk.hourly_transaction_volume IS 
'Hourly transaction volume patterns for real-time analytics dashboards';

-- =============================================================================
-- TABLE: sdk.full_text_search_index
-- PURPOSE: Searchable index for memo/description fields
-- SECURITY: Application-scoped via RLS
-- =============================================================================
CREATE TABLE IF NOT EXISTS sdk.full_text_search_index (
    search_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Target reference
    target_type VARCHAR(50) NOT NULL,
    target_id UUID NOT NULL,
    
    -- Application context
    application_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    
    -- Searchable content
    title TEXT,
    content TEXT,
    
    -- PostgreSQL tsvector (pre-computed)
    search_vector tsvector,
    
    -- Metadata for filtering
    category VARCHAR(50),
    tags TEXT[],
    
    -- Audit
    indexed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    UNIQUE (target_type, target_id)
);

-- GIN index for full-text search
CREATE INDEX IF NOT EXISTS idx_fts_vector ON sdk.full_text_search_index USING GIN(search_vector);
CREATE INDEX IF NOT EXISTS idx_fts_app ON sdk.full_text_search_index(application_id, indexed_at DESC);

COMMENT ON TABLE sdk.full_text_search_index IS 
'Full-text search index for transaction memos, descriptions, and metadata';

-- =============================================================================
-- FUNCTIONS: Materialized View Refresh Management
-- =============================================================================

-- Function: Refresh materialized views concurrently (non-blocking)
CREATE OR REPLACE FUNCTION sdk.refresh_materialized_views()
RETURNS INTEGER AS $$
DECLARE
    v_refreshed INTEGER := 0;
BEGIN
    -- Refresh concurrently if unique index exists
    REFRESH MATERIALIZED VIEW CONCURRENTLY sdk.daily_transaction_summary;
    v_refreshed := v_refreshed + 1;
    
    REFRESH MATERIALIZED VIEW CONCURRENTLY sdk.hourly_transaction_volume;
    v_refreshed := v_refreshed + 1;
    
    RETURN v_refreshed;
EXCEPTION WHEN OTHERS THEN
    -- Log error but don't fail
    RAISE WARNING 'Failed to refresh materialized views: %', SQLERRM;
    RETURN 0;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION sdk.refresh_materialized_views() IS 
'Refreshes all SDK materialized views concurrently (non-blocking)';

-- Function: Update full-text search vector
CREATE OR REPLACE FUNCTION sdk.update_search_vector()
RETURNS TRIGGER AS $$
BEGIN
    NEW.search_vector := 
        setweight(to_tsvector('english', COALESCE(NEW.title, '')), 'A') ||
        setweight(to_tsvector('english', COALESCE(NEW.content, '')), 'B') ||
        setweight(to_tsvector('english', COALESCE(array_to_string(NEW.tags, ' '), '')), 'C');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_fts_vector_update ON sdk.full_text_search_index;
CREATE TRIGGER trg_fts_vector_update
    BEFORE INSERT OR UPDATE ON sdk.full_text_search_index
    FOR EACH ROW
    EXECUTE FUNCTION sdk.update_search_vector();

-- =============================================================================
-- RLS POLICIES
-- =============================================================================

DO $$
BEGIN
    ALTER TABLE sdk.query_patterns ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE sdk.export_jobs ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE sdk.export_jobs FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE sdk.custom_tags ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE sdk.custom_tags FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE sdk.full_text_search_index ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE sdk.full_text_search_index FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Application isolation for SDK tables
CREATE POLICY export_jobs_app_isolation ON sdk.export_jobs
    FOR ALL
    TO ussd_app_user
    USING (application_id = current_setting('app.current_application_id', true)::UUID);

CREATE POLICY custom_tags_app_isolation ON sdk.custom_tags
    FOR ALL
    TO ussd_app_user
    USING (application_id = current_setting('app.current_application_id', true)::UUID);

CREATE POLICY fts_app_isolation ON sdk.full_text_search_index
    FOR ALL
    TO ussd_app_user
    USING (application_id = current_setting('app.current_application_id', true)::UUID);

-- Query patterns are internal only
CREATE POLICY query_patterns_internal ON sdk.query_patterns
    FOR ALL
    TO ussd_app_user
    USING (FALSE); -- Only accessible via admin role

-- =============================================================================
-- WORM TRIGGERS (Immutability for export jobs)
-- =============================================================================

CREATE TRIGGER trg_export_jobs_prevent_update_completed
    BEFORE UPDATE ON sdk.export_jobs
    FOR EACH ROW
    WHEN (OLD.status IN ('completed', 'failed', 'cancelled'))
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_export_jobs_prevent_delete
    BEFORE DELETE ON sdk.export_jobs
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

-- =============================================================================
-- GRANTS
-- =============================================================================

GRANT USAGE ON SCHEMA sdk TO ussd_app_user, ussd_gateway_role;
GRANT SELECT, INSERT ON sdk.export_jobs TO ussd_app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON sdk.custom_tags TO ussd_app_user;
GRANT SELECT ON sdk.daily_transaction_summary TO ussd_app_user;
GRANT SELECT ON sdk.hourly_transaction_volume TO ussd_app_user;
GRANT SELECT ON sdk.full_text_search_index TO ussd_app_user;

COMMIT;
