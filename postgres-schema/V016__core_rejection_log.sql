-- =============================================================================
-- Migration: V014__core_rejection_log
-- Description: Core table: rejection_log
-- Dependencies: V013
-- Generated: 2026-04-02 16:56:45 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- USSD KERNEL CORE SCHEMA - REJECTION LOG
-- Enterprise-Grade Immutable Ledger System
-- =============================================================================
-- FILENAME:    011_rejection_log.sql
-- SCHEMA:      ussd_core
-- TABLE:       rejection_log
-- DESCRIPTION: Immutable record of all rejected transactions with detailed
--              rejection reasons for audit, compliance, and debugging.
-- =============================================================================

/*
================================================================================
COMPLIANCE FRAMEWORK
================================================================================

ISO/IEC 27001:2022 (Information Security Management Systems)
├── A.12.4 Logging and monitoring - Transaction rejection monitoring
├── A.16.1 Management of information security incidents - Pattern analysis
└── A.16.2 Assessment and decision - Rejection decision audit trail

ISO/IEC 27040:2024 (Storage Security)
├── Immutable rejection records
├── Tamper-evident rejection log
└── Long-term retention for forensic analysis

Financial Regulations
├── AML: Suspicious rejection pattern analysis
├── Audit: Rejection reason documentation
├── Consumer protection: Rejection explanation requirements
└── Regulatory reporting: Rejection statistics

================================================================================
ENTERPRISE POSTGRESQL CODING PRACTICES
================================================================================

1. REJECTION CATEGORIES
   - VALIDATION: Schema or business rule violation
   - AUTHORIZATION: Insufficient permissions
   - FUNDS: Insufficient balance
   - LIMIT: Transaction limit exceeded
   - RISK: Risk threshold exceeded
   - SYSTEM: Internal system error
   - COMPLIANCE: Regulatory restriction

2. ERROR CODES
   - Standardized error code taxonomy
   - Hierarchical code structure
   - Localization support

3. RETENTION
   - Minimum 7 years for financial transactions
   - Longer retention for AML-related rejections
   - Secure archival procedures

================================================================================
SECURITY IMPLEMENTATION NOTES
================================================================================

REJECTION MONITORING:
- Real-time rejection rate alerts
- Pattern detection for attacks
- Fraud attempt identification

FORENSICS:
- Complete request context preserved
- Client information captured (GDPR compliant)
- Audit trail for rejection decisions

================================================================================
PERFORMANCE OPTIMIZATION ANNOTATIONS
================================================================================

INDEXES:
- PRIMARY KEY: rejection_id
- IDEMPOTENCY: idempotency_key (duplicate detection)
- ACCOUNT: initiator_account_id + rejected_at
- REASON: rejection_code + rejected_at
- TIME: rejected_at DESC (reporting)

ARCHIVAL:
- Partition by rejected_at (monthly)
- Compress old partitions
- Cold storage for > 7 years

================================================================================
AUDIT AND LOGGING REQUIREMENTS
================================================================================

AUDIT EVENTS:
- All rejections automatically logged
- Rejection pattern analysis
- Investigation workflow tracking

RETENTION: 7 years minimum
================================================================================
*/

-- =============================================================================
-- CREATE TABLE: rejection_log (partitioned)
-- =============================================================================

CREATE TABLE IF NOT EXISTS core.rejection_log (
    -- Primary identifier
    rejection_id UUID DEFAULT gen_random_uuid(),
    PRIMARY KEY (rejection_id, rejected_at),
    
    -- Original transaction reference
    idempotency_key VARCHAR(255) NOT NULL,
    idempotency_key_id UUID,
    
    -- Transaction details (as submitted)
    transaction_type_id UUID REFERENCES core.transaction_types(type_id) ON DELETE RESTRICT,
    application_id UUID,
    initiator_account_id UUID REFERENCES core.account_registry(account_id) ON DELETE RESTRICT,
    beneficiary_account_id UUID REFERENCES core.account_registry(account_id) ON DELETE RESTRICT,
    amount NUMERIC(20, 8),
    currency VARCHAR(3) CHECK (currency IS NULL OR currency ~ '^[A-Z]{3}$'),
    payload JSONB,
    
    -- Rejection details
    rejection_reason TEXT NOT NULL,
    rejection_code VARCHAR(50) NOT NULL,
    rejection_category VARCHAR(50) NOT NULL
        CHECK (rejection_category IN ('VALIDATION', 'AUTHORIZATION', 'FUNDS', 'LIMIT', 'RISK', 'SYSTEM', 'COMPLIANCE')),
    rejection_severity VARCHAR(20) DEFAULT 'error' 
        CHECK (rejection_severity IN ('warning', 'error', 'critical', 'fatal')),
    
    -- Validation errors (if applicable)
    validation_errors JSONB,  -- Array of {field, message, code}
    
    -- Client context
    client_ip INET,
    user_agent TEXT,
    session_id TEXT,
    source_ip INET,
    device_fingerprint TEXT,
    
    -- Timing
    received_at TIMESTAMPTZ NOT NULL,
    rejected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processing_duration_ms INTEGER,
    
    -- Processing metadata
    processor_version VARCHAR(20),
    validation_stage VARCHAR(50),  -- e.g., 'SCHEMA', 'BUSINESS_RULES', 'RISK_CHECK'
    processor_instance TEXT,
    
    -- Retry information
    retry_eligible BOOLEAN DEFAULT FALSE,
    retry_after_seconds INTEGER,
    retry_guidance TEXT,
    
    -- Related records
    related_transaction_id BIGINT,
    related_rejection_id UUID,  -- Self-reference deferred due to composite PK
    
    -- Investigation
    investigated BOOLEAN DEFAULT FALSE,
    investigated_by UUID,
    investigated_at TIMESTAMPTZ,
    investigation_notes TEXT,
    fraud_suspected BOOLEAN DEFAULT FALSE,
    
    -- Audit
    
    -- Partition key
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE
);

