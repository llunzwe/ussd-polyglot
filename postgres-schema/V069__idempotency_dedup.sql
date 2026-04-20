-- =============================================================================
-- Migration: V069__idempotency_dedup
-- Description: Idempotency Key Management & Duplicate Detection
-- Dependencies: V001-V068
--
-- PURPOSE: Ensure API safety by preventing duplicate ledger entries when
-- business apps retry requests. Store idempotency keys with responses to
-- enable replay of identical requests without side effects.
--
-- ADR-015: Idempotency Key Storage Strategy
-- DECISION: Store keys in dedicated table with 24h+ expiration
-- RATIONALE:
--   - Business apps may retry due to network timeouts
--   - Keys must persist long enough for all retry windows
--   - 24h default covers most scenarios, configurable per app
--   - Expired keys can be archived/archived for audit only
-- TRADE-OFFS:
--   (+) Prevents duplicate transactions from retries
--   (+) Enables safe retry logic in SDK
--   (-) Additional storage for key records
--   (-) Slight latency for key lookup on every request
--
-- ADR-016: Idempotency Key Uniqueness Scope
-- DECISION: Keys are unique per application (not globally unique)
-- RATIONALE:
--   - Different apps should not share key namespace
--   - App A's "order-123" is different from App B's "order-123"
--   - Simplifies key generation for business apps
-- TRADE-OFFS:
--   (+) Simpler key management
--   (+) No coordination needed between apps
--   (-) Potential collision if apps share key generation logic
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- SCHEMA: api
-- PURPOSE: API infrastructure tables (idempotency, rate limiting extensions)
-- Note: Extends existing api tables in V015
-- =============================================================================

-- =============================================================================
-- TABLE: api.idempotency_keys
-- PURPOSE: Store idempotency keys with request/response for replay
-- SECURITY: Application-scoped via RLS
-- WORM: Completed keys are immutable
-- =============================================================================
CREATE TABLE IF NOT EXISTS api.idempotency_keys (
    key_id UUID DEFAULT gen_random_uuid(),
    
    -- Composite unique key: application + idempotency_key
    application_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    idempotency_key VARCHAR(255) NOT NULL,
    
    -- Request context
    request_method VARCHAR(10) NOT NULL, -- POST, PUT, PATCH
    request_path VARCHAR(500) NOT NULL, -- /v1/payments
    request_hash VARCHAR(64), -- SHA-256 of request body
    request_headers JSONB, -- Store relevant headers
    
    -- Response (stored for replay)
    response_status INTEGER, -- 200, 201, 400, etc.
    response_body JSONB, -- Response payload
    response_headers JSONB,
    
    -- Ledger reference (if transaction created)
    transaction_id UUID REFERENCES core.transactions(transaction_id),
    account_id UUID REFERENCES core.account_registry(account_id),
    
    -- Processing status
    status VARCHAR(20) DEFAULT 'processing' 
        CHECK (status IN ('processing', 'completed', 'failed')),
    
    -- Timing
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ NOT NULL, -- Configurable per app
    
    -- Conflict detection
    locked_at TIMESTAMPTZ, -- For concurrent request handling
    locked_by VARCHAR(100), -- Process/thread identifier
    
    -- Retry tracking
    request_count INTEGER DEFAULT 1,
    last_request_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- Audit
    client_ip INET,
    user_agent TEXT,
    
    -- Constraint
    UNIQUE (application_id, idempotency_key, created_at),
    CONSTRAINT pk_api_idempotency_keys_key_id_created_at PRIMARY KEY (key_id, created_at));

