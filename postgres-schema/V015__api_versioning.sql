-- =============================================================================
-- Migration: V014__api_versioning
-- Description: API Versioning and Environment Separation
-- Dependencies: V001-V013
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- API VERSIONS
-- =============================================================================

CREATE TABLE IF NOT EXISTS app.api_versions (
    version_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Version identification
    application_id UUID NOT NULL,
    api_version VARCHAR(20) NOT NULL, -- e.g., 'v1', 'v2', 'v2.1'
    
    -- Version status
    version_status VARCHAR(20) DEFAULT 'active' 
        CHECK (version_status IN ('draft', 'active', 'deprecated', 'sunset', 'retired')),
    
    -- Version metadata
    version_name VARCHAR(100),
    release_notes TEXT,
    
    -- Compatibility
    base_version_id UUID REFERENCES app.api_versions(version_id) ON DELETE SET NULL,
    is_backward_compatible BOOLEAN DEFAULT TRUE,
    breaking_changes TEXT[],
    
    -- Routing
    route_prefix VARCHAR(50), -- e.g., '/api/v2'
    
    -- Lifecycle
    released_at TIMESTAMPTZ,
    deprecated_at TIMESTAMPTZ,
    sunset_at TIMESTAMPTZ, -- End of life date
    
    -- Usage tracking
    request_count INTEGER DEFAULT 0,
    error_rate NUMERIC(5, 4) DEFAULT 0,
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    UNIQUE (application_id, api_version)
);

CREATE INDEX IF NOT EXISTS idx_api_versions_app 
    ON app.api_versions(application_id, version_status);

CREATE INDEX IF NOT EXISTS idx_api_versions_status 
    ON app.api_versions(version_status, sunset_at) 
    WHERE version_status IN ('deprecated', 'sunset');

COMMENT ON TABLE app.api_versions IS 'API versioning for simultaneous multiple version support';

-- =============================================================================
-- API ENDPOINTS (Per Version)
-- =============================================================================

CREATE TABLE IF NOT EXISTS app.api_endpoints (
    endpoint_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    version_id UUID NOT NULL REFERENCES app.api_versions(version_id) ON DELETE CASCADE,
    
    -- Endpoint definition
    http_method VARCHAR(10) NOT NULL 
        CHECK (http_method IN ('GET', 'POST', 'PUT', 'PATCH', 'DELETE')),
    path_pattern VARCHAR(255) NOT NULL,
    
    -- Handler
    handler_name VARCHAR(255) NOT NULL,
    handler_function VARCHAR(255),
    
    -- Configuration
    requires_auth BOOLEAN DEFAULT TRUE,
    required_permissions TEXT[],
    rate_limit_override INTEGER, -- NULL = use default
    
    -- Request/Response
    request_schema JSONB,
    response_schema JSONB,
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    is_deprecated BOOLEAN DEFAULT FALSE,
    deprecation_notice TEXT,
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    UNIQUE (version_id, http_method, path_pattern)
);

CREATE INDEX IF NOT EXISTS idx_api_endpoints_version 
    ON app.api_endpoints(version_id, is_active);

COMMENT ON TABLE app.api_endpoints IS 'API endpoints per version';

-- =============================================================================
-- ENVIRONMENT CONFIGURATION
-- =============================================================================

CREATE TABLE IF NOT EXISTS app.environments (
    environment_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Environment identification
    application_id UUID NOT NULL,
    environment_name VARCHAR(50) NOT NULL 
        CHECK (environment_name IN ('development', 'staging', 'sandbox', 'production')),
    
    -- Environment settings
    is_production BOOLEAN DEFAULT FALSE,
    is_isolated BOOLEAN DEFAULT TRUE, -- Data isolation from other environments
    
    -- Configuration
    config_overrides JSONB, -- Override base configuration (NULL = use defaults)
    feature_flags JSONB, -- Environment-specific features (NULL = use global defaults)
    
    -- Resource limits
    max_sessions INTEGER DEFAULT 1000,
    max_requests_per_minute INTEGER DEFAULT 1000,
    max_concurrent_requests INTEGER DEFAULT 100,
    
    -- Provider routing (sandbox uses different adapters)
    provider_adapter_overrides JSONB, -- Provider-specific overrides (NULL = use global config)
    
    -- Data retention (shorter for non-prod)
    data_retention_days INTEGER DEFAULT 30,
    log_retention_days INTEGER DEFAULT 7,
    
    -- Access control
    allowed_ip_ranges INET[],
    require_vpn BOOLEAN DEFAULT FALSE,
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    UNIQUE (application_id, environment_name)
);

CREATE INDEX IF NOT EXISTS idx_environments_app 
    ON app.environments(application_id, is_active);

CREATE INDEX IF NOT EXISTS idx_environments_prod 
    ON app.environments(is_production, is_active);

COMMENT ON TABLE app.environments IS 'Environment-specific configuration (sandbox/production separation)';

-- =============================================================================
-- ENVIRONMENT ISOLATION POLICIES
-- =============================================================================

