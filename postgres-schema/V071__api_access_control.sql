-- =============================================================================
-- Migration: V071__api_access_control
-- Description: Multi-tenancy API Access Control & Audit Logging
-- Dependencies: V001-V070
--
-- PURPOSE: Service-to-service API authentication with scoped permissions,
-- comprehensive API access audit logging, and cross-tenant aggregation support.
--
-- ADR-018: API Key Scope Design
-- DECISION: Hierarchical scopes (ledger:read:own vs ledger:read:all)
-- RATIONALE:
--   - Simple read/write too coarse for security
--   - Need distinction between own data vs aggregated data
--   - Marketplace apps need cross-tenant access with restrictions
-- TRADE-OFFS:
--   (+) Granular access control
--   (+) Support for complex use cases (marketplace, admin)
--   (-) More complex permission checking logic
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- TABLE: api.key_scopes (extends app.api_keys from V005)
-- PURPOSE: Granular permission scopes for API keys
-- SECURITY: Application-scoped via RLS
-- =============================================================================
CREATE TABLE IF NOT EXISTS api.key_scopes (
    scope_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Reference to API key
    key_id UUID NOT NULL REFERENCES app.api_keys(key_id) ON DELETE CASCADE,
    
    -- Scope definition
    resource_type VARCHAR(50) NOT NULL 
        CHECK (resource_type IN (
            'ledger', 'account', 'transaction', 'webhook', 
            'export', 'reconciliation', 'dispute', 'admin'
        )),
    permission VARCHAR(20) NOT NULL 
        CHECK (permission IN ('read', 'write', 'delete', 'admin')),
    
    -- Data scope (hierarchy)
    data_scope VARCHAR(20) DEFAULT 'own' 
        CHECK (data_scope IN ('own', 'tenant', 'marketplace', 'all')),
    
    -- Restrictions
    allowed_operations TEXT[], -- Specific operations allowed
    forbidden_operations TEXT[], -- Explicitly forbidden operations
    
    -- Time restrictions
    valid_from TIMESTAMPTZ DEFAULT NOW(),
    valid_until TIMESTAMPTZ,
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_key_scopes_key ON api.key_scopes(key_id, is_active);
CREATE INDEX IF NOT EXISTS idx_key_scopes_resource ON api.key_scopes(resource_type, permission);
CREATE UNIQUE INDEX IF NOT EXISTS idx_key_scopes_unique 
    ON api.key_scopes(key_id, resource_type, permission, data_scope) 
    WHERE is_active = TRUE;

COMMENT ON TABLE api.key_scopes IS 
'Granular permission scopes for API keys with hierarchical data access';

-- =============================================================================
-- TABLE: api.access_audit_log
-- PURPOSE: Comprehensive audit log of all ledger API accesses
-- SECURITY: Append-only, queryable by admin
-- WORM: Immutable audit trail
-- =============================================================================
CREATE TABLE IF NOT EXISTS api.access_audit_log (
    audit_id UUID DEFAULT gen_random_uuid(),
    
    -- Request identification
    request_id VARCHAR(100) NOT NULL,
    
    -- Authentication context
    api_key_id UUID REFERENCES app.api_keys(key_id),
    application_id UUID REFERENCES app.application_registry(application_id),
    
    -- Request details
    request_method VARCHAR(10) NOT NULL,
    request_path TEXT NOT NULL,
    request_query JSONB,
    request_body_hash VARCHAR(64), -- Hash only, not content
    
    -- Response details
    response_status INTEGER,
    response_time_ms INTEGER,
    response_size_bytes INTEGER,
    
    -- Resource accessed
    resource_type VARCHAR(50),
    resource_id UUID,
    action_performed VARCHAR(100),
    
    -- Data scope
    data_scope VARCHAR(20), -- own, tenant, marketplace
    records_accessed INTEGER,
    
    -- Client info
    client_ip INET,
    user_agent TEXT,
    geo_country VARCHAR(2),
    
    -- Security flags
    is_suspicious BOOLEAN DEFAULT FALSE,
    suspicion_reason TEXT,
    rate_limit_hit BOOLEAN DEFAULT FALSE,
    
    -- Timing
    request_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Partitioning
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT pk_api_access_audit_log_audit_id_request_at PRIMARY KEY (audit_id, request_at));

-- Convert to hypertable
SELECT create_hypertable(
    'api.access_audit_log',
    'request_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_access_audit_app ON api.access_audit_log(application_id, request_at DESC);
CREATE INDEX IF NOT EXISTS idx_access_audit_key ON api.access_audit_log(api_key_id, request_at DESC);
CREATE INDEX IF NOT EXISTS idx_access_audit_resource ON api.access_audit_log(resource_type, resource_id, request_at DESC);
CREATE INDEX IF NOT EXISTS idx_access_audit_suspicious ON api.access_audit_log(is_suspicious, request_at) 
    WHERE is_suspicious = TRUE;
CREATE INDEX IF NOT EXISTS idx_access_audit_status ON api.access_audit_log(response_status, request_at);

COMMENT ON TABLE api.access_audit_log IS 
'Immutable audit log of all ledger API accesses with security monitoring';

-- =============================================================================
-- TABLE: api.service_accounts
-- PURPOSE: Service-to-service authentication for internal microservices
-- SECURITY: Admin only
-- =============================================================================
CREATE TABLE IF NOT EXISTS api.service_accounts (
    service_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Service identification
    service_name VARCHAR(100) UNIQUE NOT NULL,
    service_type VARCHAR(50) NOT NULL 
        CHECK (service_type IN ('internal', 'external', 'partner')),
    
    -- Authentication
    client_id VARCHAR(255) UNIQUE NOT NULL,
    client_secret_hash VARCHAR(255) NOT NULL,
    
    -- Permissions
    permissions JSONB NOT NULL DEFAULT '[]', -- [{resource, action, scope}]
    
    -- Network restrictions
    allowed_ips INET[],
    allowed_cidrs CIDR[],
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    last_authenticated_at TIMESTAMPTZ,
    
    -- Rotation
    secret_rotated_at TIMESTAMPTZ DEFAULT NOW(),
    secret_expires_at TIMESTAMPTZ,
    
    -- Audit
    created_by UUID REFERENCES core.account_registry(account_id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_service_accounts_client ON api.service_accounts(client_id, is_active);
CREATE INDEX IF NOT EXISTS idx_service_accounts_type ON api.service_accounts(service_type, is_active);

COMMENT ON TABLE api.service_accounts IS 
'Service-to-service authentication accounts for internal microservices';

-- =============================================================================
-- TABLE: api.marketplace_permissions
-- PURPOSE: Cross-tenant data sharing for marketplace applications
-- SECURITY: Admin configured, app-scoped
-- =============================================================================
CREATE TABLE IF NOT EXISTS api.marketplace_permissions (
    permission_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Marketplace app
    marketplace_app_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    
    -- Participant app
    participant_app_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    
    -- Permission scope
    allowed_resources TEXT[] NOT NULL, -- ['transactions', 'accounts']
    allowed_operations TEXT[] NOT NULL, -- ['read', 'aggregate']
    
    -- Data restrictions
    data_filters JSONB, -- {min_date, transaction_types, exclude_fields}
    
    -- Consent
    participant_consent_at TIMESTAMPTZ,
    participant_consent_ip INET,
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    revoked_at TIMESTAMPTZ,
    revoked_reason TEXT,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    UNIQUE (marketplace_app_id, participant_app_id)
);

CREATE INDEX IF NOT EXISTS idx_marketplace_perms_marketplace ON api.marketplace_permissions(marketplace_app_id, is_active);
CREATE INDEX IF NOT EXISTS idx_marketplace_perms_participant ON api.marketplace_permissions(participant_app_id, is_active);

COMMENT ON TABLE api.marketplace_permissions IS 
'Cross-tenant data sharing permissions for marketplace applications';

-- =============================================================================
-- TABLE: api.session_contexts
-- PURPOSE: Track API session context for multi-request operations
-- SECURITY: Application-scoped via RLS
-- =============================================================================
CREATE TABLE IF NOT EXISTS api.session_contexts (
    context_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Session identification
    session_token VARCHAR(255) UNIQUE NOT NULL,
    
    -- Authentication
    api_key_id UUID NOT NULL REFERENCES app.api_keys(key_id),
    application_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    
    -- Context data
    context_data JSONB DEFAULT '{}', -- {user_id, permissions, preferences}
    
    -- Security
    client_ip INET,
    geo_location JSONB,
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    
    -- Timing
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '1 hour'),
    last_activity_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- Audit
    terminated_at TIMESTAMPTZ,
    termination_reason VARCHAR(50)
);

CREATE INDEX IF NOT EXISTS idx_session_contexts_token ON api.session_contexts(session_token, is_active);
CREATE INDEX IF NOT EXISTS idx_session_contexts_app ON api.session_contexts(application_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_session_contexts_expires ON api.session_contexts(expires_at) 
    WHERE is_active = TRUE;

COMMENT ON TABLE api.session_contexts IS 
'API session context for maintaining state across related requests';

-- =============================================================================
-- FUNCTIONS: Access Control Operations
-- =============================================================================

-- Function: Check API permission
CREATE OR REPLACE FUNCTION api.check_permission(
    p_key_id UUID,
    p_resource_type VARCHAR,
    p_permission VARCHAR,
    p_data_scope VARCHAR DEFAULT 'own'
)
RETURNS BOOLEAN AS $$
DECLARE
    v_has_permission BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM api.key_scopes
        WHERE key_id = p_key_id
          AND resource_type = p_resource_type
          AND permission = p_permission
          AND data_scope >= p_data_scope -- Hierarchy: own < tenant < marketplace < all
          AND is_active = TRUE
          AND (valid_until IS NULL OR valid_until > NOW())
    ) INTO v_has_permission;
    
    RETURN COALESCE(v_has_permission, FALSE);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION api.check_permission(UUID, VARCHAR, VARCHAR, VARCHAR) IS 
'Checks if an API key has the required permission for a resource';

-- Function: Log API access
CREATE OR REPLACE FUNCTION api.log_api_access(
    p_request_id VARCHAR,
    p_api_key_id UUID,
    p_application_id UUID,
    p_request_method VARCHAR,
    p_request_path TEXT,
    p_response_status INTEGER,
    p_response_time_ms INTEGER,
    p_client_ip INET,
    p_user_agent TEXT
)
RETURNS UUID AS $$
DECLARE
    v_audit_id UUID;
BEGIN
    INSERT INTO api.access_audit_log (
        request_id,
        api_key_id,
        application_id,
        request_method,
        request_path,
        response_status,
        response_time_ms,
        client_ip,
        user_agent
    ) VALUES (
        p_request_id,
        p_api_key_id,
        p_application_id,
        p_request_method,
        p_request_path,
        p_response_status,
        p_response_time_ms,
        p_client_ip,
        p_user_agent
    )
    RETURNING audit_id INTO v_audit_id;
    
    RETURN v_audit_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION api.log_api_access(VARCHAR, UUID, UUID, VARCHAR, TEXT, INTEGER, INTEGER, INET, TEXT) IS 
'Logs an API access to the audit log';

-- Function: Detect suspicious access
CREATE OR REPLACE FUNCTION api.flag_suspicious_access()
RETURNS TRIGGER AS $$
BEGIN
    -- Flag if: unusual hour, high frequency, failed auth, foreign IP
    IF EXTRACT(HOUR FROM NEW.request_at) NOT BETWEEN 6 AND 23 THEN
        NEW.is_suspicious := TRUE;
        NEW.suspicion_reason := COALESCE(NEW.suspicion_reason || '; ', '') || 'off_hours';
    END IF;
    
    IF NEW.response_status IN (401, 403) THEN
        NEW.is_suspicious := TRUE;
        NEW.suspicion_reason := COALESCE(NEW.suspicion_reason || '; ', '') || 'auth_failure';
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_flag_suspicious ON api.access_audit_log;
CREATE TRIGGER trg_flag_suspicious
    BEFORE INSERT ON api.access_audit_log
    FOR EACH ROW
    EXECUTE FUNCTION api.flag_suspicious_access();

-- =============================================================================
-- RLS POLICIES
-- =============================================================================

DO $$
BEGIN
    ALTER TABLE api.key_scopes ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE api.key_scopes FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE api.access_audit_log ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE api.access_audit_log FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE api.service_accounts ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE api.marketplace_permissions ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE api.marketplace_permissions FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE api.session_contexts ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE api.session_contexts FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Application isolation
CREATE POLICY key_scopes_app_isolation ON api.key_scopes
    FOR ALL
    TO ussd_app_user
    USING (key_id IN (
        SELECT key_id FROM app.api_keys
        WHERE application_id = current_setting('app.current_application_id', true)::UUID
    ));

CREATE POLICY access_audit_app_isolation ON api.access_audit_log
    FOR ALL
    TO ussd_app_user
    USING (application_id = current_setting('app.current_application_id', true)::UUID);

CREATE POLICY service_accounts_admin ON api.service_accounts
    FOR ALL
    TO ussd_app_user
    USING (FALSE); -- Admin only

CREATE POLICY marketplace_perms_app_isolation ON api.marketplace_permissions
    FOR ALL
    TO ussd_app_user
    USING (marketplace_app_id = current_setting('app.current_application_id', true)::UUID
           OR participant_app_id = current_setting('app.current_application_id', true)::UUID);

CREATE POLICY session_contexts_app_isolation ON api.session_contexts
    FOR ALL
    TO ussd_app_user
    USING (application_id = current_setting('app.current_application_id', true)::UUID);

-- =============================================================================
-- WORM TRIGGERS (Immutability for audit logs)
-- =============================================================================

CREATE TRIGGER trg_access_audit_prevent_update
    BEFORE UPDATE ON api.access_audit_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_access_audit_prevent_delete
    BEFORE DELETE ON api.access_audit_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

-- =============================================================================
-- GRANTS
-- =============================================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON api.key_scopes TO ussd_app_user;
GRANT SELECT, INSERT ON api.access_audit_log TO ussd_app_user;
GRANT SELECT ON api.marketplace_permissions TO ussd_app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.session_contexts TO ussd_app_user;

COMMIT;
