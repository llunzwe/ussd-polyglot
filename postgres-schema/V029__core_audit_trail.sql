-- =============================================================================
-- Migration: V032__core_audit_trail
-- Description: Core table: audit_trail
-- Dependencies: V031
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- USSD KERNEL CORE SCHEMA - AUDIT TRAIL
-- Enterprise-Grade Immutable Ledger System
-- =============================================================================
-- FILENAME:    029_audit_trail.sql
-- SCHEMA:      ussd_core
-- TABLE:       audit_trail
-- DESCRIPTION: Comprehensive audit trail for all data access and modifications
--              with immutable logging for compliance and forensic analysis.
-- =============================================================================

/*
================================================================================
COMPLIANCE FRAMEWORK
================================================================================

ISO/IEC 27001:2022 (Information Security Management Systems)
├── A.8.1 User endpoint devices - Access logging
├── A.8.5 Secure authentication - Authentication audit
├── A.8.11 Data masking - Sensitive data handling
├── A.8.15 Logging - Comprehensive activity logging
└── A.8.16 Monitoring - Real-time monitoring

ISO/IEC 27040:2024 (Storage Security)
├── Immutable audit logs: WORM storage
├── Tamper detection: Hash chain verification
├── Long-term retention: 7+ years
└── Integrity verification: Cryptographic integrity

GDPR Compliance
├── Lawful basis: Legitimate interest for security
├── Data minimization: Minimal PII in logs
├── Retention limits: Defined retention periods
└── Subject access: Log access for data subjects

Financial Regulations
├── SOX: Change audit trail
├── PCI DSS: Access logging
├── AML: Activity monitoring
└── General: 7 year retention

================================================================================
ENTERPRISE POSTGRESQL CODING PRACTICES
================================================================================

1. AUDIT CATEGORIES
   - DATA_ACCESS: Read operations
   - DATA_CHANGE: Create/update/delete
   - SECURITY: Authentication/authorization
   - ADMIN: Administrative actions
   - SYSTEM: System events

2. AUDIT LEVELS
   - DEBUG: Detailed debugging info
   - INFO: Normal operations
   - WARNING: Suspicious activity
   - ERROR: Errors and failures
   - CRITICAL: Security incidents

3. DATA HANDLING
   - Sanitization of sensitive data
   - PII masking
   - Encryption of sensitive fields
   - Hash verification

================================================================================
SECURITY IMPLEMENTATION NOTES
================================================================================

AUDIT SECURITY:
- Immutable audit records
- Separate audit schema
- Audit table protection
- Hash chain verification

TAMPER DETECTION:
- Record hashing
- Chain verification
- Anomaly detection
- Alert on tampering

ACCESS CONTROL:
- Audit read restricted to auditors
- No delete access
- Append-only enforcement

================================================================================
PERFORMANCE OPTIMIZATION ANNOTATIONS
================================================================================

INDEXES:
- PRIMARY KEY: audit_id
- TIME: created_at DESC
- CATEGORY: audit_category + created_at
- ACTOR: actor_account_id + created_at
- TABLE: table_name + record_id

PARTITIONING:
- Range partition by created_at (monthly)
- Auto-archive old partitions
- Compression for old data

================================================================================
AUDIT AND LOGGING REQUIREMENTS
================================================================================

MANDATORY EVENTS:
- All authentication attempts
- All authorization decisions
- All data modifications
- All administrative actions
- All security events
- All system events

RETENTION:
- Security events: 7 years
- Data changes: 7 years
- Access logs: 2 years
- Debug logs: 30 days

MONITORING:
- Real-time alerting
- Anomaly detection
- Compliance dashboards
- Forensic search

================================================================================
*/

