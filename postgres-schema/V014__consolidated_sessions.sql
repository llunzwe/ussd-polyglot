-- =============================================================================
-- Migration: V014__consolidated_sessions
-- Description: Real-Time USSD Session Management (Active Sessions)
-- Dependencies: V001-V013
-- 
-- ARCHITECTURE NOTE:
-- This file creates REAL-TIME session tables optimized for active session 
-- management. For PERSISTENT session records with full audit trail and 
-- encryption, see V043__ussd_session_state.sql.
--
-- TABLE PURPOSE COMPARISON:
-- +---------------------+----------------+----------------+------------------+
-- | Table               | This File      | V043           | Use Case         |
-- +---------------------+----------------+----------------+------------------+
-- | ussd.sessions       | ✓ Real-time    |                | Active USSD      |
-- | ussd.ussd_sessions  |                | ✓ Persistent   | Audit/Compliance |
-- | ussd.session_events |                | ✓ Audit trail  | Security events  |
-- +---------------------+----------------+----------------+------------------+
--
-- FOREIGN KEY GUIDANCE:
-- - Real-time operations (current session) → ussd.sessions
-- - Audit/historical records → ussd.ussd_sessions
-- - Security/lifecycle events → ussd.session_events (in V043)
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- REAL-TIME USSD SESSIONS (TimescaleDB Hypertable)
-- PURPOSE: Active session state for in-progress USSD interactions
-- LIFETIME: 5 minutes (configurable via expires_at)
-- RETENTION: TimescaleDB automatic chunk dropping after 7 days
-- DIFFERS FROM V043: This is for REAL-TIME only; V043 has PERSISTENT records
-- =============================================================================

CREATE TABLE IF NOT EXISTS ussd.sessions (
    session_id UUID DEFAULT gen_random_uuid(),
    
    -- Session identification
    session_token VARCHAR(255) NOT NULL,
    CONSTRAINT uq_ussd_sessions_session_token UNIQUE (session_token, started_at),
    
    -- Application context
    application_id UUID NOT NULL,
    environment VARCHAR(20) DEFAULT 'production' 
        CHECK (environment IN ('sandbox', 'production')),
    
    -- User identification (encrypted)
    msisdn_hash VARCHAR(64) NOT NULL, -- Hashed, never plaintext
    user_id UUID,
    
    -- Provider context
    provider_adapter_id UUID REFERENCES ussd.provider_adapters(adapter_id) ON DELETE SET NULL,
    provider_session_id VARCHAR(255),
    
    -- Network info
    network_code VARCHAR(20),
    country_code VARCHAR(5),
    
    -- Current state
    current_menu_id UUID,
    current_state VARCHAR(100) DEFAULT 'init',
    previous_state VARCHAR(100),
    
    -- Session data
    context_data JSONB DEFAULT '{}',
    user_data JSONB DEFAULT '{}',
    input_history JSONB DEFAULT '[]',
    
    -- Session configuration
    session_config JSONB, -- Session configuration (NULL = use application defaults)
    
    -- Concurrent session handling
    is_concurrent BOOLEAN DEFAULT FALSE,
    parent_session_id UUID,
    child_session_ids UUID[] DEFAULT ARRAY[]::UUID[],
    
    -- Session lifecycle
    status VARCHAR(20) DEFAULT 'active' 
        CHECK (status IN ('active', 'paused', 'completed', 'expired', 'terminated')),
    
    -- Timing
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_activity_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '5 minutes'),
    ended_at TIMESTAMPTZ,
    
    -- Termination details
    termination_reason VARCHAR(100),
    termination_source VARCHAR(50), -- 'user', 'timeout', 'system', 'admin'
    
    -- Checkpoint for restore
    checkpoint_data JSONB,
    checkpoint_at TIMESTAMPTZ,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT chk_valid_dates CHECK (expires_at > started_at),
    CONSTRAINT pk_ussd_sessions_session_id_started_at PRIMARY KEY (session_id, started_at));