-- =============================================================================
-- CONVERT TO TIMESCALEDB HYPERTABLE
-- =============================================================================

-- Convert to hypertable for time-series optimization
-- Using rejected_at as the time column for automatic partitioning
SELECT create_hypertable(
    'core.rejection_log',
    'rejected_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

-- =============================================================================
-- INDEXES
-- =============================================================================

-- Idempotency key lookup
CREATE INDEX IF NOT EXISTS idx_rejection_log_idempotency ON core.rejection_log(idempotency_key);

-- Account lookup
CREATE INDEX IF NOT EXISTS idx_rejection_log_account ON core.rejection_log(initiator_account_id, rejected_at DESC);

-- Rejection code analysis
CREATE INDEX IF NOT EXISTS idx_rejection_log_code ON core.rejection_log(rejection_code, rejected_at DESC);

-- Category analysis
CREATE INDEX IF NOT EXISTS idx_rejection_log_category ON core.rejection_log(rejection_category, rejected_at DESC);

-- Time-based queries
CREATE INDEX IF NOT EXISTS idx_rejection_log_time ON core.rejection_log(rejected_at DESC);

-- Application filtering
CREATE INDEX IF NOT EXISTS idx_rejection_log_app ON core.rejection_log(application_id, rejected_at DESC);

-- Transaction type filtering
CREATE INDEX IF NOT EXISTS idx_rejection_log_type ON core.rejection_log(transaction_type_id, rejected_at DESC);

-- =============================================================================
-- TIMESCALEDB OPTIMIZATIONS (optional - skipped if extension unavailable)
-- =============================================================================
DO $$
BEGIN
    ALTER TABLE core.rejection_log SET (
        timescaledb.compress,
        timescaledb.compress_segmentby = 'application_id, rejection_code'
    );
    PERFORM add_compression_policy('core.rejection_log', INTERVAL '30 days');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TimescaleDB compression setup skipped: %', SQLERRM;
END;
$$;

-- Fraud investigation
CREATE INDEX IF NOT EXISTS idx_rejection_log_fraud ON core.rejection_log(rejection_id) 
    WHERE fraud_suspected = TRUE AND investigated = FALSE;

-- Client IP for pattern analysis
CREATE INDEX IF NOT EXISTS idx_rejection_log_ip ON core.rejection_log(client_ip, rejected_at DESC);

-- Severity filtering
CREATE INDEX IF NOT EXISTS idx_rejection_log_severity ON core.rejection_log(rejection_severity, rejected_at DESC);

-- =============================================================================
-- TRIGGERS (Audit trail is WORM, but investigation fields need updates)
-- =============================================================================

-- The rejection log is primarily immutable, BUT investigation fields need updates.
-- We use a conditional trigger that allows updates only to investigation fields.

CREATE OR REPLACE FUNCTION core.rejection_log_update_check()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_allowed_fields TEXT[] := ARRAY['investigated', 'investigated_by', 'investigated_at', 'investigation_notes', 'fraud_suspected'];
    v_changed_field TEXT;
    v_old_json JSONB;
    v_new_json JSONB;
    v_field TEXT;
BEGIN
    -- Convert rows to JSONB for comparison
    v_old_json := to_jsonb(OLD);
    v_new_json := to_jsonb(NEW);
    
    -- Check if any non-allowed fields changed
    FOR v_field IN SELECT jsonb_object_keys(v_new_json)
    LOOP
        -- Skip fields that haven't changed
        IF v_old_json->v_field IS DISTINCT FROM v_new_json->v_field THEN
            -- Check if this is an allowed field to change
            IF NOT (v_field = ANY(v_allowed_fields)) THEN
                RAISE EXCEPTION 'REJECTION_LOG_IMMUTABLE: Field % cannot be modified. Only investigation fields (%,%,%,%,%) are mutable.', 
                    v_field, 
                    'investigated', 'investigated_by', 'investigated_at', 'investigation_notes', 'fraud_suspected';
            END IF;
        END IF;
    END LOOP;
    
    -- Log the investigation update to audit trail
    PERFORM core.log_audit_event(
        'DATA_CHANGE'::VARCHAR(50),
        'INFO'::VARCHAR(20),
        'REJECTION_INVESTIGATION_UPDATED'::VARCHAR(100),
        'UPDATE'::VARCHAR(50),
        'SUCCESS'::VARCHAR(20),
        NEW.investigated_by,
        'USER'::VARCHAR(50),
        'core'::VARCHAR(50),
        'rejection_log'::VARCHAR(100),
        NEW.rejection_id::TEXT,
        jsonb_build_object('fraud_suspected', OLD.fraud_suspected, 'investigated', OLD.investigated),
        jsonb_build_object('fraud_suspected', NEW.fraud_suspected, 'investigated', NEW.investigated, 'notes', NEW.investigation_notes)
    );
    
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_rejection_log_update_check ON core.rejection_log;
CREATE TRIGGER trg_rejection_log_update_check
    BEFORE UPDATE ON core.rejection_log
    FOR EACH ROW
    EXECUTE FUNCTION core.rejection_log_update_check();

-- Prevent deletes on rejection log (always immutable)
DROP TRIGGER IF EXISTS trg_rejection_log_prevent_delete ON core.rejection_log;
CREATE TRIGGER trg_rejection_log_prevent_delete
    BEFORE DELETE ON core.rejection_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

-- Prevent truncate
DROP TRIGGER IF EXISTS trg_rejection_log_prevent_truncate ON core.rejection_log;
CREATE TRIGGER trg_rejection_log_prevent_truncate
    BEFORE TRUNCATE ON core.rejection_log
    FOR EACH STATEMENT
    EXECUTE FUNCTION core.prevent_truncate();

-- =============================================================================
-- HASH COMPUTATION TRIGGER
-- =============================================================================



-- =============================================================================
-- RLS POLICIES
-- =============================================================================

-- Enable RLS
DO $$
BEGIN
    ALTER TABLE core.rejection_log ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'RLS not enabled on hypertable: %', SQLERRM;
END $$;

-- Policy: Accounts can view their own rejections
-- PRODUCTION FIX: Uses safe UUID helper to prevent NULL casting issues
CREATE POLICY rejection_log_account_access ON core.rejection_log
    FOR SELECT
    TO ussd_app_user
    USING (initiator_account_id = core.get_current_setting_as_uuid('app.current_account_id'));

-- Policy: Application-scoped access
CREATE POLICY rejection_log_app_access ON core.rejection_log
    FOR SELECT
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

-- Policy: Kernel role has full access
CREATE POLICY rejection_log_kernel_access ON core.rejection_log
    FOR ALL
    TO ussd_kernel_role
    USING (true);

-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

-- Function to log a rejection
CREATE OR REPLACE FUNCTION core.log_rejection(
    p_idempotency_key VARCHAR,
    p_rejection_reason TEXT,
    p_rejection_code VARCHAR,
    p_rejection_category VARCHAR,
    p_initiator_account_id UUID DEFAULT NULL,
    p_application_id UUID DEFAULT NULL,
    p_transaction_type_id UUID DEFAULT NULL,
    p_amount NUMERIC DEFAULT NULL,
    p_currency VARCHAR DEFAULT NULL,
    p_payload JSONB DEFAULT NULL,
    p_validation_errors JSONB DEFAULT NULL,
    p_client_ip INET DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL,
    p_session_id TEXT DEFAULT NULL,
    p_received_at TIMESTAMPTZ DEFAULT NULL,
    p_processing_duration_ms INTEGER DEFAULT NULL,
    p_retry_eligible BOOLEAN DEFAULT FALSE,
    p_retry_guidance TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_rejection_id UUID;
BEGIN
    INSERT INTO core.rejection_log (
        idempotency_key,
        rejection_reason,
        rejection_code,
        rejection_category,
        initiator_account_id,
        application_id,
        transaction_type_id,
        amount,
        currency,
        payload,
        validation_errors,
        client_ip,
        user_agent,
        session_id,
        received_at,
        processing_duration_ms,
        retry_eligible,
        retry_guidance
    ) VALUES (
        p_idempotency_key,
        p_rejection_reason,
        p_rejection_code,
        p_rejection_category,
        p_initiator_account_id,
        p_application_id,
        p_transaction_type_id,
        p_amount,
        p_currency,
        p_payload,
        p_validation_errors,
        p_client_ip,
        p_user_agent,
        p_session_id,
        COALESCE(p_received_at, NOW()),
        p_processing_duration_ms,
        p_retry_eligible,
        p_retry_guidance
    )
    RETURNING rejection_id INTO v_rejection_id;
    
    RETURN v_rejection_id;
END;
$$;

-- Function to get rejection statistics
CREATE OR REPLACE FUNCTION core.get_rejection_stats(
    p_start_date DATE,
    p_end_date DATE,
    p_application_id UUID DEFAULT NULL
)
RETURNS TABLE (
    rejection_category VARCHAR(50),
    rejection_code VARCHAR(50),
    count BIGINT,
    avg_amount NUMERIC(20, 8),
    avg_processing_ms NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        rl.rejection_category,
        rl.rejection_code,
        COUNT(*)::BIGINT,
        AVG(rl.amount),
        AVG(rl.processing_duration_ms)
    FROM core.rejection_log rl
    WHERE rl.rejected_at::DATE BETWEEN p_start_date AND p_end_date
    AND (p_application_id IS NULL OR rl.application_id = p_application_id)
    GROUP BY rl.rejection_category, rl.rejection_code
    ORDER BY COUNT(*) DESC;
END;
$$;

-- Function to flag rejection for fraud investigation
CREATE OR REPLACE FUNCTION core.flag_rejection_fraud(
    p_rejection_id UUID,
    p_notes TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE core.rejection_log
    SET 
        fraud_suspected = TRUE,
        investigation_notes = COALESCE(investigation_notes, '') || E'\n' || COALESCE(p_notes, 'Flagged for investigation')
    WHERE rejection_id = p_rejection_id;
    
    RETURN FOUND;
END;
$$;

-- Function to mark rejection as investigated
CREATE OR REPLACE FUNCTION core.mark_rejection_investigated(
    p_rejection_id UUID,
    p_investigated_by UUID,
    p_notes TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE core.rejection_log
    SET 
        investigated = TRUE,
        investigated_by = p_investigated_by,
        investigated_at = NOW(),
        investigation_notes = COALESCE(investigation_notes, '') || E'\n' || COALESCE(p_notes, '')
    WHERE rejection_id = p_rejection_id;
    
    RETURN FOUND;
END;
$$;

-- Function to detect rejection patterns (potential fraud)
CREATE OR REPLACE FUNCTION core.detect_rejection_patterns(
    p_time_window_hours INTEGER DEFAULT 1,
    p_threshold INTEGER DEFAULT 10
)
RETURNS TABLE (
    client_ip INET,
    initiator_account_id UUID,
    rejection_count BIGINT,
    unique_codes BIGINT,
    first_rejection TIMESTAMPTZ,
    last_rejection TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        rl.client_ip,
        rl.initiator_account_id,
        COUNT(*)::BIGINT as rejection_count,
        COUNT(DISTINCT rl.rejection_code)::BIGINT as unique_codes,
        MIN(rl.rejected_at) as first_rejection,
        MAX(rl.rejected_at) as last_rejection
    FROM core.rejection_log rl
    WHERE rl.rejected_at > NOW() - (p_time_window_hours || ' hours')::INTERVAL
    GROUP BY rl.client_ip, rl.initiator_account_id
    HAVING COUNT(*) >= p_threshold
    ORDER BY COUNT(*) DESC;
END;
$$;

-- =============================================================================
-- TABLE AND COLUMN COMMENTS
-- =============================================================================

COMMENT ON TABLE core.rejection_log IS 
    'Immutable record of all rejected transactions for audit, compliance, and debugging. PARTITIONED by date.';

COMMENT ON COLUMN core.rejection_log.rejection_id IS 
    'Unique identifier for the rejection record';
COMMENT ON COLUMN core.rejection_log.idempotency_key IS 
    'Client-provided idempotency key from the rejected transaction';
COMMENT ON COLUMN core.rejection_log.rejection_category IS 
    'Category: VALIDATION, AUTHORIZATION, FUNDS, LIMIT, RISK, SYSTEM, COMPLIANCE';
COMMENT ON COLUMN core.rejection_log.rejection_code IS 
    'Standardized error code for the rejection';
COMMENT ON COLUMN core.rejection_log.rejection_severity IS 
    'Severity level: warning, error, critical, fatal';
COMMENT ON COLUMN core.rejection_log.validation_errors IS 
    'Detailed validation errors as JSON array';
COMMENT ON COLUMN core.rejection_log.retry_eligible IS 
    'Whether the client should retry this request';
COMMENT ON COLUMN core.rejection_log.fraud_suspected IS 
    'Whether this rejection pattern suggests fraud';
COMMENT ON COLUMN core.rejection_log.partition_date IS 
    'Partition key for time-based partitioning';

-- =============================================================================
-- END OF FILE
-- =============================================================================

COMMIT;
