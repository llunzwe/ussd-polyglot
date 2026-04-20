-- =============================================================================
-- Migration: V008__redis_cache_schema
-- Description: Redis Cache Schema for Session and Rate Limit Caching
-- Dependencies: V001-V004
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- CACHE KEY REGISTRY
-- =============================================================================

CREATE TABLE IF NOT EXISTS ussd.cache_key_registry (
    key_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Key identification
    cache_key VARCHAR(255) NOT NULL UNIQUE,
    key_pattern VARCHAR(255) NOT NULL, -- e.g., 'session:{session_id}'
    
    -- Key type
    key_type VARCHAR(50) NOT NULL 
        CHECK (key_type IN ('session', 'rate_limit', 'menu', 'user_data', 'provider_response', 'temp')),
    
    -- Application scope
    application_id UUID,
    
    -- TTL configuration
    default_ttl_seconds INTEGER NOT NULL DEFAULT 300,
    max_ttl_seconds INTEGER DEFAULT 3600,
    
    -- Key metadata
    description TEXT,
    example_value JSONB,
    
    -- Validation
    validation_schema JSONB, -- JSON schema for value validation
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_cache_registry_type 
    ON ussd.cache_key_registry(key_type);

CREATE INDEX IF NOT EXISTS idx_cache_registry_app 
    ON ussd.cache_key_registry(application_id);

COMMENT ON TABLE ussd.cache_key_registry IS 'Registry of cache key patterns and configurations';

-- =============================================================================
-- CACHE INVALIDATION LOG
-- =============================================================================

CREATE TABLE IF NOT EXISTS ussd.cache_invalidation_log (
    log_id UUID DEFAULT gen_random_uuid(),
    
    -- Invalidation details
    cache_key VARCHAR(255) NOT NULL,
    key_pattern VARCHAR(255) NOT NULL,
    
    -- Invalidation reason
    invalidation_reason VARCHAR(100) NOT NULL 
        CHECK (invalidation_reason IN ('expired', 'manual', 'dependency_change', 'session_end', 'data_update')),
    
    -- Source
    invalidated_by UUID,
    application_id UUID,
    
    -- Timing
    cached_at TIMESTAMPTZ,
    invalidated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Hit statistics (if available)
    hit_count INTEGER,
    miss_count INTEGER,
    
    -- Partition key
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT pk_ussd_cache_invalidation_log_log_id_invalidated_at PRIMARY KEY (log_id, invalidated_at));

-- Convert to hypertable
SELECT create_hypertable(
    'ussd.cache_invalidation_log',
    'invalidated_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_cache_invalidation_key 
    ON ussd.cache_invalidation_log(cache_key, invalidated_at DESC);

CREATE INDEX IF NOT EXISTS idx_cache_invalidation_app 
    ON ussd.cache_invalidation_log(application_id, invalidated_at DESC);

COMMENT ON TABLE ussd.cache_invalidation_log IS 'Log of cache invalidations for analysis';

-- =============================================================================
-- RATE LIMIT BUCKETS (Token Bucket Algorithm)
-- =============================================================================

CREATE TABLE IF NOT EXISTS ussd.rate_limit_buckets (
    bucket_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Bucket identification
    bucket_key VARCHAR(255) NOT NULL UNIQUE, -- e.g., 'api:{app_id}:{user_id}'
    
    -- Resource being limited
    resource_type VARCHAR(50) NOT NULL 
        CHECK (resource_type IN ('api_requests', 'ussd_sessions', 'sms_send', 'webhook_calls')),
    
    -- Application context
    application_id UUID NOT NULL,
    
    -- Token bucket state
    tokens NUMERIC(20, 8) NOT NULL DEFAULT 0,
    bucket_capacity NUMERIC(20, 8) NOT NULL,
    
    -- Rate configuration
    refill_rate_per_second NUMERIC(20, 8) NOT NULL,
    
    -- Timing
    last_refill_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Status
    is_blocked BOOLEAN DEFAULT FALSE,
    blocked_until TIMESTAMPTZ,
    block_reason VARCHAR(100),
    
    -- Statistics
    total_requests INTEGER DEFAULT 0,
    throttled_requests INTEGER DEFAULT 0,
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_rate_limit_buckets_key 
    ON ussd.rate_limit_buckets(bucket_key, is_blocked);

CREATE INDEX IF NOT EXISTS idx_rate_limit_buckets_app 
    ON ussd.rate_limit_buckets(application_id, resource_type);

CREATE INDEX IF NOT EXISTS idx_rate_limit_blocked 
    ON ussd.rate_limit_buckets(blocked_until) 
    WHERE is_blocked = TRUE;

COMMENT ON TABLE ussd.rate_limit_buckets IS 'Token bucket state for rate limiting';

-- =============================================================================
-- RATE LIMIT POLICIES (Per-Application)
-- =============================================================================

CREATE TABLE IF NOT EXISTS app.rate_limit_policies (
    policy_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Application
    application_id UUID NOT NULL,
    
    -- Resource type
    resource_type VARCHAR(50) NOT NULL 
        CHECK (resource_type IN ('api_requests', 'ussd_sessions', 'sms_send', 'webhook_calls')),
    
    -- Limits
    requests_per_minute INTEGER NOT NULL DEFAULT 60,
    requests_per_hour INTEGER DEFAULT 1000,
    requests_per_day INTEGER DEFAULT 10000,
    
    -- Burst configuration
    burst_capacity INTEGER DEFAULT 10,
    
    -- Auto-escalation
    auto_escalate BOOLEAN DEFAULT FALSE,
    escalation_threshold INTEGER, -- requests in 1 minute to trigger escalation
    escalation_multiplier NUMERIC(3, 2) DEFAULT 1.5,
    
    -- Cooldown
    cooldown_seconds INTEGER DEFAULT 60,
    
    -- Environment
    environment VARCHAR(20) DEFAULT 'production' 
        CHECK (environment IN ('sandbox', 'production')),
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    UNIQUE (application_id, resource_type, environment)
);

CREATE INDEX IF NOT EXISTS idx_rate_limit_policies_app 
    ON app.rate_limit_policies(application_id, environment);

COMMENT ON TABLE app.rate_limit_policies IS 'Per-application rate limiting policies with auto-escalation';

-- =============================================================================
-- SESSION STATE CACHE (Backup for Redis)
-- =============================================================================

CREATE TABLE IF NOT EXISTS ussd.session_state_cache (
    cache_entry_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Session reference
    session_id UUID NOT NULL UNIQUE,
    
    -- Cached state
    menu_id UUID,
    current_state VARCHAR(100),
    context_data JSONB,
    input_history JSONB,
    
    -- TTL
    expires_at TIMESTAMPTZ NOT NULL,
    
    -- Metadata
    version INTEGER DEFAULT 1,
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for cleanup
CREATE INDEX IF NOT EXISTS idx_session_cache_expiry 
    ON ussd.session_state_cache(expires_at);

COMMENT ON TABLE ussd.session_state_cache IS 'Session state cache backup (when Redis unavailable)';

-- =============================================================================
-- TRIGGERS (Operational tables - not WORM, they need updates)
-- =============================================================================

-- Cache invalidation log is immutable audit trail
CREATE TRIGGER trg_cache_invalidation_log_prevent_update
    BEFORE UPDATE ON ussd.cache_invalidation_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_cache_invalidation_log_prevent_delete
    BEFORE DELETE ON ussd.cache_invalidation_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

CREATE TRIGGER trg_cache_invalidation_log_prevent_truncate
    BEFORE TRUNCATE ON ussd.cache_invalidation_log
    FOR EACH STATEMENT
    EXECUTE FUNCTION core.prevent_truncate();

-- Cache key registry, rate limits, and session cache are operational - they need updates
-- Added standard timestamp update triggers instead of WORM

DROP TRIGGER IF EXISTS trg_cache_key_registry_timestamp ON ussd.cache_key_registry;
CREATE TRIGGER trg_cache_key_registry_timestamp
    BEFORE UPDATE ON ussd.cache_key_registry
    FOR EACH ROW
    EXECUTE FUNCTION core.update_timestamp();

DROP TRIGGER IF EXISTS trg_rate_limit_buckets_timestamp ON ussd.rate_limit_buckets;
CREATE TRIGGER trg_rate_limit_buckets_timestamp
    BEFORE UPDATE ON ussd.rate_limit_buckets
    FOR EACH ROW
    EXECUTE FUNCTION core.update_timestamp();

DROP TRIGGER IF EXISTS trg_rate_limit_policies_timestamp ON app.rate_limit_policies;
CREATE TRIGGER trg_rate_limit_policies_timestamp
    BEFORE UPDATE ON app.rate_limit_policies
    FOR EACH ROW
    EXECUTE FUNCTION core.update_timestamp();

DROP TRIGGER IF EXISTS trg_session_state_cache_timestamp ON ussd.session_state_cache;
CREATE TRIGGER trg_session_state_cache_timestamp
    BEFORE UPDATE ON ussd.session_state_cache
    FOR EACH ROW
    EXECUTE FUNCTION core.update_timestamp();

COMMIT;