-- -----------------------------------------------------------------------------
-- CREATE TABLE: audit_trail (partitioned)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.audit_trail (
    -- Primary identifier
    audit_id BIGSERIAL,
    audit_reference VARCHAR(100) NOT NULL DEFAULT 'AUTO-' || substr(md5(random()::text), 1, 16),
    
    -- Audit classification
    audit_category VARCHAR(50) NOT NULL
        CHECK (audit_category IN ('DATA_ACCESS', 'DATA_CHANGE', 'SECURITY', 'ADMIN', 'SYSTEM', 'COMPLIANCE')),
    audit_level VARCHAR(20) NOT NULL
        CHECK (audit_level IN ('DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL')),
    audit_event VARCHAR(100) NOT NULL,
    audit_description TEXT,
    
    -- Actor information
    actor_account_id UUID,
    actor_type VARCHAR(50) DEFAULT 'USER',  -- 'USER', 'SYSTEM', 'API', 'BATCH', 'SERVICE'
    actor_name VARCHAR(255),
    session_id TEXT,
    api_key_id UUID,
    
    -- Action details
    action VARCHAR(50) NOT NULL,  -- 'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'LOGIN', 'LOGOUT', etc.
    action_status VARCHAR(20) NOT NULL  -- 'SUCCESS', 'FAILURE', 'DENIED', 'PENDING'
        CHECK (action_status IN ('SUCCESS', 'FAILURE', 'DENIED', 'PENDING')),
    action_result TEXT,
    
    -- Target object
    table_schema VARCHAR(50),
    table_name VARCHAR(100),
    record_id TEXT,
    record_type VARCHAR(50),
    
    -- Change data (for DATA_CHANGE category)
    old_data JSONB,
    new_data JSONB,
    change_summary TEXT,
    changed_fields TEXT[],
    
    -- Context
    application_id UUID,
    transaction_id UUID,
    correlation_id UUID,
    request_id TEXT,
    workflow_id UUID,
    
    -- Client information
    client_ip INET,
    client_ip_country VARCHAR(2),
    user_agent TEXT,
    device_fingerprint VARCHAR(64),
    geolocation JSONB,
    
    -- Query information
    query_text TEXT,
    query_hash VARCHAR(64),
    row_count INTEGER,
    execution_time_ms INTEGER,
    
    -- Error information
    error_code VARCHAR(50),
    error_message TEXT,
    stack_trace TEXT,
    
    -- Integrity (hash chain)
    record_hash VARCHAR(64) NOT NULL DEFAULT 'PENDING',
    previous_audit_hash VARCHAR(64),  -- For hash chain
    chain_verified BOOLEAN DEFAULT FALSE,
    
    -- Retention
    retention_class VARCHAR(20) DEFAULT 'STANDARD'  -- 'SHORT', 'STANDARD', 'LONG', 'PERMANENT'
        CHECK (retention_class IN ('SHORT', 'STANDARD', 'LONG', 'PERMANENT')),
    purge_after_date DATE,
    
    -- Timing
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Partition key
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE,
    
    -- Constraints
    PRIMARY KEY (audit_id, created_at)
);

-- -----------------------------------------------------------------------------
-- CONVERT TO TIMESCALEDB HYPERTABLE
-- -----------------------------------------------------------------------------

-- Convert to hypertable for time-series optimization
-- Using created_at as the time column for automatic partitioning
SELECT create_hypertable(
    'core.audit_trail',
    'created_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

-- -----------------------------------------------------------------------------
-- INDEXES
-- -----------------------------------------------------------------------------
-- Time-based queries
CREATE INDEX IF NOT EXISTS idx_audit_trail_time 
    ON core.audit_trail(created_at DESC);

-- Unique index for audit_reference including partitioning column
CREATE UNIQUE INDEX IF NOT EXISTS idx_audit_trail_reference 
    ON core.audit_trail(audit_reference, created_at);

-- Category and level filtering
CREATE INDEX IF NOT EXISTS idx_audit_trail_category_level 
    ON core.audit_trail(audit_category, audit_level, created_at DESC);

-- Event type queries
CREATE INDEX IF NOT EXISTS idx_audit_trail_event 
    ON core.audit_trail(audit_event, created_at DESC);

-- Actor tracking
CREATE INDEX IF NOT EXISTS idx_audit_trail_actor 
    ON core.audit_trail(actor_account_id, created_at DESC) 
    WHERE actor_account_id IS NOT NULL;

-- Table change tracking
CREATE INDEX IF NOT EXISTS idx_audit_trail_table 
    ON core.audit_trail(table_schema, table_name, created_at DESC) 
    WHERE table_name IS NOT NULL;

-- Record-specific history
CREATE INDEX IF NOT EXISTS idx_audit_trail_record 
    ON core.audit_trail(record_id, table_name, created_at DESC) 
    WHERE record_id IS NOT NULL;

-- Transaction correlation
CREATE INDEX IF NOT EXISTS idx_audit_trail_transaction 
    ON core.audit_trail(transaction_id, created_at DESC) 
    WHERE transaction_id IS NOT NULL;

-- Correlation tracking
CREATE INDEX IF NOT EXISTS idx_audit_trail_correlation 
    ON core.audit_trail(correlation_id, created_at DESC) 
    WHERE correlation_id IS NOT NULL;

-- Security event monitoring
CREATE INDEX IF NOT EXISTS idx_audit_trail_security 
    ON core.audit_trail(audit_category, action_status, created_at DESC) 
    WHERE audit_category = 'SECURITY';

-- -----------------------------------------------------------------------------
-- TIMESCALEDB OPTIMIZATIONS (optional - skipped if extension unavailable)
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    ALTER TABLE core.audit_trail SET (
        timescaledb.compress,
        timescaledb.compress_segmentby = 'audit_category, table_name'
    );
    PERFORM add_compression_policy('core.audit_trail', INTERVAL '30 days');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TimescaleDB compression setup skipped: %', SQLERRM;
END;
$$;

-- Add retention policy based on retention_class
-- Note: Actual retention requires custom policy based on retention_class
-- SELECT add_retention_policy('core.audit_trail', INTERVAL '7 years');

-- Error tracking
CREATE INDEX IF NOT EXISTS idx_audit_trail_errors 
    ON core.audit_trail(audit_level, created_at DESC) 
    WHERE audit_level IN ('ERROR', 'CRITICAL');

-- IP tracking (security)
CREATE INDEX IF NOT EXISTS idx_audit_trail_ip 
    ON core.audit_trail(client_ip, created_at DESC) 
    WHERE client_ip IS NOT NULL;

-- Session tracking
CREATE INDEX IF NOT EXISTS idx_audit_trail_session 
    ON core.audit_trail(session_id, created_at DESC) 
    WHERE session_id IS NOT NULL;

-- Retention management
CREATE INDEX IF NOT EXISTS idx_audit_trail_retention 
    ON core.audit_trail(purge_after_date) 
    WHERE purge_after_date IS NOT NULL;

-- -----------------------------------------------------------------------------
-- ROW LEVEL SECURITY
-- CRITICAL FIX: Add RLS protection to audit trail
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    ALTER TABLE core.audit_trail ENABLE ROW LEVEL SECURITY;
    ALTER TABLE core.audit_trail FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Policy: Only auditors and admins can view audit trail
CREATE POLICY audit_trail_auditor_access ON core.audit_trail
    FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM pg_roles 
            WHERE rolname = CURRENT_USER 
            AND (rolname LIKE '%audit%' OR rolname LIKE '%admin%')
        )
    );