-- Convert to hypertable for time-series
SELECT create_hypertable(
    'ussd.sessions',
    'started_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_sessions_msisdn 
    ON ussd.sessions(msisdn_hash, status) 
    WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_sessions_app 
    ON ussd.sessions(application_id, environment, status);

CREATE INDEX IF NOT EXISTS idx_sessions_token 
    ON ussd.sessions(session_token) 
    WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_sessions_expiry 
    ON ussd.sessions(expires_at) 
    WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_sessions_provider 
    ON ussd.sessions(provider_adapter_id, provider_session_id);

CREATE INDEX IF NOT EXISTS idx_sessions_concurrent 
    ON ussd.sessions(parent_session_id) 
    WHERE parent_session_id IS NOT NULL;

COMMENT ON TABLE ussd.sessions IS 
'REAL-TIME USSD SESSIONS - Active Session Management Only
ISO 27001: A.8.1 (User Endpoint), A.8.5 (Secure Authentication)
GDPR: Art 5(1)(e) (Storage Limitation)

PURPOSE:
  Real-time active session tracking for in-progress USSD interactions.
  Data retained for 7 days (TimescaleDB chunk dropping).

DIFFERS FROM ussd.ussd_sessions (V043):
  - This table: Real-time only, 5-min TTL, minimal columns
  - V043 table: Persistent records, full PII encryption, 90-day retention

USE THIS TABLE FOR:
  - Current active session lookup
  - Real-time session state during USSD flow
  - Session timeout management
  - Concurrent session detection

USE ussd.ussd_sessions (V043) FOR:
  - Audit trails and compliance
  - Historical session analysis
  - Fraud detection (device fingerprinting)
  - Session hash chain integrity

SECURITY FEATURES:
  - MSISDN hashed only (no encryption at rest here - in V043)
  - Multi-layer timeouts: network (2min), app (5min), absolute (15min)
  - Session hash chain in V043 for audit trail
  - No PINs stored in input_history

AFRICA''S TALKING INTEGRATION:
  - Session timeout: 180 seconds (configurable per route)
  - Callback format: application/x-www-form-urlencoded
  - Supports concurrent session policies';

-- =============================================================================
-- ACTIVE SESSION MONITORING (Real-time view materialized)
-- PURPOSE: Operational monitoring of currently active sessions
-- =============================================================================

CREATE TABLE IF NOT EXISTS ussd.active_session_monitor (
    monitor_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    session_id UUID NOT NULL,
    
    -- Real-time metrics
    is_active BOOLEAN DEFAULT TRUE,
    last_ping_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Current state
    current_menu VARCHAR(100),
    current_input_field VARCHAR(100),
    validation_status VARCHAR(20),
    
    -- Performance
    response_time_ms INTEGER,
    input_processing_ms INTEGER,
    
    -- Alerts
    has_error BOOLEAN DEFAULT FALSE,
    error_count INTEGER DEFAULT 0,
    last_error_at TIMESTAMPTZ,
    last_error_message TEXT,
    
    -- User experience
    frustration_score INTEGER DEFAULT 0, -- Based on repeated errors
    retry_count INTEGER DEFAULT 0,
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_active_monitor_session 
    ON ussd.active_session_monitor(session_id, is_active);

CREATE INDEX IF NOT EXISTS idx_active_monitor_ping 
    ON ussd.active_session_monitor(last_ping_at) 
    WHERE is_active = TRUE;

CREATE INDEX IF NOT EXISTS idx_active_monitor_frustration 
    ON ussd.active_session_monitor(frustration_score DESC) 
    WHERE frustration_score > 3;

COMMENT ON TABLE ussd.active_session_monitor IS 'Real-time active session monitoring for operations dashboard';

-- =============================================================================
-- ENVIRONMENT ISOLATION VIEW
-- =============================================================================

CREATE OR REPLACE VIEW ussd.active_sessions_by_environment AS
SELECT 
    environment,
    application_id,
    COUNT(*) FILTER (WHERE status = 'active') as active_count,
    COUNT(*) FILTER (WHERE status = 'paused') as paused_count,
    COUNT(*) FILTER (WHERE expires_at < NOW() + INTERVAL '1 minute') as expiring_soon,
    MAX(last_activity_at) as last_activity,
    COUNT(*) FILTER (WHERE is_concurrent) as concurrent_sessions
FROM ussd.sessions
WHERE status IN ('active', 'paused')
GROUP BY environment, application_id;

COMMENT ON VIEW ussd.active_sessions_by_environment IS 'Real-time session counts by environment';

-- =============================================================================
-- TRIGGERS
-- =============================================================================

-- Use core.update_timestamp for updated_at maintenance
DROP TRIGGER IF EXISTS trg_sessions_timestamp ON ussd.sessions;
CREATE TRIGGER trg_sessions_timestamp
    BEFORE UPDATE ON ussd.sessions
    FOR EACH ROW
    EXECUTE FUNCTION core.update_timestamp();

DROP TRIGGER IF EXISTS trg_active_session_monitor_timestamp ON ussd.active_session_monitor;
CREATE TRIGGER trg_active_session_monitor_timestamp
    BEFORE UPDATE ON ussd.active_session_monitor
    FOR EACH ROW
    EXECUTE FUNCTION core.update_timestamp();

-- =============================================================================
-- WORM TRIGGERS (Immutability for completed sessions)
-- Note: WORM applied after session ends to allow state updates during active session
-- =============================================================================

CREATE TRIGGER trg_sessions_prevent_update_completed
    BEFORE UPDATE ON ussd.sessions
    FOR EACH ROW
    WHEN (OLD.status IN ('completed', 'expired', 'terminated'))
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_sessions_prevent_delete
    BEFORE DELETE ON ussd.sessions
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

CREATE TRIGGER trg_active_session_monitor_prevent_update
    BEFORE UPDATE ON ussd.active_session_monitor
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_active_session_monitor_prevent_delete
    BEFORE DELETE ON ussd.active_session_monitor
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

-- =============================================================================
-- RLS POLICIES
-- =============================================================================

DO $$
BEGIN
    ALTER TABLE ussd.sessions ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE ussd.sessions FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE ussd.active_session_monitor ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE ussd.active_session_monitor FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Application-scoped access
-- PRODUCTION FIX: Uses safe UUID helper to prevent NULL casting issues
CREATE POLICY sessions_app_isolation ON ussd.sessions
    FOR ALL
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

-- Active monitor inherits session isolation
CREATE POLICY active_monitor_app_isolation ON ussd.active_session_monitor
    FOR ALL
    TO ussd_app_user
    USING (session_id IN (
        SELECT session_id FROM ussd.sessions 
        WHERE application_id = core.get_current_setting_as_uuid('app.current_application_id')
    ));

-- =============================================================================
-- GRANTS
-- =============================================================================

-- Create roles if they don't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ussd_gateway_role') THEN
        CREATE ROLE ussd_gateway_role NOLOGIN;
    END IF;
END;
$$;

GRANT SELECT, INSERT, UPDATE ON ussd.sessions TO ussd_gateway_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ussd.active_session_monitor TO ussd_gateway_role;

COMMIT;