CREATE TABLE IF NOT EXISTS app.environment_isolation_policies (
    policy_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Policy scope
    application_id UUID NOT NULL,
    
    -- Isolation rules
    source_environment VARCHAR(50) NOT NULL,
    target_environment VARCHAR(50) NOT NULL,
    
    -- Allowed operations
    allow_data_sync BOOLEAN DEFAULT FALSE,
    allow_config_sync BOOLEAN DEFAULT FALSE,
    allow_user_sync BOOLEAN DEFAULT FALSE,
    
    -- Sync conditions
    sync_conditions JSONB, -- Data sync conditions (NULL = no sync allowed)
    
    -- Data masking for non-prod
    mask_pii_in_non_prod BOOLEAN DEFAULT TRUE,
    mask_financial_data BOOLEAN DEFAULT TRUE,
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    CHECK (source_environment != target_environment),
    UNIQUE (application_id, source_environment, target_environment)
);

COMMENT ON TABLE app.environment_isolation_policies IS 'Data isolation policies between environments';

-- =============================================================================
-- API REQUEST LOG (Version tracking)
-- =============================================================================

CREATE TABLE IF NOT EXISTS app.api_request_log (
    log_id UUID DEFAULT gen_random_uuid(),
    
    -- Request identification
    request_id VARCHAR(255) NOT NULL,
    CONSTRAINT uq_app_api_request_log_request_id UNIQUE (request_id, request_started_at),
    correlation_id VARCHAR(255),
    
    -- Version info
    application_id UUID NOT NULL,
    api_version VARCHAR(20) NOT NULL,
    endpoint_id UUID,
    
    -- Environment
    environment VARCHAR(50) NOT NULL,
    
    -- Request details
    http_method VARCHAR(10) NOT NULL,
    request_path TEXT NOT NULL,
    request_headers JSONB,
    request_body JSONB,
    
    -- Response details
    response_status INTEGER,
    response_headers JSONB,
    response_body JSONB,
    
    -- Performance
    request_started_at TIMESTAMPTZ NOT NULL,
    request_ended_at TIMESTAMPTZ,
    duration_ms INTEGER,
    
    -- Client info
    client_ip INET,
    user_agent TEXT,
    api_key_id UUID,
    
    -- Status
    is_error BOOLEAN DEFAULT FALSE,
    error_code VARCHAR(100),
    error_message TEXT,
    
    -- Partition key
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT pk_app_api_request_log_log_id_request_started_at PRIMARY KEY (log_id, request_started_at));

-- Convert to hypertable
SELECT create_hypertable(
    'app.api_request_log',
    'request_started_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_api_log_app_version 
    ON app.api_request_log(application_id, api_version, request_started_at DESC);

CREATE INDEX IF NOT EXISTS idx_api_log_environment 
    ON app.api_request_log(environment, request_started_at DESC);

CREATE INDEX IF NOT EXISTS idx_api_log_correlation 
    ON app.api_request_log(correlation_id) 
    WHERE correlation_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_api_log_errors 
    ON app.api_request_log(application_id, is_error, request_started_at DESC) 
    WHERE is_error = TRUE;

COMMENT ON TABLE app.api_request_log IS 'API request log with version and environment tracking';

-- =============================================================================
-- TRIGGERS (Mixed: Audit logs are WORM, operational tables need updates)
-- =============================================================================

-- API request log is immutable audit trail
CREATE TRIGGER trg_api_request_log_prevent_update
    BEFORE UPDATE ON app.api_request_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_api_request_log_prevent_delete
    BEFORE DELETE ON app.api_request_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

CREATE TRIGGER trg_api_request_log_prevent_truncate
    BEFORE TRUNCATE ON app.api_request_log
    FOR EACH STATEMENT
    EXECUTE FUNCTION core.prevent_truncate();

-- API versions, endpoints, and environments are operational - need updates
DROP TRIGGER IF EXISTS trg_api_versions_timestamp ON app.api_versions;
CREATE TRIGGER trg_api_versions_timestamp
    BEFORE UPDATE ON app.api_versions
    FOR EACH ROW
    EXECUTE FUNCTION core.update_timestamp();

DROP TRIGGER IF EXISTS trg_api_endpoints_timestamp ON app.api_endpoints;
CREATE TRIGGER trg_api_endpoints_timestamp
    BEFORE UPDATE ON app.api_endpoints
    FOR EACH ROW
    EXECUTE FUNCTION core.update_timestamp();

DROP TRIGGER IF EXISTS trg_environments_timestamp ON app.environments;
CREATE TRIGGER trg_environments_timestamp
    BEFORE UPDATE ON app.environments
    FOR EACH ROW
    EXECUTE FUNCTION core.update_timestamp();

DROP TRIGGER IF EXISTS trg_environment_policies_timestamp ON app.environment_isolation_policies;
CREATE TRIGGER trg_environment_policies_timestamp
    BEFORE UPDATE ON app.environment_isolation_policies
    FOR EACH ROW
    EXECUTE FUNCTION core.update_timestamp();

COMMIT;
