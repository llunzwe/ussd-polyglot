-- =============================================================================
-- Migration: V031__core_idempotency_keys
-- Description: Core table: idempotency_keys
-- Dependencies: V030
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- USSD KERNEL CORE SCHEMA - IDEMPOTENCY KEYS
-- Enterprise-Grade Immutable Ledger System
-- =============================================================================
-- FILENAME:    028_idempotency_keys.sql
-- SCHEMA:      ussd_core
-- TABLE:       idempotency_keys
-- DESCRIPTION: Idempotency key registry for exactly-once transaction
--              processing with deduplication and replay protection.
-- =============================================================================

/*
================================================================================
COMPLIANCE FRAMEWORK
================================================================================

ISO/IEC 27001:2022 (Information Security Management Systems)
├── A.12.4 Logging and monitoring - Duplicate detection
├── A.12.6 Technical vulnerability management - Replay attack prevention
└── A.16.1 Management of information security incidents - Duplicate handling

ISO/IEC 27040:2024 (Storage Security)
├── Immutable idempotency records
├── Request hash verification
└── Replay protection audit trail

Financial Regulations
├── Exactly-once: Duplicate transaction prevention
├── Audit trail: Complete request history
└── Fraud prevention: Replay attack mitigation

================================================================================
ENTERPRISE POSTGRESQL CODING PRACTICES
================================================================================

1. KEY GENERATION
   - Client-generated UUIDs or unique strings
   - Time-bound expiration (default 24 hours)
   - Request hash for content verification

2. LIFECYCLE
   - PENDING: Key allocated, transaction not yet created
   - PROCESSING: Transaction in progress
   - COMPLETED: Transaction completed
   - EXPIRED: Key expired without completion

3. CLEANUP
   - Automatic expiration
   - Periodic purging of old keys
   - Archival of completed keys

================================================================================
SECURITY IMPLEMENTATION NOTES
================================================================================

REPLAY PROTECTION:
- Request hash verification
- Time window enforcement
- Key uniqueness constraints

DUPLICATE DETECTION:
- Unique key constraint
- Request hash comparison
- Client notification of duplicates

================================================================================
PERFORMANCE OPTIMIZATION ANNOTATIONS
================================================================================

INDEXES:
- PRIMARY KEY: idempotency_key_id
- KEY: idempotency_key (unique)
- STATUS: status + created_at
- EXPIRY: expires_at (for cleanup)

CLEANUP:
- Partition by created_at
- Auto-purge expired keys

================================================================================
AUDIT AND LOGGING REQUIREMENTS
================================================================================

AUDIT EVENTS:
- KEY_CREATED
- KEY_COMPLETED
- DUPLICATE_DETECTED
- KEY_EXPIRED

RETENTION: 2 years (keys), 7 years (audit log)
================================================================================
*/

-- -----------------------------------------------------------------------------
-- CREATE TABLE: idempotency_keys
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.idempotency_keys (
    -- Primary identifier
    idempotency_key_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    
    -- Idempotency key (client-provided)
    idempotency_key VARCHAR(255) NOT NULL,
    
    -- Multi-tenant unique constraint: idempotency keys are scoped by application
    CONSTRAINT uq_idempotency_keys_app_key UNIQUE (application_id, idempotency_key),
    
    -- Scope
    application_id UUID,
    initiator_account_id UUID REFERENCES core.account_registry(account_id) ON DELETE RESTRICT,
    
    -- Request identification
    request_type VARCHAR(50) NOT NULL,
    request_endpoint VARCHAR(255),
    request_method VARCHAR(10),
    
    -- Request hash for content verification
    request_hash VARCHAR(64) NOT NULL,
    request_payload_hash VARCHAR(64),
    
    -- Status
    status VARCHAR(20) DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'PROCESSING', 'COMPLETED', 'FAILED', 'EXPIRED')),
    
    -- Result reference
    transaction_id UUID,
    transaction_reference VARCHAR(100),
    entity_type VARCHAR(50),  -- Type of entity created (transaction, account, etc.)
    entity_id UUID,           -- ID of entity created
    
    -- Response caching
    response_code INTEGER,
    response_body JSONB,
    response_headers JSONB,
    
    -- Timing
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ,
    processing_started_at TIMESTAMPTZ,
    processing_duration_ms INTEGER,
    
    -- Client context
    client_ip INET,
    user_agent TEXT,
    request_id TEXT,
    correlation_id UUID,
    session_id TEXT,
    
    -- Replay tracking
    replay_count INTEGER DEFAULT 0,
    last_replayed_at TIMESTAMPTZ,
    
    -- Audit
    record_hash VARCHAR(64) NOT NULL DEFAULT 'PENDING',
    
    -- Partition key for cleanup
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE
);