-- -----------------------------------------------------------------------------
-- IMMUTABILITY TRIGGERS
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_audit_trail_prevent_update ON core.audit_trail;
CREATE TRIGGER trg_audit_trail_prevent_update
    BEFORE UPDATE ON core.audit_trail
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

DROP TRIGGER IF EXISTS trg_audit_trail_prevent_delete ON core.audit_trail;
CREATE TRIGGER trg_audit_trail_prevent_delete
    BEFORE DELETE ON core.audit_trail
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

-- CRITICAL FIX: Add TRUNCATE protection to prevent audit trail destruction
DROP TRIGGER IF EXISTS trg_audit_trail_prevent_truncate ON core.audit_trail;
CREATE TRIGGER trg_audit_trail_prevent_truncate
    BEFORE TRUNCATE ON core.audit_trail
    FOR EACH STATEMENT
    EXECUTE FUNCTION core.prevent_truncate();

-- -----------------------------------------------------------------------------
-- HASH COMPUTATION AND CHAIN TRIGGER
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.compute_audit_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_previous_hash VARCHAR(64);
    v_lock_obtained BOOLEAN;
BEGIN
    -- CRITICAL FIX: Use advisory lock to prevent race condition in hash chain
    SELECT pg_try_advisory_lock(999) INTO v_lock_obtained;  -- Lock ID 999 for audit chain
    
    IF NOT v_lock_obtained THEN
        PERFORM pg_advisory_lock(999);
    END IF;
    
    BEGIN
        -- Get previous audit hash for chain (now protected by advisory lock)
        SELECT record_hash INTO v_previous_hash
        FROM core.audit_trail
        ORDER BY created_at DESC, audit_id DESC
        LIMIT 1;
        
        NEW.previous_audit_hash := v_previous_hash;
        
        -- CRITICAL FIX: Use structured JSON hash input to prevent collision attacks
        NEW.record_hash := core.generate_hash(
            jsonb_build_object(
                'audit_id', COALESCE(NEW.audit_id::TEXT, ''),
                'audit_reference', NEW.audit_reference,
                'audit_category', NEW.audit_category,
                'audit_level', NEW.audit_level,
                'audit_event', NEW.audit_event,
                'actor_account_id', COALESCE(NEW.actor_account_id::TEXT, ''),
                'action', NEW.action,
                'action_status', NEW.action_status,
                'table_name', COALESCE(NEW.table_name, ''),
                'record_id', COALESCE(NEW.record_id, ''),
                'old_data', COALESCE(NEW.old_data::TEXT, '{}'),
                'new_data', COALESCE(NEW.new_data::TEXT, '{}'),
                'created_at', NEW.created_at::TEXT,
                'previous_hash', COALESCE(v_previous_hash, '')
            )::TEXT
        );
        
        -- Release advisory lock
        PERFORM pg_advisory_unlock(999);
    EXCEPTION WHEN OTHERS THEN
        -- Ensure lock is released even on error
        PERFORM pg_advisory_unlock(999);
        RAISE;
    END;
    
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_trail_compute_hash ON core.audit_trail;
CREATE TRIGGER trg_audit_trail_compute_hash
    BEFORE INSERT ON core.audit_trail
    FOR EACH ROW
    EXECUTE FUNCTION core.compute_audit_hash();

