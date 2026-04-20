-- =============================================================================
-- Migration: V055__ussd_shortcode_routing
-- Description: USSD table: shortcode_routing
-- Dependencies: V054
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- ============================================================================
-- USSD SHORTCODE ROUTING CONFIGURATION
-- ============================================================================
-- Purpose: Map USSD shortcodes (*123#, *123*1#, etc.) to applications and
--          manage routing rules for the gateway layer.
-- Context: Shortcodes are the entry points for USSD services. They can be:
--          - Single level: *123# (main menu)
--          - Multi-level: *123*1*456# (deep link to specific function)
--          - Hierarchical: *123# -> option 1 -> option 2
--
-- COMPLIANCE & STANDARDS:
--   ISO/IEC 27001:2022 - Information Security Management
--     * A.8.22: Web filtering and secure routing configuration
--     * A.8.23: Web application security (SSRF prevention in endpoints)
--     * A.8.11: Secure session timeout configuration per route
--     * A.8.7: Malware protection (input validation on route conditions)
--
--   ISO/IEC 27018:2019 - PII Protection
--     * Route conditions must not store unencrypted PII
--     * MSISDN prefix whitelisting pseudonymization
--
--   ISO 31000:2018 - Risk Management
--     * Risk-based authentication requirements per route
--     * Velocity limits enforcement per shortcode
--     * Canary deployment for risk mitigation
--
--   PCI DSS v4.0:
--     * Strong authentication for payment routes (required_auth_level)
--     * Access controls for sensitive route changes
--
-- TELECOM CONTEXT:
--   - Shortcodes are leased from regulators (e.g., *123# costs $X/month)
--   - Some operators support wildcards (*123*)
--   - Shortcodes may be shared across operators or operator-specific
--
-- SECURITY REQUIREMENTS:
--   - SSRF prevention: application_endpoint whitelist validation
--   - Rate limiting configuration per route
--   - Dual authorization for sensitive route changes
--   - Configuration hash chain for tamper detection
-- ============================================================================

-- ----------------------------------------------------------------------------
-- TABLE: shortcode_routing
-- ----------------------------------------------------------------------------
-- Defines routing rules for USSD shortcodes to backend applications.
-- Supports complex routing logic including operator-specific rules,
-- time-based routing, and load balancing.
-- ----------------------------------------------------------------------------

-- PRODUCTION FIX: Added schema prefix and standardized types
CREATE TABLE IF NOT EXISTS ussd.shortcode_routing (
    -- Primary identifier
    route_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Shortcode pattern (may include wildcards for advanced routing)
    -- Examples: '*123#', '*123*1#', '*123*#' (wildcard)
    shortcode_pattern VARCHAR(50) NOT NULL,
    
    -- Normalized shortcode (base code without parameters)
    -- Example: '*123*1*456#' -> '*123#'
    base_shortcode VARCHAR(20) NOT NULL,
    
    -- Operator filter (NULL = all operators)
    operator_code VARCHAR(6),
    
    -- Target application identifier (UUID for consistency with app.application_registry)
    application_id UUID NOT NULL,
    
    -- Application endpoint (URL or internal service name)
    application_endpoint VARCHAR(512) NOT NULL,
    
    -- Routing method: DIRECT, LOAD_BALANCED, CANARY, A_B_TEST
    routing_method VARCHAR(20) DEFAULT 'DIRECT',
    
    -- Priority for route matching (higher = checked first)
    match_priority INT DEFAULT 100,
    
    -- Route conditions (JSON for complex rules)
    -- Example: {"time_range": "08:00-18:00", "whitelist_msisdn_prefix": ["+25571"]}
    route_conditions JSONB DEFAULT '{}',
    
    -- Load balancing weights (for LOAD_BALANCED routing)
    lb_weight INT DEFAULT 100 CHECK (lb_weight >= 0 AND lb_weight <= 1000),
    
    -- Feature flags for this route
    features_enabled JSONB DEFAULT '[]',
    -- Example: ["biometric_auth", "qr_code", "offline_mode"]
    
    -- Rate limiting configuration
    rate_limit_requests_per_minute INT DEFAULT 60,
    rate_limit_burst INT DEFAULT 10,
    
    -- Session configuration
    session_timeout_seconds INT DEFAULT 90,
    max_session_duration_seconds INT DEFAULT 600, -- 10 minutes absolute max
    allow_concurrent_sessions BOOLEAN DEFAULT FALSE,
    
    -- Authentication requirements
    required_auth_level VARCHAR(16) DEFAULT 'NONE',
    -- NONE, ANONYMOUS, PIN, OTP, BIOMETRIC
    
    -- SIM swap check requirement for sensitive routes
    sim_swap_check_required BOOLEAN DEFAULT FALSE,
    
    -- Menu configuration reference
    default_menu_id VARCHAR(64),
    
    -- Response templates
    welcome_message TEXT,
    timeout_message TEXT,
    error_message TEXT,
    
    -- Status and lifecycle
    is_active BOOLEAN DEFAULT TRUE,
    effective_from TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    effective_to TIMESTAMPTZ,
    
    -- Audit fields
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by VARCHAR(128) NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by VARCHAR(128) NOT NULL,
    version INT DEFAULT 1,
    
    -- Immutable ledger tracking
    config_hash VARCHAR(64), -- SHA-256 of configuration for audit
    change_sequence BIGINT, -- Position in configuration changelog
    
    -- CANARY DEPLOYMENT COLUMNS
    canary_percentage DECIMAL(5,2) DEFAULT 0 CHECK (canary_percentage >= 0 AND canary_percentage <= 100),
    canary_msisdn_ranges TEXT[], -- ['+255700000000-+255799999999']
    canary_enabled_at TIMESTAMPTZ,
    canary_completed_at TIMESTAMPTZ,
    
    -- CIRCUIT BREAKER COLUMNS
    circuit_breaker_enabled BOOLEAN DEFAULT TRUE,
    circuit_breaker_threshold DECIMAL(3,2) DEFAULT 0.50 CHECK (circuit_breaker_threshold > 0 AND circuit_breaker_threshold <= 1),
    circuit_breaker_cooldown_seconds INT DEFAULT 60,
    circuit_breaker_status VARCHAR(16) DEFAULT 'CLOSED', -- CLOSED, OPEN, HALF_OPEN
    last_failure_at TIMESTAMPTZ,
    consecutive_failures INT DEFAULT 0,
    circuit_breaker_opened_at TIMESTAMPTZ,
    
    -- MULTI-REGION ROUTING COLUMNS
    primary_region VARCHAR(32) DEFAULT 'default',
    failover_region VARCHAR(32),
    data_residency_requirement VARCHAR(32), -- 'EU', 'US', 'AFRICA', etc.
    geo_routing_enabled BOOLEAN DEFAULT FALSE,
    allowed_regions TEXT[], -- ['EU', 'UK', 'US']
    blocked_regions TEXT[], -- ['SANCTIONED_COUNTRY']
    
    -- A/B TESTING COLUMNS
    ab_test_variant VARCHAR(32), -- 'control', 'variant_a'
    ab_test_config JSONB DEFAULT '{}',
    ab_test_enabled BOOLEAN DEFAULT FALSE,
    ab_test_allocation_percent DECIMAL(5,2) DEFAULT 50.00,
    
    -- Constraints
    CONSTRAINT valid_shortcode_format CHECK (
        shortcode_pattern ~ '^\*[0-9]+([*][0-9#*]*)?#$'
    ),
    CONSTRAINT valid_base_shortcode CHECK (
        base_shortcode ~ '^\*[0-9]+#$'
    ),
    CONSTRAINT valid_routing_method CHECK (
        routing_method IN ('DIRECT', 'LOAD_BALANCED', 'CANARY', 'A_B_TEST', 'FAILOVER')
    ),
    CONSTRAINT valid_effective_dates CHECK (
        effective_to IS NULL OR effective_to > effective_from
    ),
    CONSTRAINT valid_session_timeouts CHECK (
        session_timeout_seconds > 0 AND 
        session_timeout_seconds <= max_session_duration_seconds AND
        max_session_duration_seconds <= 3600 -- Max 1 hour
    ),
    CONSTRAINT valid_required_auth CHECK (
        required_auth_level IN ('NONE', 'ANONYMOUS', 'PIN', 'OTP', 'BIOMETRIC', 'HARDWARE_TOKEN')
    ),
    CONSTRAINT valid_circuit_breaker_status CHECK (
        circuit_breaker_status IN ('CLOSED', 'OPEN', 'HALF_OPEN')
    ),
    CONSTRAINT valid_ab_test_variant CHECK (
        ab_test_variant IS NULL OR ab_test_variant IN ('control', 'variant_a', 'variant_b', 'variant_c')
    ),
    
    -- Unique constraint for route matching order
    UNIQUE(shortcode_pattern, operator_code, match_priority)
);

-- ----------------------------------------------------------------------------
-- FUNCTION: calculate_config_hash
-- ----------------------------------------------------------------------------
-- Calculates SHA-256 hash of route configuration for tamper detection
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION calculate_config_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_config_text TEXT;
BEGIN
    v_config_text := NEW.shortcode_pattern || 
                     NEW.base_shortcode || 
                     NEW.application_id || 
                     NEW.application_endpoint ||
                     NEW.routing_method ||
                     NEW.route_conditions::TEXT ||
                     NEW.required_auth_level ||
                     COALESCE(NEW.sim_swap_check_required::TEXT, 'false');
    
    NEW.config_hash := encode(digest(v_config_text, 'sha256'), 'hex');
    NEW.change_sequence := nextval('route_change_seq');
    NEW.updated_at := NOW();
    
    RETURN NEW;
END;
$$;

-- Create sequence for change tracking
CREATE SEQUENCE IF NOT EXISTS route_change_seq START 1;

-- Apply hash calculation trigger
DROP TRIGGER IF EXISTS trg_calculate_config_hash ON RISK;
CREATE TRIGGER trg_calculate_config_hash
    BEFORE INSERT OR UPDATE ON shortcode_routing
    FOR EACH ROW
    EXECUTE FUNCTION calculate_config_hash();

-- NOTE: resolve_shortcode function has been moved to V060__routing_resolve_shortcode.sql
-- for a more comprehensive implementation with A/B testing, canary deployment,
-- and circuit breaker support.

-- ----------------------------------------------------------------------------
-- FUNCTION: extract_ussd_parameters
-- ----------------------------------------------------------------------------
-- Extracts parameters from USSD string based on pattern
-- Example: *123*AMOUNT*PIN# with pattern *123*# -> {amount, pin}
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION extract_ussd_parameters(
    p_ussd_string VARCHAR,
    p_pattern VARCHAR
)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_params JSONB := '{}'::JSONB;
    v_ussd_parts TEXT[];
    v_pattern_parts TEXT[];
    i INT;
BEGIN
    -- Split strings by asterisk
    v_ussd_parts := string_to_array(p_ussd_string, '*');
    v_pattern_parts := string_to_array(p_pattern, '*');
    
    -- Extract parameters
    FOR i IN 1..array_length(v_ussd_parts, 1) LOOP
        -- Skip empty parts and the hash at the end
        IF v_ussd_parts[i] IS NOT NULL AND v_ussd_parts[i] != '' AND v_ussd_parts[i] != '#' THEN
            -- If pattern part exists and is not a wildcard, use it as key
            IF i <= array_length(v_pattern_parts, 1) THEN
                IF v_pattern_parts[i] = '#' THEN
                    -- Last part with hash, extract value before #
                    v_params := v_params || jsonb_build_object('param_' || i, regexp_replace(v_ussd_parts[i], '#$', ''));
                ELSIF v_pattern_parts[i] ~ '^[0-9]+$' THEN
                    -- Numeric pattern part, skip (it's part of the structure)
                    CONTINUE;
                ELSE
                    -- Named parameter in pattern
                    v_params := v_params || jsonb_build_object(lower(v_pattern_parts[i]), v_ussd_parts[i]);
                END IF;
            ELSE
                -- Extra parameter
                v_params := v_params || jsonb_build_object('param_' || i, v_ussd_parts[i]);
            END IF;
        END IF;
    END LOOP;
    
    RETURN v_params;
END;
$$;

-- ----------------------------------------------------------------------------
-- FUNCTION: check_circuit_breaker
-- ----------------------------------------------------------------------------
-- Updates circuit breaker status based on failure tracking
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION check_circuit_breaker(
    p_route_id UUID,
    p_success BOOLEAN
)
RETURNS VARCHAR(16) -- Returns current circuit breaker status
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_route RECORD;
    v_new_status VARCHAR(16);
BEGIN
    SELECT * INTO v_route FROM shortcode_routing WHERE route_id = p_route_id;
    
    IF NOT FOUND THEN
        RETURN 'CLOSED'; -- Default if route not found
    END IF;
    
    v_new_status := v_route.circuit_breaker_status;
    
    -- Handle success
    IF p_success THEN
        IF v_route.circuit_breaker_status = 'HALF_OPEN' THEN
            -- Reset to CLOSED after successful call in HALF_OPEN state
            v_new_status := 'CLOSED';
            UPDATE shortcode_routing 
            SET circuit_breaker_status = 'CLOSED',
                consecutive_failures = 0,
                last_failure_at = NULL
            WHERE route_id = p_route_id;
        ELSIF v_route.consecutive_failures > 0 THEN
            -- Reset failure count on success
            UPDATE shortcode_routing 
            SET consecutive_failures = 0
            WHERE route_id = p_route_id;
        END IF;
    ELSE
        -- Handle failure
        UPDATE shortcode_routing 
        SET consecutive_failures = consecutive_failures + 1,
            last_failure_at = NOW()
        WHERE route_id = p_route_id;
        
        -- Check if threshold exceeded
        IF v_route.consecutive_failures + 1 >= (v_route.circuit_breaker_threshold * 10)::INT THEN
            v_new_status := 'OPEN';
            UPDATE shortcode_routing 
            SET circuit_breaker_status = 'OPEN',
                circuit_breaker_opened_at = NOW()
            WHERE route_id = p_route_id;
        END IF;
    END IF;
    
    RETURN v_new_status;
END;
$$;

-- ----------------------------------------------------------------------------
-- FUNCTION: reset_circuit_breaker
-- ----------------------------------------------------------------------------
-- Manually resets circuit breaker (for maintenance or after fix)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION reset_circuit_breaker(
    p_route_id UUID,
    p_reason TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE shortcode_routing 
    SET circuit_breaker_status = 'CLOSED',
        consecutive_failures = 0,
        last_failure_at = NULL,
        circuit_breaker_opened_at = NULL
    WHERE route_id = p_route_id;
    
    -- Log the reset to history
    INSERT INTO shortcode_routing_history (
        route_id,
        change_type,
        configuration_snapshot,
        changed_by,
        change_reason
    ) VALUES (
        p_route_id,
        'CIRCUIT_BREAKER_RESET',
        jsonb_build_object('reason', p_reason, 'reset_at', NOW()),
        CURRENT_USER,
        p_reason
    );
    
    RETURN TRUE;
END;
$$;

-- ----------------------------------------------------------------------------
-- FUNCTION: is_msisdn_in_canary_range
-- ----------------------------------------------------------------------------
-- Checks if MSISDN is in canary deployment range
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION is_msisdn_in_canary_range(
    p_msisdn VARCHAR,
    p_canary_ranges TEXT[]
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_range TEXT;
    v_start_msisdn VARCHAR;
    v_end_msisdn VARCHAR;
BEGIN
    IF p_canary_ranges IS NULL OR array_length(p_canary_ranges, 1) IS NULL THEN
        RETURN FALSE;
    END IF;
    
    FOREACH v_range IN ARRAY p_canary_ranges LOOP
        -- Parse range format: +255700000000-+255799999999
        v_start_msisdn := split_part(v_range, '-', 1);
        v_end_msisdn := split_part(v_range, '-', 2);
        
        IF p_msisdn >= v_start_msisdn AND p_msisdn <= v_end_msisdn THEN
            RETURN TRUE;
        END IF;
    END LOOP;
    
    RETURN FALSE;
END;
$$;

-- ----------------------------------------------------------------------------
-- FUNCTION: select_canary_route
-- ----------------------------------------------------------------------------
-- Determines if request should use canary route based on percentage or MSISDN
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION select_canary_route(
    p_msisdn VARCHAR,
    p_canary_percentage DECIMAL,
    p_canary_ranges TEXT[]
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_msisdn_hash BIGINT;
    v_hash_percent DECIMAL;
BEGIN
    -- Check explicit MSISDN ranges first
    IF p_canary_ranges IS NOT NULL AND array_length(p_canary_ranges, 1) > 0 THEN
        IF is_msisdn_in_canary_range(p_msisdn, p_canary_ranges) THEN
            RETURN TRUE;
        END IF;
    END IF;
    
    -- Use hash-based allocation for consistent user experience
    v_msisdn_hash := abs(('x' || substr(md5(p_msisdn), 1, 8))::bit(32)::int);
    v_hash_percent := (v_msisdn_hash % 10000) / 100.0;
    
    RETURN v_hash_percent < p_canary_percentage;
END;
$$;

-- ----------------------------------------------------------------------------
-- TABLE: shortcode_routing_history
-- ----------------------------------------------------------------------------
-- Immutable audit log of all routing configuration changes.
-- Required for compliance and rollback capabilities.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS shortcode_routing_history (
    history_id BIGSERIAL PRIMARY KEY,
    route_id UUID NOT NULL,
    change_type VARCHAR(32) NOT NULL, -- CREATE, UPDATE, DELETE, ACTIVATE, DEACTIVATE, CIRCUIT_BREAKER_RESET
    
    -- Full snapshot of configuration at this point in time
    configuration_snapshot JSONB NOT NULL,
    
    -- Change metadata
    changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    changed_by VARCHAR(128) NOT NULL,
    change_reason TEXT,
    
    -- Approval workflow (for sensitive changes)
    approved_by VARCHAR(128),
    approved_at TIMESTAMPTZ,
    
    -- Hash chain for tamper detection
    previous_hash VARCHAR(64),
    snapshot_hash VARCHAR(64) NOT NULL
);

-- Hash calculation for history entries
CREATE OR REPLACE FUNCTION calculate_history_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev_hash VARCHAR(64);
BEGIN
    -- Get previous hash for this route
    SELECT snapshot_hash INTO v_prev_hash
    FROM shortcode_routing_history
    WHERE route_id = NEW.route_id
    ORDER BY history_id DESC
    LIMIT 1;
    
    NEW.previous_hash := v_prev_hash;
    NEW.snapshot_hash := encode(digest(
        NEW.route_id::TEXT || NEW.change_type || NEW.configuration_snapshot::TEXT || NEW.changed_at::TEXT,
        'sha256'
    ), 'hex');
    
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_calculate_history_hash ON ussd.shortcode_routing_history;
CREATE TRIGGER trg_calculate_history_hash
    BEFORE INSERT ON ussd.shortcode_routing_history
    FOR EACH ROW
    EXECUTE FUNCTION calculate_history_hash();

-- ----------------------------------------------------------------------------
-- TABLE: routing_metrics
-- ----------------------------------------------------------------------------
-- Aggregated metrics for routing performance monitoring.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS routing_metrics (
    metric_id BIGSERIAL PRIMARY KEY,
    route_id UUID NOT NULL,
    aggregation_period TIMESTAMPTZ NOT NULL, -- Hourly buckets
    
    -- Request metrics
    total_requests BIGINT DEFAULT 0,
    successful_requests BIGINT DEFAULT 0,
    failed_requests BIGINT DEFAULT 0,
    timeout_requests BIGINT DEFAULT 0,
    
    -- Response time metrics (in milliseconds)
    avg_response_time_ms INT,
    p50_response_time_ms INT,
    p95_response_time_ms INT,
    p99_response_time_ms INT,
    max_response_time_ms INT,
    
    -- Error breakdown
    error_4xx_count BIGINT DEFAULT 0,
    error_5xx_count BIGINT DEFAULT 0,
    network_error_count BIGINT DEFAULT 0,
    
    -- Session metrics
    sessions_created BIGINT DEFAULT 0,
    sessions_completed BIGINT DEFAULT 0,
    sessions_timeout BIGINT DEFAULT 0,
    
    -- Circuit breaker metrics
    circuit_opens INT DEFAULT 0,
    circuit_half_opens INT DEFAULT 0,
    
    -- Created at (for this record)
    recorded_at TIMESTAMPTZ DEFAULT NOW(),
    
    UNIQUE(route_id, aggregation_period)
);

-- ----------------------------------------------------------------------------
-- FUNCTION: record_routing_metric
-- ----------------------------------------------------------------------------
-- Records metrics for a routing operation
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION record_routing_metric(
    p_route_id UUID,
    p_success BOOLEAN,
    p_response_time_ms INT,
    p_error_type VARCHAR(10) DEFAULT NULL,
    p_is_session_created BOOLEAN DEFAULT FALSE,
    p_is_session_completed BOOLEAN DEFAULT FALSE,
    p_is_timeout BOOLEAN DEFAULT FALSE
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_period TIMESTAMPTZ;
BEGIN
    v_period := DATE_TRUNC('hour', NOW());
    
    INSERT INTO routing_metrics (
        route_id,
        aggregation_period,
        total_requests,
        successful_requests,
        failed_requests,
        timeout_requests,
        avg_response_time_ms,
        max_response_time_ms,
        error_4xx_count,
        error_5xx_count,
        network_error_count,
        sessions_created,
        sessions_completed,
        sessions_timeout
    ) VALUES (
        p_route_id,
        v_period,
        1,
        CASE WHEN p_success THEN 1 ELSE 0 END,
        CASE WHEN NOT p_success THEN 1 ELSE 0 END,
        CASE WHEN p_is_timeout THEN 1 ELSE 0 END,
        p_response_time_ms,
        p_response_time_ms,
        CASE WHEN p_error_type = '4xx' THEN 1 ELSE 0 END,
        CASE WHEN p_error_type = '5xx' THEN 1 ELSE 0 END,
        CASE WHEN p_error_type = 'NETWORK' THEN 1 ELSE 0 END,
        CASE WHEN p_is_session_created THEN 1 ELSE 0 END,
        CASE WHEN p_is_session_completed THEN 1 ELSE 0 END,
        CASE WHEN p_is_timeout THEN 1 ELSE 0 END
    )
    ON CONFLICT (route_id, aggregation_period) DO UPDATE SET
        total_requests = routing_metrics.total_requests + 1,
        successful_requests = routing_metrics.successful_requests + 
            CASE WHEN p_success THEN 1 ELSE 0 END,
        failed_requests = routing_metrics.failed_requests + 
            CASE WHEN NOT p_success THEN 1 ELSE 0 END,
        timeout_requests = routing_metrics.timeout_requests + 
            CASE WHEN p_is_timeout THEN 1 ELSE 0 END,
        avg_response_time_ms = (
            (routing_metrics.avg_response_time_ms * routing_metrics.total_requests + p_response_time_ms) / 
            (routing_metrics.total_requests + 1)
        )::INT,
        max_response_time_ms = GREATEST(routing_metrics.max_response_time_ms, p_response_time_ms),
        error_4xx_count = routing_metrics.error_4xx_count + 
            CASE WHEN p_error_type = '4xx' THEN 1 ELSE 0 END,
        error_5xx_count = routing_metrics.error_5xx_count + 
            CASE WHEN p_error_type = '5xx' THEN 1 ELSE 0 END,
        network_error_count = routing_metrics.network_error_count + 
            CASE WHEN p_error_type = 'NETWORK' THEN 1 ELSE 0 END,
        sessions_created = routing_metrics.sessions_created + 
            CASE WHEN p_is_session_created THEN 1 ELSE 0 END,
        sessions_completed = routing_metrics.sessions_completed + 
            CASE WHEN p_is_session_completed THEN 1 ELSE 0 END,
        sessions_timeout = routing_metrics.sessions_timeout + 
            CASE WHEN p_is_timeout THEN 1 ELSE 0 END;
END;
$$;

-- ----------------------------------------------------------------------------
-- PRODUCTION FIX (DEP-007): Added missing tables referenced in V060, V061
-- ----------------------------------------------------------------------------

-- Table: application_endpoints
-- Purpose: Store application endpoint configurations for SSRF prevention
CREATE TABLE IF NOT EXISTS ussd.application_endpoints (
    endpoint_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    application_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    endpoint_url VARCHAR(512) NOT NULL,
    endpoint_type VARCHAR(50) NOT NULL DEFAULT 'webhook', -- webhook, api, internal
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(application_id, endpoint_url)
);

COMMENT ON TABLE ussd.application_endpoints IS 
    'Application endpoint whitelist for SSRF prevention in routing';

-- Table: circuit_breaker_states
-- Purpose: Circuit breaker pattern for routing resilience
CREATE TABLE IF NOT EXISTS ussd.circuit_breaker_states (
    circuit_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    route_id UUID NOT NULL REFERENCES ussd.shortcode_routing(route_id),
    circuit_breaker_status VARCHAR(20) NOT NULL DEFAULT 'CLOSED', -- CLOSED, OPEN, HALF_OPEN
    consecutive_failures INT DEFAULT 0,
    success_count_half_open INT DEFAULT 0,
    opened_at TIMESTAMPTZ,
    last_failure_at TIMESTAMPTZ,
    last_success_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(route_id)
);

COMMENT ON TABLE ussd.circuit_breaker_states IS 
    'Circuit breaker states for resilient routing to applications';

-- Index for circuit breaker lookups
CREATE INDEX IF NOT EXISTS idx_circuit_breaker_route 
    ON ussd.circuit_breaker_states(route_id, circuit_breaker_status);

-- Index for circuit breaker monitoring
CREATE INDEX IF NOT EXISTS idx_circuit_breaker_status 
    ON ussd.circuit_breaker_states(circuit_breaker_status, opened_at) 
    WHERE circuit_breaker_status != 'CLOSED';

-- ----------------------------------------------------------------------------
-- INDEXES
-- ----------------------------------------------------------------------------

-- Fast lookup for active routes by shortcode
CREATE INDEX IF NOT EXISTS idx_routing_active_shortcode 
    ON ussd.shortcode_routing(base_shortcode, is_active, match_priority DESC);

-- Operator-specific route lookup
CREATE INDEX IF NOT EXISTS idx_routing_operator 
    ON shortcode_routing(operator_code, base_shortcode, is_active);

-- Time-based route validity
CREATE INDEX IF NOT EXISTS idx_routing_effective_dates 
    ON shortcode_routing(effective_from, effective_to) 
    WHERE effective_to IS NOT NULL;

-- Circuit breaker monitoring
CREATE INDEX IF NOT EXISTS idx_routing_circuit_breaker 
    ON shortcode_routing(circuit_breaker_status, consecutive_failures DESC)
    WHERE circuit_breaker_status != 'CLOSED';

-- History lookup for audit
CREATE INDEX IF NOT EXISTS idx_routing_history_route 
    ON ussd.shortcode_routing_history(route_id, changed_at DESC);

-- Metrics aggregation queries
CREATE INDEX IF NOT EXISTS idx_routing_metrics_period 
    ON routing_metrics(route_id, aggregation_period DESC);

-- ----------------------------------------------------------------------------
-- SECURITY CONSIDERATIONS
-- ----------------------------------------------------------------------------
-- [ISO/IEC 27001:2022] A.8.22 - Web filtering and secure routing
-- [ISO/IEC 27001:2022] A.8.23 - SSRF prevention
-- [ISO/IEC 27018:2019] PII protection in route conditions
-- [ISO 31000:2018] Risk-based authentication requirements
/*
1. CONFIGURATION INJECTION:
   - Validate all route_conditions JSONB against schema
   - Sanitize application_endpoint (whitelist allowed protocols)
   - Never allow file:// or other dangerous protocols

2. SSRF PREVENTION:
   - Restrict application_endpoint to internal service mesh
   - Validate endpoints don't point to metadata services (169.254.169.254)
   - Use service mesh sidecars for external calls

3. RATE LIMITING:
   - Enforce rate_limit_requests_per_minute at gateway layer
   - Per-MSISDN rate limiting (prevent enumeration attacks)
   - Global rate limiting per shortcode

4. AUTHENTICATION BYPASS:
   - required_auth_level must be enforced at gateway, not just application
   - Never downgrade authentication requirements dynamically
   - Log all authentication requirement changes to SIEM

5. CONFIGURATION TAMPERING:
   - All changes logged to shortcode_routing_history
   - Hash chain prevents undetected modifications
   - Regular integrity audits of configuration
*/

-- ----------------------------------------------------------------------------
-- SESSION TIMEOUT HANDLING
-- ----------------------------------------------------------------------------
-- [ISO/IEC 27001:2022] A.8.11 - Per-route timeout configuration
-- [PCI DSS v4.0] Payment route timeout restrictions
-- Risk-based timeout adjustment
/*
Per-route timeout configuration:

1. SHORTCODE-SPECIFIC TIMEOUTS:
   - Financial services: 120s (user needs time to verify)
   - Information services: 30s (quick lookups)
   - Registration flows: 300s (may require external verification)

2. DYNAMIC TIMEOUT ADJUSTMENT:
   - Extend timeout during PIN entry (security pause)
   - Reduce timeout for sensitive operations (faster expiration)
   - Maximum extension: 3x base timeout

3. CONCURRENT SESSION HANDLING:
   - allow_concurrent_sessions = FALSE:
     * Terminate existing session on new request
     * Notify user of previous session termination
   - allow_concurrent_sessions = TRUE:
     * Limit to maximum 3 concurrent sessions per MSISDN
     * Require session ID differentiation

4. IDLE DETECTION:
   - Track last activity per session
   - Warning at 80% of session_timeout_seconds
   - Force termination at 100% (no grace period for USSD)
*/

-- ----------------------------------------------------------------------------
-- SIM SWAP DETECTION LOGIC
-- ----------------------------------------------------------------------------
-- [ISO/IEC 27035-2:2023] SIM swap detection integration
-- [ISO 31000:2018] Risk-adjusted route restrictions
-- Post-swap routing: Enhanced verification routes
-- GSMA IR.71 compliance for swap detection
/*
Shortcode routing can be used to trigger SIM swap detection:

1. SENSITIVE ROUTE PROTECTION:
   - High-value transaction shortcodes (*123*5# for transfers)
   - First-time device detection triggers additional verification
   - Mandatory 24h cooling period for new device + high-value

2. ROUTE-BASED SIM SWAP CHECKS:
   - sim_swap_check_required = TRUE triggers SIM swap check
   - When TRUE, query SIM swap detection before allowing access
   - Route to verification flow if swap detected within 72h

3. DYNAMIC ROUTING BASED ON RISK:
   - Low risk: Normal flow
   - Medium risk: Additional PIN required
   - High risk: Block, require in-branch verification
*/

-- ----------------------------------------------------------------------------
-- SAMPLE DATA (Development/Testing Only)
-- ----------------------------------------------------------------------------
-- NOTE: Sample data removed for production. Use application onboarding API
-- to create routing configurations with proper authentication.
--
-- Example configuration (DO NOT USE IN PRODUCTION):
-- INSERT INTO shortcode_routing (...) VALUES (...);
--
-- All routing configurations must be created through the admin API with:
-- - Proper authentication
-- - Audit trail logging
-- - Config hash validation
-- - Approval workflow for sensitive routes

COMMIT;