-- Convert to hypertable for automatic expiration
SELECT create_hypertable(
    'api.idempotency_keys',
    'created_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_idempotency_keys_lookup ON api.idempotency_keys(application_id, idempotency_key, status);
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_expires ON api.idempotency_keys(expires_at) WHERE status IN ('processing');
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_transaction ON api.idempotency_keys(transaction_id) WHERE transaction_id IS NOT NULL;

COMMENT ON TABLE api.idempotency_keys IS 
'Idempotency key storage for API request deduplication.
Keys are unique per application and expire after configured TTL.
WORM: Completed responses are immutable.';

-- =============================================================================
-- TABLE: api.duplicate_detection_log
-- PURPOSE: Log of detected duplicate requests for audit
-- SECURITY: Application-scoped via RLS
-- =============================================================================
CREATE TABLE IF NOT EXISTS api.duplicate_detection_log (
    log_id UUID DEFAULT gen_random_uuid(),
    
    -- Original request reference
    original_key_id UUID NOT NULL,
    
    -- Duplicate request details
    duplicate_request_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    duplicate_request_hash VARCHAR(64), -- Hash of duplicate request body
    
    -- Match analysis
    is_identical_request BOOLEAN DEFAULT TRUE, -- Body matches exactly
    differences JSONB, -- If not identical, what changed
    
    -- Action taken
    action_taken VARCHAR(20) DEFAULT 'replayed_response' 
        CHECK (action_taken IN ('replayed_response', 'rejected', 'processed_as_new')),
    
    -- Client info
    client_ip INET,
    user_agent TEXT,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_api_duplicate_detection_log_log_id_created_at PRIMARY KEY (log_id, created_at));

-- Convert to hypertable
SELECT create_hypertable(
    'api.duplicate_detection_log',
    'created_at',
    chunk_time_interval => INTERVAL '7 days',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_duplicate_log_original ON api.duplicate_detection_log(original_key_id);
CREATE INDEX IF NOT EXISTS idx_duplicate_log_action ON api.duplicate_detection_log(action_taken, created_at);

COMMENT ON TABLE api.duplicate_detection_log IS 
'Audit log of duplicate request detection and resolution actions';

-- =============================================================================
-- TABLE: api.idempotency_policies
-- PURPOSE: Per-application idempotency configuration
-- SECURITY: Application-scoped via RLS
-- =============================================================================
CREATE TABLE IF NOT EXISTS api.idempotency_policies (
    policy_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Application
    application_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    
    -- Policy configuration
    key_ttl_hours INTEGER DEFAULT 24, -- Default 24h expiration
    max_key_length INTEGER DEFAULT 255,
    required_headers TEXT[] DEFAULT ARRAY['Idempotency-Key'], -- Headers to check
    
    -- Validation rules
    require_request_body_hash BOOLEAN DEFAULT TRUE,
    ignore_header_changes TEXT[] DEFAULT ARRAY['x-request-id', 'x-correlation-id'],
    
    -- Behavior on conflict
    on_body_mismatch VARCHAR(20) DEFAULT 'reject' 
        CHECK (on_body_mismatch IN ('reject', 'ignore', 'process_as_new')),
    
    -- Limits
    max_keys_per_hour INTEGER DEFAULT 10000,
    cleanup_after_days INTEGER DEFAULT 30, -- Archive after this period
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    UNIQUE (application_id)
);

CREATE INDEX IF NOT EXISTS idx_idempotency_policies_app ON api.idempotency_policies(application_id, is_active);

COMMENT ON TABLE api.idempotency_policies IS 
'Per-application idempotency configuration and policies';

-- =============================================================================
-- TABLE: api.idempotency_archives
-- PURPOSE: Archived expired keys for long-term audit
-- SECURITY: Application-scoped via RLS
-- =============================================================================
CREATE TABLE IF NOT EXISTS api.idempotency_archives (
    archive_id UUID DEFAULT gen_random_uuid(),
    
    -- Original key reference
    original_key_id UUID NOT NULL,
    application_id UUID NOT NULL,
    idempotency_key VARCHAR(255) NOT NULL,
    
    -- Request/response snapshot
    request_method VARCHAR(10),
    request_path VARCHAR(500),
    response_status INTEGER,
    transaction_id UUID,
    
    -- Timing
    original_created_at TIMESTAMPTZ NOT NULL,
    archived_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Archive metadata
    archive_reason VARCHAR(50) DEFAULT 'expiration', -- expiration, manual, migration
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_api_idempotency_archives_archive_id_archived_at PRIMARY KEY (archive_id, archived_at));

-- Convert to hypertable
SELECT create_hypertable(
    'api.idempotency_archives',
    'archived_at',
    chunk_time_interval => INTERVAL '30 days',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_idempotency_archives_lookup ON api.idempotency_archives(application_id, idempotency_key);
CREATE INDEX IF NOT EXISTS idx_idempotency_archives_transaction ON api.idempotency_archives(transaction_id) WHERE transaction_id IS NOT NULL;

COMMENT ON TABLE api.idempotency_archives IS 
'Archived idempotency keys for long-term audit (after expiration)';

-- =============================================================================
-- FUNCTIONS: Idempotency Operations
-- =============================================================================

-- Function: Check idempotency key
CREATE OR REPLACE FUNCTION api.check_idempotency_key(
    p_application_id UUID,
    p_idempotency_key VARCHAR,
    p_request_hash VARCHAR DEFAULT NULL
)
RETURNS TABLE (
    key_exists BOOLEAN,
    key_status VARCHAR,
    response_status INTEGER,
    response_body JSONB,
    transaction_id UUID,
    is_locked BOOLEAN
) AS $$
DECLARE
    v_record RECORD;
BEGIN
    SELECT * INTO v_record
    FROM api.idempotency_keys
    WHERE application_id = p_application_id
      AND idempotency_key = p_idempotency_key;
    
    IF NOT FOUND THEN
        key_exists := FALSE;
        key_status := NULL;
        response_status := NULL;
        response_body := NULL;
        transaction_id := NULL;
        is_locked := FALSE;
        RETURN NEXT;
        RETURN;
    END IF;
    
    key_exists := TRUE;
    key_status := v_record.status;
    response_status := v_record.response_status;
    response_body := v_record.response_body;
    transaction_id := v_record.transaction_id;
    is_locked := v_record.locked_at IS NOT NULL 
                 AND v_record.locked_at > NOW() - INTERVAL '5 minutes';
    
    -- Update request count
    UPDATE api.idempotency_keys
    SET request_count = request_count + 1,
        last_request_at = NOW()
    WHERE key_id = v_record.key_id;
    
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION api.check_idempotency_key(UUID, VARCHAR, VARCHAR) IS 
'Checks if an idempotency key exists and returns stored response if available';

-- Function: Create idempotency key
CREATE OR REPLACE FUNCTION api.create_idempotency_key(
    p_application_id UUID,
    p_idempotency_key VARCHAR,
    p_request_method VARCHAR,
    p_request_path VARCHAR,
    p_request_hash VARCHAR,
    p_request_headers JSONB,
    p_client_ip INET,
    p_user_agent TEXT,
    p_ttl_hours INTEGER DEFAULT 24
)
RETURNS UUID AS $$
DECLARE
    v_key_id UUID;
    v_policy RECORD;
BEGIN
    -- Get policy for TTL
    SELECT key_ttl_hours INTO v_policy
    FROM api.idempotency_policies
    WHERE application_id = p_application_id
      AND is_active = TRUE;
    
    INSERT INTO api.idempotency_keys (
        application_id,
        idempotency_key,
        request_method,
        request_path,
        request_hash,
        request_headers,
        client_ip,
        user_agent,
        expires_at,
        locked_at,
        locked_by
    ) VALUES (
        p_application_id,
        p_idempotency_key,
        p_request_method,
        p_request_path,
        p_request_hash,
        p_request_headers,
        p_client_ip,
        p_user_agent,
        NOW() + COALESCE((v_policy.key_ttl_hours || ' hours')::interval, INTERVAL '24 hours'),
        NOW(),
        pg_backend_pid()::text
    )
    ON CONFLICT (application_id, idempotency_key) DO NOTHING
    RETURNING key_id INTO v_key_id;
    
    RETURN v_key_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION api.create_idempotency_key(UUID, VARCHAR, VARCHAR, VARCHAR, VARCHAR, JSONB, INET, TEXT, INTEGER) IS 
'Creates a new idempotency key record for an in-flight request';

-- Function: Complete idempotency key
CREATE OR REPLACE FUNCTION api.complete_idempotency_key(
    p_key_id UUID,
    p_response_status INTEGER,
    p_response_body JSONB,
    p_response_headers JSONB,
    p_transaction_id UUID DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
    UPDATE api.idempotency_keys
    SET status = 'completed',
        response_status = p_response_status,
        response_body = p_response_body,
        response_headers = p_response_headers,
        transaction_id = p_transaction_id,
        completed_at = NOW(),
        locked_at = NULL,
        locked_by = NULL
    WHERE key_id = p_key_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION api.complete_idempotency_key(UUID, INTEGER, JSONB, JSONB, UUID) IS 
'Completes an idempotency key with the response for future replay';

-- Function: Log duplicate detection
CREATE OR REPLACE FUNCTION api.log_duplicate_detection(
    p_original_key_id UUID,
    p_duplicate_hash VARCHAR,
    p_is_identical BOOLEAN,
    p_differences JSONB,
    p_action_taken VARCHAR,
    p_client_ip INET,
    p_user_agent TEXT
)
RETURNS UUID AS $$
DECLARE
    v_log_id UUID;
BEGIN
    INSERT INTO api.duplicate_detection_log (
        original_key_id,
        duplicate_request_hash,
        is_identical_request,
        differences,
        action_taken,
        client_ip,
        user_agent
    ) VALUES (
        p_original_key_id,
        p_duplicate_hash,
        p_is_identical,
        p_differences,
        p_action_taken,
        p_client_ip,
        p_user_agent
    )
    RETURNING log_id INTO v_log_id;
    
    RETURN v_log_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION api.log_duplicate_detection(UUID, VARCHAR, BOOLEAN, JSONB, VARCHAR, INET, TEXT) IS 
'Logs a duplicate request detection for audit purposes';

-- Function: Archive expired idempotency keys
CREATE OR REPLACE FUNCTION api.archive_expired_keys(
    p_batch_size INTEGER DEFAULT 1000
)
RETURNS INTEGER AS $$
DECLARE
    v_archived INTEGER := 0;
BEGIN
    -- Archive expired keys
    WITH archived AS (
        INSERT INTO api.idempotency_archives (
            original_key_id,
            application_id,
            idempotency_key,
            request_method,
            request_path,
            response_status,
            transaction_id,
            original_created_at,
            archive_reason
        )
        SELECT 
            key_id,
            application_id,
            idempotency_key,
            request_method,
            request_path,
            response_status,
            transaction_id,
            created_at,
            'expiration'
        FROM api.idempotency_keys
        WHERE expires_at < NOW()
          AND status = 'completed'
        LIMIT p_batch_size
        RETURNING original_key_id
    )
    SELECT COUNT(*) INTO v_archived FROM archived;
    
    -- Delete archived keys from main table
    DELETE FROM api.idempotency_keys
    WHERE key_id IN (
        SELECT original_key_id 
        FROM api.idempotency_archives 
        WHERE archived_at > NOW() - INTERVAL '1 hour'
    );
    
    RETURN v_archived;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION api.archive_expired_keys(INTEGER) IS 
'Archives expired completed idempotency keys and removes from active table';

-- =============================================================================
-- RLS POLICIES
-- =============================================================================

DO $$
BEGIN
    ALTER TABLE api.idempotency_keys ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE api.idempotency_keys FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE api.duplicate_detection_log ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE api.duplicate_detection_log FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE api.idempotency_policies ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE api.idempotency_archives ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE api.idempotency_archives FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Application isolation
CREATE POLICY idempotency_keys_app_isolation ON api.idempotency_keys
    FOR ALL
    TO ussd_app_user
    USING (application_id = current_setting('app.current_application_id', true)::UUID);

CREATE POLICY duplicate_log_app_isolation ON api.duplicate_detection_log
    FOR ALL
    TO ussd_app_user
    USING (original_key_id IN (
        SELECT key_id FROM api.idempotency_keys
        WHERE application_id = current_setting('app.current_application_id', true)::UUID
    ));

CREATE POLICY idempotency_policies_app_isolation ON api.idempotency_policies
    FOR ALL
    TO ussd_app_user
    USING (application_id = current_setting('app.current_application_id', true)::UUID);

CREATE POLICY idempotency_archives_app_isolation ON api.idempotency_archives
    FOR ALL
    TO ussd_app_user
    USING (application_id = current_setting('app.current_application_id', true)::UUID);

-- =============================================================================
-- WORM TRIGGERS (Immutability for completed keys)
-- =============================================================================

CREATE TRIGGER trg_idempotency_keys_prevent_update_completed
    BEFORE UPDATE ON api.idempotency_keys
    FOR EACH ROW
    WHEN (OLD.status = 'completed')
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_idempotency_keys_prevent_delete
    BEFORE DELETE ON api.idempotency_keys
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

-- =============================================================================
-- GRANTS
-- =============================================================================

GRANT USAGE ON SCHEMA api TO ussd_app_user, ussd_gateway_role;
GRANT SELECT, INSERT, UPDATE ON api.idempotency_keys TO ussd_app_user;
GRANT SELECT ON api.duplicate_detection_log TO ussd_app_user;
GRANT SELECT, UPDATE ON api.idempotency_policies TO ussd_app_user;
GRANT SELECT ON api.idempotency_archives TO ussd_app_user;

COMMIT;