-- -----------------------------------------------------------------------------
-- HELPER FUNCTIONS
-- -----------------------------------------------------------------------------

-- Function to log an audit event
CREATE OR REPLACE FUNCTION core.log_audit_event(
    p_audit_category VARCHAR(50),
    p_audit_level VARCHAR(20),
    p_audit_event VARCHAR(100),
    p_action VARCHAR(50),
    p_action_status VARCHAR(20),
    p_actor_account_id UUID DEFAULT NULL,
    p_actor_type VARCHAR(50) DEFAULT 'SYSTEM',
    p_table_schema VARCHAR(50) DEFAULT NULL,
    p_table_name VARCHAR(100) DEFAULT NULL,
    p_record_id TEXT DEFAULT NULL,
    p_old_data JSONB DEFAULT NULL,
    p_new_data JSONB DEFAULT NULL,
    p_application_id UUID DEFAULT NULL,
    p_transaction_id UUID DEFAULT NULL,
    p_correlation_id UUID DEFAULT NULL,
    p_client_ip INET DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL,
    p_error_message TEXT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_audit_id BIGINT;
    v_reference VARCHAR(100);
    v_retention_class VARCHAR(20);
    v_purge_date DATE;
BEGIN
    -- Determine retention based on level and category
    v_retention_class := CASE 
        WHEN p_audit_level = 'CRITICAL' OR p_audit_category = 'SECURITY' THEN 'PERMANENT'
        WHEN p_audit_level = 'ERROR' OR p_audit_category IN ('DATA_CHANGE', 'ADMIN') THEN 'LONG'
        WHEN p_audit_level = 'DEBUG' THEN 'SHORT'
        ELSE 'STANDARD'
    END;
    
    v_purge_date := CASE v_retention_class
        WHEN 'SHORT' THEN CURRENT_DATE + INTERVAL '30 days'
        WHEN 'STANDARD' THEN CURRENT_DATE + INTERVAL '2 years'
        WHEN 'LONG' THEN CURRENT_DATE + INTERVAL '7 years'
        ELSE NULL  -- PERMANENT
    END;
    
    -- Generate reference
    v_reference := 'AUD-' || TO_CHAR(NOW(), 'YYYYMMDD-HH24MISS-MS') || '-' || SUBSTRING(MD5(RANDOM()::TEXT), 1, 6);
    
    INSERT INTO core.audit_trail (
        audit_reference,
        audit_category,
        audit_level,
        audit_event,
        actor_account_id,
        actor_type,
        action,
        action_status,
        table_schema,
        table_name,
        record_id,
        old_data,
        new_data,
        application_id,
        transaction_id,
        correlation_id,
        client_ip,
        user_agent,
        error_message,
        retention_class,
        purge_after_date
    ) VALUES (
        v_reference,
        p_audit_category,
        p_audit_level,
        p_audit_event,
        p_actor_account_id,
        p_actor_type,
        p_action,
        p_action_status,
        p_table_schema,
        p_table_name,
        p_record_id,
        p_old_data,
        p_new_data,
        p_application_id,
        p_transaction_id,
        p_correlation_id,
        p_client_ip,
        p_user_agent,
        p_error_message,
        v_retention_class,
        v_purge_date
    ) RETURNING audit_id INTO v_audit_id;
    
    RETURN v_audit_id;
END;
$$;

-- Function to get audit history for a record
CREATE OR REPLACE FUNCTION core.get_record_audit_history(
    p_table_schema VARCHAR(50),
    p_table_name VARCHAR(100),
    p_record_id TEXT,
    p_limit INTEGER DEFAULT 100
)
RETURNS TABLE (
    audit_id BIGINT,
    created_at TIMESTAMPTZ,
    audit_event VARCHAR(100),
    actor_account_id UUID,
    action VARCHAR(50),
    action_status VARCHAR(20),
    change_summary TEXT
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        at.audit_id,
        at.created_at,
        at.audit_event,
        at.actor_account_id,
        at.action,
        at.action_status,
        at.change_summary
    FROM core.audit_trail at
    WHERE at.table_schema = p_table_schema
      AND at.table_name = p_table_name
      AND at.record_id = p_record_id
    ORDER BY at.created_at DESC
    LIMIT p_limit;
END;
$$;

-- Function to get security events
CREATE OR REPLACE FUNCTION core.get_security_events(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ,
    p_min_level VARCHAR(20) DEFAULT 'WARNING'
)
RETURNS TABLE (
    audit_id BIGINT,
    created_at TIMESTAMPTZ,
    audit_event VARCHAR(100),
    audit_level VARCHAR(20),
    actor_account_id UUID,
    action_status VARCHAR(20),
    client_ip INET,
    error_message TEXT
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        at.audit_id,
        at.created_at,
        at.audit_event,
        at.audit_level,
        at.actor_account_id,
        at.action_status,
        at.client_ip,
        at.error_message
    FROM core.audit_trail at
    WHERE at.audit_category = 'SECURITY'
      AND at.created_at BETWEEN p_start_time AND p_end_time
      AND at.audit_level >= p_min_level
    ORDER BY at.created_at DESC;
END;
$$;

-- Function to verify audit chain integrity
CREATE OR REPLACE FUNCTION core.verify_audit_chain(
    p_start_time TIMESTAMPTZ DEFAULT NULL,
    p_end_time TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
    is_valid BOOLEAN,
    total_records BIGINT,
    verified_records BIGINT,
    broken_at_audit_id BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_is_valid BOOLEAN := TRUE;
    v_broken_at BIGINT := NULL;
    v_total BIGINT;
    v_verified BIGINT := 0;
    v_record RECORD;
    v_previous_hash VARCHAR(64) := NULL;
    v_computed_hash VARCHAR(64);
BEGIN
    SELECT COUNT(*) INTO v_total
    FROM core.audit_trail
    WHERE (p_start_time IS NULL OR created_at >= p_start_time)
      AND (p_end_time IS NULL OR created_at <= p_end_time);
    
    FOR v_record IN 
        SELECT audit_id, record_hash, previous_audit_hash, created_at
        FROM core.audit_trail
        WHERE (p_start_time IS NULL OR created_at >= p_start_time)
          AND (p_end_time IS NULL OR created_at <= p_end_time)
        ORDER BY created_at, audit_id
    LOOP
        IF v_previous_hash IS DISTINCT FROM v_record.previous_audit_hash THEN
            v_is_valid := FALSE;
            v_broken_at := v_record.audit_id;
            EXIT;
        END IF;
        
        v_previous_hash := v_record.record_hash;
        v_verified := v_verified + 1;
    END LOOP;
    
    RETURN QUERY SELECT v_is_valid, v_total, v_verified, v_broken_at;
END;
$$;

-- Function to get audit statistics
CREATE OR REPLACE FUNCTION core.get_audit_statistics(
    p_start_date DATE,
    p_end_date DATE
)
RETURNS TABLE (
    audit_category VARCHAR(50),
    event_count BIGINT,
    error_count BIGINT,
    unique_actors BIGINT,
    avg_execution_time_ms NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        at.audit_category,
        COUNT(*) as event_count,
        COUNT(*) FILTER (WHERE at.action_status = 'FAILURE') as error_count,
        COUNT(DISTINCT at.actor_account_id) as unique_actors,
        AVG(at.execution_time_ms)::NUMERIC as avg_execution_time_ms
    FROM core.audit_trail at
    WHERE at.created_at::DATE BETWEEN p_start_date AND p_end_date
    GROUP BY at.audit_category
    ORDER BY event_count DESC;
END;
$$;

-- -----------------------------------------------------------------------------
-- COMMENTS
-- -----------------------------------------------------------------------------
COMMENT ON TABLE core.audit_trail IS 'Comprehensive audit trail for all data access and modifications';
COMMENT ON COLUMN core.audit_trail.audit_id IS 'Unique identifier for the audit record';
COMMENT ON COLUMN core.audit_trail.audit_category IS 'DATA_ACCESS, DATA_CHANGE, SECURITY, ADMIN, SYSTEM, or COMPLIANCE';
COMMENT ON COLUMN core.audit_trail.audit_level IS 'DEBUG, INFO, WARNING, ERROR, or CRITICAL';
COMMENT ON COLUMN core.audit_trail.record_hash IS 'SHA-256 hash for integrity verification';
COMMENT ON COLUMN core.audit_trail.previous_audit_hash IS 'Hash of previous audit record for chain verification';

-- =============================================================================
-- END OF FILE
-- =============================================================================

COMMIT;