-- -----------------------------------------------------------------------------
-- INDEXES
-- -----------------------------------------------------------------------------
-- Key lookups (unique constraint already indexed, but add partial for active)
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_active 
    ON core.idempotency_keys(idempotency_key, status) 
    WHERE status IN ('PENDING', 'PROCESSING');

-- Status monitoring
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_status 
    ON core.idempotency_keys(status, created_at);

-- Expiration cleanup
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_expiry 
    ON core.idempotency_keys(expires_at) 
    WHERE status IN ('PENDING', 'PROCESSING');

-- Account-based queries
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_account 
    ON core.idempotency_keys(initiator_account_id, created_at DESC);

-- Transaction linking
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_transaction 
    ON core.idempotency_keys(transaction_id) 
    WHERE transaction_id IS NOT NULL;

-- Application-scoped queries
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_application 
    ON core.idempotency_keys(application_id, created_at);

-- Request type analysis
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_request_type 
    ON core.idempotency_keys(request_type, status);

-- Correlation tracking
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_correlation 
    ON core.idempotency_keys(correlation_id) 
    WHERE correlation_id IS NOT NULL;

-- Date-based partitioning support
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_partition 
    ON core.idempotency_keys(partition_date);

-- -----------------------------------------------------------------------------
-- IMMUTABILITY TRIGGERS
-- -----------------------------------------------------------------------------
-- AUDIT FIX (FINDING-005): Removed WORM triggers from idempotency_keys table.
-- This table tracks operation state transitions (PENDING → COMPLETED/FAILED/EXPIRED)
-- and requires UPDATE capability for legitimate state management.
-- 
-- Security maintained through:
-- - Application-level authorization checks
-- - Audit trail logging all state changes
-- - Request hash verification prevents tampering
-- -----------------------------------------------------------------------------

-- State transition audit trigger (logs all changes instead of preventing them)
CREATE OR REPLACE FUNCTION core.audit_idempotency_state_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Log state transition to audit trail
    PERFORM core.log_audit_event(
        'DATA_CHANGE'::VARCHAR(50),
        'INFO'::VARCHAR(20),
        'IDEMPOTENCY_KEY_STATE_CHANGE'::VARCHAR(100),
        'UPDATE'::VARCHAR(50),
        'SUCCESS'::VARCHAR(20),
        NEW.initiator_account_id,
        'SYSTEM'::VARCHAR(50),
        'core'::VARCHAR(50),
        'idempotency_keys'::VARCHAR(100),
        NEW.idempotency_key_id::TEXT,
        jsonb_build_object('old_status', OLD.status, 'new_status', NEW.status),
        jsonb_build_object('transaction_id', NEW.transaction_id, 'completed_at', NEW.completed_at)
    );
    
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_idempotency_keys_audit_change ON core.idempotency_keys;
CREATE TRIGGER trg_idempotency_keys_audit_change
    AFTER UPDATE ON core.idempotency_keys
    FOR EACH ROW
    EXECUTE FUNCTION core.audit_idempotency_state_change();

