-- =============================================================================
-- Migration: V053__app_agent_sessions
-- Description: App table: agent_sessions
-- Dependencies: V052
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- ULTIMATE SOFTWARE SECURITY SOLUTIONS & DEFI LIMITED
-- AI Agent Sessions Table
-- =============================================================================
-- Compliance: ISO 27001:2022 (A.8.1, A.12.4), ISO 27018:2019
--             GDPR (Art. 17 - Right to erasure), SOC 2 Type II
-- Classification: CONFIDENTIAL - Contains AI Conversation State
-- Encryption: Session data encrypted at application layer for sensitive content
-- Version: 1.0.0
-- Author: Database Engineering Team
-- Last Modified: 2026-03-30
-- =============================================================================

-- -----------------------------------------------------------------------------
-- TABLE: agent_sessions
-- PURPOSE: Persistent state storage for AI agent conversations and workflows
-- SECURITY: Session data encrypted; TTL enforced; access tied to user ownership
-- NOTES: Supports multiple agent types; conversation history in separate table
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS app.agent_sessions (
    -- Primary Identifier
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Session Identification
    session_id VARCHAR(255) UNIQUE NOT NULL,  -- External session identifier
    
    -- Agent Configuration
    agent_type VARCHAR(100) NOT NULL CHECK (
        agent_type IN ('conversational', 'task_oriented', 'autonomous',
                      'multi_agent', 'code_assistant', 'data_analyst',
                      'security_analyst', 'custom')
    ),
    agent_version VARCHAR(50) NOT NULL DEFAULT '1.0.0',
    
    -- Model Reference
    -- PRODUCTION FIX (DEP-006): app.model_registry does not exist.
    -- Changed to TEXT field to store model identifier; FK can be added later if table is created.
    model_id TEXT,  -- Was: UUID REFERENCES app.model_registry(id)
    
    -- Session Ownership
    user_id UUID NOT NULL REFERENCES app.users(id),
    organization_id UUID REFERENCES app.application_registry(application_id),
    
    -- Session State (encrypted JSONB)
    session_data JSONB NOT NULL DEFAULT '{}'::jsonb,
    session_data_hash VARCHAR(64),      -- Integrity verification
    
    -- Session Status State Machine
    status VARCHAR(20) NOT NULL DEFAULT 'active' CHECK (
        status IN ('initializing', 'active', 'paused', 'waiting_input',
                   'processing', 'error', 'completed', 'expired', 'terminated')
    ),
    
    -- Context Window Management
    context_window_tokens INTEGER DEFAULT 0,
    max_context_tokens INTEGER DEFAULT 8192,
    context_compression_enabled BOOLEAN DEFAULT FALSE,
    
    -- Tool Execution State
    available_tools TEXT[],             -- Tools enabled for this session
    tool_execution_state JSONB DEFAULT '{}'::jsonb,  -- Pending tool calls
    
    -- Memory and Retrieval
    memory_enabled BOOLEAN DEFAULT TRUE,
    vector_collection VARCHAR(255),     -- Associated vector store collection
    
    -- Conversation Metadata
    message_count INTEGER DEFAULT 0,
    last_message_at TIMESTAMPTZ,
    first_message_at TIMESTAMPTZ,
    
    -- Token Usage Tracking
    total_input_tokens BIGINT DEFAULT 0,
    total_output_tokens BIGINT DEFAULT 0,
    total_cost_usd NUMERIC(12,6) DEFAULT 0.0,
    
    -- Session Lifecycle
    started_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_activity_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMPTZ,             -- Auto-cleanup timestamp
    ttl_seconds INTEGER DEFAULT 86400,  -- 24 hours default
    
    -- Geographic and Network Context
    ip_address INET,
    user_agent_hash VARCHAR(64),
    geo_location JSONB,                 -- Country, region (if available)
    
    -- Security Context
    security_level VARCHAR(20) DEFAULT 'standard' CHECK (
        security_level IN ('standard', 'elevated', 'restricted', 'classified')
    ),
    mfa_verified BOOLEAN DEFAULT FALSE,
    auth_session_id UUID,               -- Link to auth session
    
    -- Compliance Flags
    contains_pii BOOLEAN DEFAULT FALSE,
    data_classification VARCHAR(20) DEFAULT 'internal',
    gdpr_data_subject_request_id UUID,  -- Link to DSR if applicable
    
    -- Error Handling
    error_count INTEGER DEFAULT 0,
    last_error_at TIMESTAMPTZ,
    last_error_message TEXT,
    
    -- Resume Capability
    resumable BOOLEAN DEFAULT TRUE,
    resume_token_hash VARCHAR(64),      -- Hashed token for session resumption
    
    -- Immutable Ledger Integration
    ledger_hash VARCHAR(64),
    ledger_sequence BIGINT,
    
    -- Audit Columns
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by UUID REFERENCES app.users(id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by UUID REFERENCES app.users(id),
    
    -- Soft Delete (for audit trail)
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES app.users(id),
    
    -- Constraints
    CONSTRAINT chk_session_data_size CHECK (
        pg_column_size(session_data) <= 10485760  -- 10MB max
    ),
    CONSTRAINT chk_ttl_positive CHECK (ttl_seconds > 0),
    CONSTRAINT chk_message_count_nonnegative CHECK (message_count >= 0),
    CONSTRAINT chk_token_usage_nonnegative CHECK (
        total_input_tokens >= 0 AND total_output_tokens >= 0
    )
);

-- -----------------------------------------------------------------------------
-- INDEXES: Optimized for session lookup and cleanup jobs
-- -----------------------------------------------------------------------------

-- Primary session lookup by external ID
CREATE INDEX IF NOT EXISTS idx_agent_sessions_session_id 
    ON app.agent_sessions USING btree (session_id);

-- User session listing
CREATE INDEX IF NOT EXISTS idx_agent_sessions_user 
    ON app.agent_sessions USING btree (user_id, status, last_activity_at DESC);

-- Active sessions query
CREATE INDEX IF NOT EXISTS idx_agent_sessions_active 
    ON app.agent_sessions USING btree (status, last_activity_at) 
    WHERE status IN ('active', 'processing', 'waiting_input');

-- Expiration tracking for cleanup jobs
CREATE INDEX IF NOT EXISTS idx_agent_sessions_expires 
    ON app.agent_sessions USING btree (expires_at) 
    WHERE expires_at IS NOT NULL AND deleted_at IS NULL;

-- Agent type filtering
CREATE INDEX IF NOT EXISTS idx_agent_sessions_agent_type 
    ON app.agent_sessions USING btree (agent_type, status);

-- Model usage tracking
CREATE INDEX IF NOT EXISTS idx_agent_sessions_model 
    ON app.agent_sessions USING btree (model_id, created_at DESC) 
    WHERE model_id IS NOT NULL;

-- Organization queries
CREATE INDEX IF NOT EXISTS idx_agent_sessions_org 
    ON app.agent_sessions USING btree (organization_id, created_at DESC) 
    WHERE organization_id IS NOT NULL;

-- Security level filtering
CREATE INDEX IF NOT EXISTS idx_agent_sessions_security 
    ON app.agent_sessions USING btree (security_level, status);

-- PII detection queries
CREATE INDEX IF NOT EXISTS idx_agent_sessions_pii 
    ON app.agent_sessions USING btree (contains_pii, created_at) 
    WHERE contains_pii = TRUE;

-- Ledger verification
CREATE INDEX IF NOT EXISTS idx_agent_sessions_ledger 
    ON app.agent_sessions USING btree (ledger_sequence) 
    WHERE ledger_sequence IS NOT NULL;

-- Soft delete filtering
CREATE INDEX IF NOT EXISTS idx_agent_sessions_active_flag 
    ON app.agent_sessions USING btree (deleted_at) 
    WHERE deleted_at IS NULL;

-- Activity tracking for analytics
CREATE INDEX IF NOT EXISTS idx_agent_sessions_activity 
    ON app.agent_sessions USING btree (last_activity_at DESC) 
    WHERE status != 'expired' AND deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- ROW LEVEL SECURITY (RLS): Strict session isolation
-- -----------------------------------------------------------------------------

DO $$
BEGIN
    ALTER TABLE app.agent_sessions ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Force RLS for table owner
DO $$
BEGIN
    ALTER TABLE app.agent_sessions FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Policy: Users can only access their own sessions
-- NOTE: Simplified to avoid forward dependency on permission functions.
-- Full permission-based access control will be added in V125 when permission
-- system is fully implemented.
CREATE POLICY agent_sessions_select_policy ON app.agent_sessions
    FOR SELECT
    USING (
        deleted_at IS NULL AND
        (
            -- User owns the session
            user_id = current_setting('app.current_user_id', true)::UUID
            OR
            -- Same organization access (if user belongs to same org)
            (
                organization_id IS NOT NULL AND
                organization_id = current_setting('app.current_organization_id', true)::UUID
            )
        )
    );

-- Policy: Users can only create sessions for themselves
CREATE POLICY agent_sessions_insert_policy ON app.agent_sessions
    FOR INSERT
    WITH CHECK (
        user_id = current_setting('app.current_user_id', true)::UUID
    );

-- Policy: Users can only update their own active sessions
CREATE POLICY agent_sessions_update_policy ON app.agent_sessions
    FOR UPDATE
    USING (
        deleted_at IS NULL AND
        user_id = current_setting('app.current_user_id', true)::UUID
    );

-- Policy: Soft delete only
CREATE POLICY agent_sessions_delete_policy ON app.agent_sessions
    FOR DELETE
    USING (FALSE);

-- -----------------------------------------------------------------------------
-- TRIGGERS: Automated session management
-- -----------------------------------------------------------------------------

-- Trigger: Compute session hash and set expiration
CREATE OR REPLACE FUNCTION app.trigger_agent_sessions_inserted()
RETURNS TRIGGER AS $$
BEGIN
    -- Set audit fields
    IF NEW.created_by IS NULL THEN
        NEW.created_by := current_setting('app.current_user_id', true)::UUID;
    END IF;
    
    -- Compute session data hash for integrity
    NEW.session_data_hash := encode(
        digest(NEW.session_data::text, 'sha256'),
        'hex'
    );
    
    -- Set expiration based on TTL
    IF NEW.expires_at IS NULL AND NEW.ttl_seconds IS NOT NULL THEN
        NEW.expires_at := NEW.started_at + (NEW.ttl_seconds || ' seconds')::interval;
    END IF;
    
    -- Set first message timestamp if messages exist
    IF NEW.message_count > 0 AND NEW.first_message_at IS NULL THEN
        NEW.first_message_at := NEW.started_at;
        NEW.last_message_at := NEW.started_at;
    END IF;
    
    -- Compute ledger hash
    NEW.ledger_hash := encode(
        digest(
            NEW.id::text || NEW.session_id || NEW.user_id::text || 
            NEW.started_at::text || NEW.session_data_hash,
            'sha256'
        ),
        'hex'
    );
    
    -- Get ledger sequence
    SELECT COALESCE(MAX(ledger_sequence), 0) + 1 
    INTO NEW.ledger_sequence
    FROM app.agent_sessions;
    
    -- Log to audit
    INSERT INTO app.audit_log (
        table_name, record_id, action,
        new_data, performed_by
    ) VALUES (
        'agent_sessions', NEW.id, 'SESSION_START',
        jsonb_build_object(
            'session_id', NEW.session_id,
            'agent_type', NEW.agent_type,
            'user_id', NEW.user_id
        ),
        NEW.created_by
    );
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS agent_sessions_inserted ON app.agent_sessions;
CREATE TRIGGER agent_sessions_inserted
    BEFORE INSERT ON app.agent_sessions
    FOR EACH ROW
    EXECUTE FUNCTION app.trigger_agent_sessions_inserted();

-- Trigger: Update timestamp and recompute hash on modification
CREATE OR REPLACE FUNCTION app.trigger_agent_sessions_updated()
RETURNS TRIGGER AS $$
BEGIN
    -- Prevent modification of immutable fields
    IF OLD.ledger_hash IS DISTINCT FROM NEW.ledger_hash OR
       OLD.ledger_sequence IS DISTINCT FROM NEW.ledger_sequence THEN
        RAISE EXCEPTION 'Ledger fields are immutable';
    END IF;
    
    -- Update timestamp
    NEW.updated_at := CURRENT_TIMESTAMP;
    NEW.updated_by := current_setting('app.current_user_id', true)::UUID;
    
    -- Recompute session data hash if data changed
    IF NEW.session_data IS DISTINCT FROM OLD.session_data THEN
        NEW.session_data_hash := encode(
            digest(NEW.session_data::text, 'sha256'),
            'hex'
        );
    END IF;
    
    -- Update activity timestamp
    NEW.last_activity_at := CURRENT_TIMESTAMP;
    
    -- Extend expiration on activity (if session is active)
    IF NEW.status = 'active' AND NEW.ttl_seconds IS NOT NULL THEN
        NEW.expires_at := CURRENT_TIMESTAMP + (NEW.ttl_seconds || ' seconds')::interval;
    END IF;
    
    -- Log status changes
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO app.audit_log (
            table_name, record_id, action,
            old_data, new_data, performed_by
        ) VALUES (
            'agent_sessions', NEW.id, 'STATUS_CHANGE',
            jsonb_build_object('status', OLD.status),
            jsonb_build_object('status', NEW.status),
            NEW.updated_by
        );
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS agent_sessions_updated ON app.agent_sessions;
CREATE TRIGGER agent_sessions_updated
    BEFORE UPDATE ON app.agent_sessions
    FOR EACH ROW
    EXECUTE FUNCTION app.trigger_agent_sessions_updated();

-- Trigger: Soft delete enforcement
CREATE OR REPLACE FUNCTION app.trigger_agent_sessions_soft_delete()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
        NEW.deleted_by := current_setting('app.current_user_id', true)::UUID;
        NEW.status := 'terminated';
        
        INSERT INTO app.audit_log (
            table_name, record_id, action,
            old_data, performed_by
        ) VALUES (
            'agent_sessions', NEW.id, 'SESSION_END',
            jsonb_build_object(
                'session_id', OLD.session_id,
                'status', OLD.status,
                'message_count', OLD.message_count,
                'duration_seconds', EXTRACT(EPOCH FROM (NEW.deleted_at - OLD.started_at))
            ),
            NEW.deleted_by
        );
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS agent_sessions_soft_delete ON app.agent_sessions;
CREATE TRIGGER agent_sessions_soft_delete
    BEFORE UPDATE OF deleted_at ON app.agent_sessions
    FOR EACH ROW
    EXECUTE FUNCTION app.trigger_agent_sessions_soft_delete();

-- Trigger: Prevent hard delete
CREATE OR REPLACE FUNCTION app.trigger_agent_sessions_prevent_delete()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Hard delete prohibited. Use soft delete via UPDATE.'
        USING HINT = 'Set deleted_at to terminate a session';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS agent_sessions_prevent_delete ON app.agent_sessions;
CREATE TRIGGER agent_sessions_prevent_delete
    BEFORE DELETE ON app.agent_sessions
    FOR EACH ROW
    EXECUTE FUNCTION app.trigger_agent_sessions_prevent_delete();

-- -----------------------------------------------------------------------------
-- CLEANUP FUNCTION: Expired session cleanup job
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.cleanup_expired_sessions(
    batch_size INTEGER DEFAULT 1000
)
RETURNS INTEGER AS $$
DECLARE
    cleaned_count INTEGER := 0;
BEGIN
    UPDATE app.agent_sessions
    SET 
        deleted_at = CURRENT_TIMESTAMP,
        deleted_by = current_setting('app.current_user_id', true)::UUID,
        status = 'expired'
    WHERE 
        deleted_at IS NULL
        AND status NOT IN ('expired', 'terminated', 'completed')
        AND expires_at < CURRENT_TIMESTAMP
        AND id IN (
            SELECT id FROM app.agent_sessions
            WHERE deleted_at IS NULL
            AND status NOT IN ('expired', 'terminated', 'completed')
            AND expires_at < CURRENT_TIMESTAMP
            LIMIT batch_size
        );
    
    GET DIAGNOSTICS cleaned_count = ROW_COUNT;
    
    RETURN cleaned_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION app.cleanup_expired_sessions IS 
    'Marks expired sessions as deleted. Should be run by scheduled job.';

-- -----------------------------------------------------------------------------
-- TABLE COMMENTS
-- -----------------------------------------------------------------------------

COMMENT ON TABLE app.agent_sessions IS 
    'AI agent session state persistence. Tracks conversation context, 
     tool state, and token usage. Sessions auto-expire based on TTL.';

COMMENT ON COLUMN app.agent_sessions.session_id IS 'External session identifier';
COMMENT ON COLUMN app.agent_sessions.agent_type IS 'Category of AI agent';
COMMENT ON COLUMN app.agent_sessions.session_data IS 'Encrypted session state (JSONB)';
COMMENT ON COLUMN app.agent_sessions.status IS 'Session state machine status';
COMMENT ON COLUMN app.agent_sessions.available_tools IS 'Enabled MCP tools';
COMMENT ON COLUMN app.agent_sessions.context_window_tokens IS 'Current context size';
COMMENT ON COLUMN app.agent_sessions.expires_at IS 'Auto-cleanup timestamp';
COMMENT ON COLUMN app.agent_sessions.security_level IS 'Data sensitivity classification';
COMMENT ON COLUMN app.agent_sessions.resume_token_hash IS 'Hashed token for session resumption';

-- -----------------------------------------------------------------------------
-- GRANTS
-- -----------------------------------------------------------------------------

GRANT SELECT ON app.agent_sessions TO app_readonly;
GRANT SELECT, INSERT, UPDATE ON app.agent_sessions TO app_readwrite;
GRANT ALL ON app.agent_sessions TO app_admin;
GRANT EXECUTE ON FUNCTION app.cleanup_expired_sessions TO app_admin;

-- =============================================================================
-- END OF FILE
-- =============================================================================

COMMIT;