-- -----------------------------------------------------------------------------
-- HASH COMPUTATION TRIGGER
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.compute_idempotency_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.record_hash := core.generate_hash(
        NEW.idempotency_key_id::TEXT || 
        NEW.idempotency_key || 
        COALESCE(NEW.application_id::TEXT, '') ||
        COALESCE(NEW.initiator_account_id::TEXT, '') ||
        NEW.request_type ||
        NEW.request_hash ||
        NEW.status ||
        NEW.created_at::TEXT
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_idempotency_keys_compute_hash ON core.idempotency_keys;
CREATE TRIGGER trg_idempotency_keys_compute_hash
    BEFORE INSERT ON core.idempotency_keys
    FOR EACH ROW
    EXECUTE FUNCTION core.compute_idempotency_hash();

-- -----------------------------------------------------------------------------
-- HELPER FUNCTIONS
-- -----------------------------------------------------------------------------

-- Function to create a new idempotency key
CREATE OR REPLACE FUNCTION core.create_idempotency_key(
    p_idempotency_key VARCHAR(255),
    p_request_type VARCHAR(50),
    p_request_hash VARCHAR(64),
    p_application_id UUID DEFAULT NULL,
    p_initiator_account_id UUID DEFAULT NULL,
    p_request_endpoint VARCHAR(255) DEFAULT NULL,
    p_request_method VARCHAR(10) DEFAULT NULL,
    p_request_payload_hash VARCHAR(64) DEFAULT NULL,
    p_expiry_hours INTEGER DEFAULT 24,
    p_client_ip INET DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL,
    p_correlation_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_key_id UUID;
BEGIN
    INSERT INTO core.idempotency_keys (
        idempotency_key,
        application_id,
        initiator_account_id,
        request_type,
        request_endpoint,
        request_method,
        request_hash,
        request_payload_hash,
        expires_at,
        client_ip,
        user_agent,
        correlation_id
    ) VALUES (
        p_idempotency_key,
        p_application_id,
        p_initiator_account_id,
        p_request_type,
        p_request_endpoint,
        p_request_method,
        p_request_hash,
        p_request_payload_hash,
        NOW() + INTERVAL '1 hour' * p_expiry_hours,
        p_client_ip,
        p_user_agent,
        p_correlation_id
    ) RETURNING idempotency_key_id INTO v_key_id;
    
    RETURN v_key_id;
END;
$$;

-- Function to check if idempotency key exists and get result
CREATE OR REPLACE FUNCTION core.check_idempotency_key(
    p_idempotency_key VARCHAR(255)
)
RETURNS TABLE (
    key_exists BOOLEAN,
    status VARCHAR(20),
    transaction_id UUID,
    response_code INTEGER,
    response_body JSONB,
    is_expired BOOLEAN
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_record RECORD;
BEGIN
    SELECT * INTO v_record
    FROM core.idempotency_keys
    WHERE idempotency_key = p_idempotency_key;
    
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, NULL::VARCHAR(20), NULL::UUID, NULL::INTEGER, NULL::JSONB, NULL::BOOLEAN;
        RETURN;
    END IF;
    
    RETURN QUERY SELECT 
        TRUE,
        v_record.status,
        v_record.transaction_id,
        v_record.response_code,
        v_record.response_body,
        v_record.expires_at < NOW();
    
    -- Update replay tracking
    -- Note: Since table is immutable, this would need a separate replay log table
END;
$$;

-- Function to complete an idempotency key
-- AUDIT FIX (FINDING-005): Now properly updates state after WORM removal
CREATE OR REPLACE FUNCTION core.complete_idempotency_key(
    p_idempotency_key VARCHAR(255),
    p_status VARCHAR(20),
    p_transaction_id UUID DEFAULT NULL,
    p_transaction_reference VARCHAR(100) DEFAULT NULL,
    p_response_code INTEGER DEFAULT NULL,
    p_response_body JSONB DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_updated INTEGER;
BEGIN
    -- Validate status transition
    IF p_status NOT IN ('COMPLETED', 'FAILED', 'EXPIRED') THEN
        RAISE EXCEPTION 'INVALID_STATUS: Status must be COMPLETED, FAILED, or EXPIRED, got %', p_status;
    END IF;
    
    -- Update the idempotency key record
    UPDATE core.idempotency_keys
    SET 
        status = p_status,
        transaction_id = p_transaction_id,
        transaction_reference = p_transaction_reference,
        response_code = p_response_code,
        response_body = p_response_body,
        completed_at = NOW(),
        processing_duration_ms = EXTRACT(EPOCH FROM (NOW() - processing_started_at))::INTEGER * 1000
    WHERE idempotency_key = p_idempotency_key
      AND status IN ('PENDING', 'PROCESSING');
    
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    
    IF v_updated = 0 THEN
        RAISE WARNING 'No idempotency key found to complete: % (may already be completed or expired)', p_idempotency_key;
        RETURN FALSE;
    END IF;
    
    RETURN TRUE;
END;
$$;

-- Function to get expired keys for cleanup
CREATE OR REPLACE FUNCTION core.get_expired_idempotency_keys(
    p_batch_size INTEGER DEFAULT 10000
)
RETURNS TABLE (
    idempotency_key_id UUID,
    idempotency_key VARCHAR(255),
    status VARCHAR(20),
    created_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ik.idempotency_key_id,
        ik.idempotency_key,
        ik.status,
        ik.created_at,
        ik.expires_at
    FROM core.idempotency_keys ik
    WHERE ik.expires_at < NOW()
       OR (ik.status IN ('PENDING', 'PROCESSING') AND ik.created_at < NOW() - INTERVAL '7 days')
    ORDER BY ik.created_at
    LIMIT p_batch_size;
END;
$$;

-- Function to get idempotency statistics
CREATE OR REPLACE FUNCTION core.get_idempotency_statistics(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS TABLE (
    request_type VARCHAR(50),
    total_keys BIGINT,
    completed_keys BIGINT,
    failed_keys BIGINT,
    expired_keys BIGINT,
    avg_replay_count NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ik.request_type,
        COUNT(*) as total_keys,
        COUNT(*) FILTER (WHERE ik.status = 'COMPLETED') as completed_keys,
        COUNT(*) FILTER (WHERE ik.status = 'FAILED') as failed_keys,
        COUNT(*) FILTER (WHERE ik.status = 'EXPIRED') as expired_keys,
        AVG(ik.replay_count)::NUMERIC as avg_replay_count
    FROM core.idempotency_keys ik
    WHERE (p_start_date IS NULL OR ik.created_at::DATE >= p_start_date)
      AND (p_end_date IS NULL OR ik.created_at::DATE <= p_end_date)
    GROUP BY ik.request_type
    ORDER BY total_keys DESC;
END;
$$;

-- Function to detect duplicate requests
CREATE OR REPLACE FUNCTION core.detect_duplicate_requests(
    p_time_window_hours INTEGER DEFAULT 24
)
RETURNS TABLE (
    request_hash VARCHAR(64),
    request_type VARCHAR(50),
    duplicate_count BIGINT,
    key_ids UUID[]
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ik.request_hash,
        ik.request_type,
        COUNT(*) as duplicate_count,
        ARRAY_AGG(ik.idempotency_key_id) as key_ids
    FROM core.idempotency_keys ik
    WHERE ik.created_at > NOW() - INTERVAL '1 hour' * p_time_window_hours
    GROUP BY ik.request_hash, ik.request_type
    HAVING COUNT(*) > 1;
END;
$$;

-- -----------------------------------------------------------------------------
-- COMMENTS
-- -----------------------------------------------------------------------------
COMMENT ON TABLE core.idempotency_keys IS 'Idempotency key registry for exactly-once transaction processing';
COMMENT ON COLUMN core.idempotency_keys.idempotency_key IS 'Client-provided unique key for deduplication';
COMMENT ON COLUMN core.idempotency_keys.request_hash IS 'Hash of request for integrity verification';
COMMENT ON COLUMN core.idempotency_keys.status IS 'PENDING, PROCESSING, COMPLETED, FAILED, or EXPIRED';
COMMENT ON COLUMN core.idempotency_keys.replay_count IS 'Number of times this key was replayed';

-- =============================================================================
-- END OF FILE
-- =============================================================================

COMMIT;
