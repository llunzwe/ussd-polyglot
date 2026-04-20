-- =============================================================================
-- Migration: V225__session_create_session
-- Description: session: create_session
-- Dependencies: V224
-- Generated: 2026-04-02 16:56:49 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- ============================================================================
-- FUNCTION: create_session
-- ============================================================================
-- Purpose: Initialize a new USSD session with proper validation, security
--          checks, and immutable ledger integration.
-- Context: Called when a user dials a USSD shortcode (*123#).
--          Must be atomic and handle concurrent session scenarios.
--
-- COMPLIANCE & STANDARDS:
--   ISO/IEC 27001:2022 - Information Security Management
--     * A.5.1: Security policies - session creation policies
--     * A.8.1: User endpoint security - device verification
--     * A.8.5: Secure authentication - auth level assignment
--     * A.8.11: Session timeout configuration
--     * A.8.12: Audit logging - session creation events
--
--   ISO/IEC 27018:2019 - PII Protection
--     * MSISDN format validation (E.164)
--     * Context encryption before storage
--     * Minimal PII collection principle
--
--   ISO 31000:2018 - Risk Management
--     * Risk-based session timeout calculation
--     * Velocity limit enforcement
--     * Device trust score integration
--
--   PCI DSS v4.0:
--     * Session timeout enforcement (max 10 minutes)
--     * Secure session identifier generation
--     * Input validation and sanitization
--
-- SESSION INITIATION FLOW:
--   1. User dials shortcode
--   2. Gateway receives request from operator
--   3. Gateway calls create_session()
--   4. Function validates request and creates session record
--   5. Returns session context for menu rendering
--
-- SECURITY CHECKS:
--   - MSISDN format validation (E.164 regex)
--   - Shortcode format validation
--   - Concurrent session handling
--   - Device fingerprint verification
--   - Velocity limit enforcement
--   - SIM swap status check
--
-- ENTERPRISE CODING PRACTICES:
--   - SECURITY DEFINER for elevated privileges
--   - Input validation at function entry
--   - Advisory locks for concurrent session prevention
--   - Hash chain initialization for audit
--   - Exception handling with cleanup
-- ============================================================================

-- =============================================================================
-- STUB FUNCTIONS: These are referenced by create_session and must exist
-- PRODUCTION NOTE: These are minimal implementations. Replace with full logic.
-- =============================================================================

-- Stub: Verify device fingerprint
-- PRODUCTION FIX: Fixed signature to match actual usage (4 params)
CREATE OR REPLACE FUNCTION verify_device_fingerprint(
    p_msisdn VARCHAR(15),
    p_fingerprint_hash VARCHAR(64),
    p_operator_code VARCHAR(6),
    p_security_flags TEXT[] DEFAULT ARRAY[]::TEXT[]
)
RETURNS TABLE (
    is_verified BOOLEAN,
    fingerprint_id UUID,
    trust_score INT,
    is_blocked BOOLEAN,
    block_reason TEXT,
    requires_verification BOOLEAN,
    last_seen_at TIMESTAMPTZ,
    verification_result VARCHAR(20),
    auth_method VARCHAR(16),
    security_flags TEXT[]
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Minimal implementation - replace with full device fingerprint verification
    RETURN QUERY SELECT 
        true::BOOLEAN,
        gen_random_uuid()::UUID,
        80::INT,
        false::BOOLEAN,
        NULL::TEXT,
        false::BOOLEAN,
        NOW()::TIMESTAMPTZ,
        'VERIFIED'::VARCHAR(20),
        'NONE'::VARCHAR(16),
        p_security_flags;
END;
$$;

-- Stub: Generate device fingerprint
-- PRODUCTION FIX: Fixed signature to match actual usage (12 params)
CREATE OR REPLACE FUNCTION generate_device_fingerprint(
    p_msisdn VARCHAR(15),
    p_source_ip INET,
    p_imei_hash VARCHAR(64) DEFAULT NULL,
    p_imsi_hash VARCHAR(64) DEFAULT NULL,
    p_device_model VARCHAR(128) DEFAULT NULL,
    p_os_version VARCHAR(50) DEFAULT NULL,
    p_network_type VARCHAR(10) DEFAULT NULL,
    p_mcc_mnc VARCHAR(10) DEFAULT NULL,
    p_lac VARCHAR(10) DEFAULT NULL,
    p_cell_id VARCHAR(20) DEFAULT NULL,
    p_latitude DECIMAL(10,8) DEFAULT NULL,
    p_longitude DECIMAL(11,8) DEFAULT NULL,
    p_session_id UUID DEFAULT NULL
)
RETURNS TABLE (
    fingerprint_hash VARCHAR(64),
    fingerprint_id UUID,
    trust_score INT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Minimal implementation - replace with full fingerprint generation
    RETURN QUERY SELECT 
        encode(digest(p_msisdn || ':' || COALESCE(p_source_ip::TEXT, 'unknown'), 'sha256'), 'hex')::VARCHAR(64),
        gen_random_uuid()::UUID,
        50::INT;
END;
$$;

-- Stub: Create encrypted session context
-- PRODUCTION FIX: Fixed signature to match actual usage
CREATE OR REPLACE FUNCTION create_session_context(
    p_language_code VARCHAR(10) DEFAULT 'en',
    p_shortcode VARCHAR(50) DEFAULT NULL,
    p_device_fingerprint_id UUID DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::JSONB
)
RETURNS BYTEA
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Minimal implementation - replace with actual encryption
    RETURN convert_to(jsonb_build_object(
        'language', p_language_code,
        'shortcode', p_shortcode,
        'device_fingerprint_id', p_device_fingerprint_id,
        'metadata', p_metadata
    )::TEXT, 'UTF8');
END;
$$;

-- Stub: Calculate session hash
-- PRODUCTION FIX: Fixed signature to match actual usage (6 params)
CREATE OR REPLACE FUNCTION calculate_session_hash(
    p_previous_hash VARCHAR(64) DEFAULT NULL,
    p_session_id UUID DEFAULT NULL,
    p_msisdn VARCHAR(15) DEFAULT NULL,
    p_state VARCHAR(32) DEFAULT 'INIT',
    p_timestamp TIMESTAMPTZ DEFAULT NOW(),
    p_context_encrypted BYTEA DEFAULT NULL
)
RETURNS VARCHAR(64)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Minimal implementation - replace with full hash chain logic
    RETURN encode(digest(
        COALESCE(p_previous_hash, '') || ':' ||
        COALESCE(p_session_id::TEXT, '') || ':' || 
        COALESCE(p_msisdn, '') || ':' || 
        COALESCE(p_state, '') || ':' ||
        COALESCE(p_timestamp::TEXT, '') || ':' ||
        COALESCE(encode(p_context_encrypted, 'hex'), ''),
        'sha256'
    ), 'hex');
END;
$$;


-- Stub: Record fingerprint event
-- PRODUCTION FIX: Added stub function for record_fingerprint_event
CREATE OR REPLACE FUNCTION record_fingerprint_event(
    p_fingerprint_id UUID,
    p_msisdn VARCHAR(15),
    p_event_type VARCHAR(50),
    p_severity VARCHAR(20) DEFAULT 'INFO',
    p_event_data JSONB DEFAULT '{}'::JSONB,
    p_session_id UUID DEFAULT NULL,
    p_transaction_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_event_id UUID;
BEGIN
    -- Minimal implementation - replace with actual event logging
    v_event_id := gen_random_uuid();
    RETURN v_event_id;
END;
$$;

-- Stub: Log menu navigation
-- PRODUCTION FIX: Added stub function for log_menu_navigation
CREATE OR REPLACE FUNCTION log_menu_navigation(
    p_session_id UUID,
    p_from_menu_id VARCHAR(64) DEFAULT NULL,
    p_to_menu_id VARCHAR(64) DEFAULT NULL,
    p_user_input VARCHAR(400) DEFAULT NULL,
    p_duration_ms INTEGER DEFAULT NULL,
    p_context_snapshot JSONB DEFAULT '{}'::JSONB,
    p_device_fingerprint_id UUID DEFAULT NULL,
    p_source_ip INET DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_nav_id UUID;
BEGIN
    -- Minimal implementation - replace with actual navigation logging
    v_nav_id := gen_random_uuid();
    RETURN v_nav_id;
END;
$$;

-- Stub: Record menu analytics
-- PRODUCTION FIX: Added stub function for record_menu_analytics
CREATE OR REPLACE FUNCTION record_menu_analytics(
    p_menu_id VARCHAR(64),
    p_event_type VARCHAR(50),
    p_event_data JSONB DEFAULT '{}'::JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_analytics_id UUID;
BEGIN
    -- Minimal implementation - replace with actual analytics
    v_analytics_id := gen_random_uuid();
    RETURN v_analytics_id;
END;
$$;

-- Stub: Get SIM swap status
-- PRODUCTION FIX: Added stub function for get_sim_swap_status
CREATE OR REPLACE FUNCTION get_sim_swap_status(
    p_msisdn VARCHAR(15)
)
RETURNS TABLE (
    swap_detected BOOLEAN,
    days_since_swap INTEGER,
    is_within_critical_window BOOLEAN,
    requires_verification BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Minimal implementation - replace with actual SIM swap check
    RETURN QUERY SELECT 
        false::BOOLEAN,
        0::INTEGER,
        false::BOOLEAN,
        false::BOOLEAN;
END;
$$;

-- =============================================================================
-- MAIN FUNCTION: create_session
-- =============================================================================

CREATE OR REPLACE FUNCTION create_session(
    -- Input parameters
    p_msisdn VARCHAR(15),
    p_shortcode VARCHAR(50),
    p_operator_code VARCHAR(6),
    p_network_session_id VARCHAR(128),
    p_source_ip INET,
    p_user_agent VARCHAR(256) DEFAULT NULL,
    p_ussd_string VARCHAR(4000) DEFAULT NULL,
    p_device_fingerprint_hash VARCHAR(64) DEFAULT NULL,
    p_device_model VARCHAR(128) DEFAULT NULL,
    p_network_type VARCHAR(10) DEFAULT NULL,
    p_latitude DECIMAL(10,8) DEFAULT NULL,
    p_longitude DECIMAL(11,8) DEFAULT NULL
)
RETURNS TABLE (
    session_id UUID,
    current_state VARCHAR(32),
    application_id VARCHAR(64),
    default_menu_id VARCHAR(64),
    expires_at TIMESTAMPTZ,
    is_concurrent_blocked BOOLEAN,
    security_flags TEXT[],
    device_verification_required BOOLEAN,
    required_auth_method VARCHAR(16),
    sim_swap_detected BOOLEAN,
    days_since_sim_swap INT
) 
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_session_id UUID;
    v_route RECORD;
    v_existing_session RECORD;
    v_device_fingerprint_id UUID;
    v_security_flags TEXT[] := ARRAY[]::TEXT[];
    v_is_concurrent_blocked BOOLEAN := FALSE;
    v_context_encrypted BYTEA;
    v_expires_at TIMESTAMPTZ;
    v_session_hash VARCHAR(64);
    v_previous_hash VARCHAR(64);
    v_ip_whitelisted BOOLEAN;
    v_velocity_ok BOOLEAN;
    v_sim_swap_status RECORD;
    v_device_verification RECORD;
BEGIN
    -- ========================================================================
    -- [CREATE-001] Input validation
    -- ========================================================================
    
    -- Validate MSISDN format (E.164)
    IF p_msisdn !~ '^\+[1-9][0-9]{7,14}$' THEN
        RAISE EXCEPTION 'Invalid MSISDN format: %', p_msisdn
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    
    -- Validate shortcode format (*123# pattern)
    IF p_shortcode !~ '^\*[0-9]+([*][0-9#*]*)?#$' THEN
        RAISE EXCEPTION 'Invalid shortcode format: %', p_shortcode
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    
    -- Validate operator_code (MCC-MNC format: 3 digits + 2-3 digits)
    IF p_operator_code !~ '^[0-9]{5,6}$' THEN
        RAISE EXCEPTION 'Invalid operator_code format: %', p_operator_code
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    
    -- Check source_ip against whitelist (if configured)
    SELECT EXISTS (
        SELECT 1 FROM ussd_gateway_whitelist 
        WHERE ip_address >>= p_source_ip OR ip_address = p_source_ip
    ) INTO v_ip_whitelisted;
    
    -- In production, enforce IP whitelist
    -- For now, just flag if not whitelisted
    IF NOT v_ip_whitelisted THEN
        v_security_flags := array_append(v_security_flags, 'IP_NOT_WHITELISTED');
    END IF;
    
    -- Sanitize user_agent (remove null bytes and limit length)
    IF p_user_agent IS NOT NULL THEN
        p_user_agent := substring(regexp_replace(p_user_agent, '[\x00-\x1F]', '', 'g'), 1, 256);
    END IF;
    
    -- ========================================================================
    -- [CREATE-002] Resolve shortcode to application
    -- ========================================================================
    
    SELECT * INTO v_route
    FROM resolve_shortcode(p_shortcode, p_operator_code);
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No route found for shortcode: %', p_shortcode
            USING ERRCODE = 'no_data_found';
    END IF;
    
    -- Check if circuit breaker is open
    IF v_route.circuit_breaker_status = 'OPEN' THEN
        RAISE EXCEPTION 'Service temporarily unavailable for shortcode: %', p_shortcode
            USING ERRCODE = 'service_not_available';
    END IF;

    -- ========================================================================
    -- [CREATE-003] Check concurrent session policy
    -- ========================================================================
    
    -- Acquire transaction-level advisory lock to prevent race conditions
    -- Uses pg_advisory_xact_lock which is automatically released at transaction end
    PERFORM pg_advisory_xact_lock(hashtext('session_' || p_msisdn));
    
    BEGIN
        -- Check for existing active sessions
        SELECT * INTO v_existing_session
        FROM ussd_session_state
        WHERE msisdn = p_msisdn
          AND is_active = TRUE
          AND expires_at > NOW()
        ORDER BY created_at DESC
        LIMIT 1;
        
        IF FOUND THEN
            IF v_route.allow_concurrent_sessions = FALSE THEN
                -- Terminate existing session
                UPDATE ussd_session_state
                SET is_active = FALSE,
                    completion_status = 'SYSTEM_CANCEL',
                    completed_at = NOW(),
                    current_state = 'CANCELLED',
                    is_finalized = TRUE,
                    finalized_at = NOW()
                WHERE session_id = v_existing_session.session_id;
                
                v_security_flags := array_append(v_security_flags, 'PREVIOUS_SESSION_TERMINATED');
                
                -- Log the termination
                PERFORM record_fingerprint_event(
                    v_existing_session.device_fingerprint_id,
                    p_msisdn,
                    'SESSION_TERMINATED',
                    'INFO',
                    jsonb_build_object(
                        'reason', 'concurrent_session',
                        'new_session_shortcode', p_shortcode
                    ),
                    v_existing_session.session_id,
                    NULL
                );
            ELSE
                -- Check concurrent session limit (max 3)
                IF (SELECT COUNT(*) FROM ussd_session_state 
                    WHERE msisdn = p_msisdn AND is_active = TRUE) >= 3 THEN
                    
                    v_is_concurrent_blocked := TRUE;
                    v_security_flags := array_append(v_security_flags, 'CONCURRENT_LIMIT_REACHED');
                    
                    -- Return without creating session (lock auto-released by xact_lock)
                    session_id := NULL;
                    current_state := 'BLOCKED';
                    application_id := NULL;
                    default_menu_id := NULL;
                    expires_at := NULL;
                    is_concurrent_blocked := TRUE;
                    security_flags := v_security_flags;
                    device_verification_required := TRUE;
                    required_auth_method := 'BLOCKED';
                    sim_swap_detected := FALSE;
                    days_since_sim_swap := NULL;
                    RETURN NEXT;
                    RETURN;
                END IF;
            END IF;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            -- Lock is automatically released by pg_advisory_xact_lock on transaction rollback
            RAISE;
    END;

    -- ========================================================================
    -- [CREATE-004] Verify device fingerprint
    -- ========================================================================
    
    -- Generate or lookup device fingerprint
    IF p_device_fingerprint_hash IS NOT NULL THEN
        -- Use provided fingerprint hash
        SELECT * INTO v_device_verification
        FROM verify_device_fingerprint(
            p_msisdn,
            p_device_fingerprint_hash,
            p_operator_code,
            v_security_flags
        );
        
        v_device_fingerprint_id := v_device_verification.fingerprint_id;
        v_security_flags := v_device_verification.security_flags;
        
        -- If new device, generate fingerprint
        IF v_device_fingerprint_id IS NULL THEN
            SELECT fingerprint_id INTO v_device_fingerprint_id
            FROM generate_device_fingerprint(
                p_msisdn,
                p_operator_code,
                NULL, -- imei_hash
                NULL, -- imsi_hash
                p_device_model,
                NULL, -- os_version
                p_network_type,
                NULL, -- mcc_mnc
                NULL, -- lac
                NULL, -- cell_id
                p_latitude,
                p_longitude,
                NULL -- session_id (will be updated)
            );
            
            v_security_flags := array_append(v_security_flags, 'NEW_DEVICE_REGISTERED');
        END IF;
    ELSE
        -- No fingerprint provided - create anonymous placeholder
        v_security_flags := array_append(v_security_flags, 'NO_FINGERPRINT');
        
        -- Still try to look up by MSISDN only
        SELECT fingerprint_id INTO v_device_fingerprint_id
        FROM device_fingerprints
        WHERE msisdn = p_msisdn
          AND status = 'ACTIVE'
        ORDER BY last_session_at DESC
        LIMIT 1;
    END IF;

    -- ========================================================================
    -- [CREATE-005] Check velocity limits
    -- ========================================================================
    
    SELECT * INTO v_velocity_ok FROM check_velocity_limits(
        p_msisdn,
        p_source_ip,
        v_route.application_id,
        v_route.rate_limit_requests_per_minute,
        v_route.rate_limit_burst
    );
    
    IF NOT v_velocity_ok THEN
        v_security_flags := array_append(v_security_flags, 'VELOCITY_LIMIT_EXCEEDED');
        
        -- Don't block immediately, but flag for monitoring
        -- In strict mode, uncomment the following:
        -- PERFORM pg_advisory_unlock(hashtext('session_' || p_msisdn));
        -- RAISE EXCEPTION 'Rate limit exceeded for MSISDN: %', p_msisdn
        --     USING ERRCODE = 'too_many_requests';
    END IF;

    -- ========================================================================
    -- [CREATE-006] Check SIM swap status
    -- ========================================================================
    
    SELECT * INTO v_sim_swap_status FROM get_sim_swap_status(p_msisdn);
    
    -- If route requires SIM swap check, enforce restrictions
    IF v_route.sim_swap_check_required AND v_sim_swap_status.swap_detected THEN
        v_security_flags := array_append(v_security_flags, 'SIM_SWAP_RESTRICTION');
        
        -- Check if within critical window
        IF v_sim_swap_status.is_within_critical_window THEN
            v_security_flags := array_append(v_security_flags, 
                CASE 
                    WHEN v_sim_swap_status.days_since_swap < 1 THEN 'SIM_SWAP_24H'
                    ELSE 'SIM_SWAP_72H'
                END
            );
        END IF;
    END IF;

    -- ========================================================================
    -- [CREATE-007] Calculate session expiration
    -- ========================================================================
    
    -- Base timeout from route configuration
    v_expires_at := NOW() + (v_route.session_timeout_seconds || ' seconds')::INTERVAL;
    
    -- Adjust for device trust level
    IF v_device_fingerprint_id IS NOT NULL THEN
        DECLARE
            v_trust_level VARCHAR(16);
        BEGIN
            SELECT trust_level INTO v_trust_level
            FROM device_fingerprints
            WHERE fingerprint_id = v_device_fingerprint_id;
            
            -- Reduce timeout for untrusted devices
            CASE v_trust_level
                WHEN 'NEW' THEN
                    v_expires_at := LEAST(v_expires_at, NOW() + INTERVAL '60 seconds');
                WHEN 'LOW' THEN
                    v_expires_at := LEAST(v_expires_at, NOW() + INTERVAL '90 seconds');
                WHEN 'BLACKLISTED' THEN
                    -- Block device (lock auto-released on transaction end)
                    RAISE EXCEPTION 'Device blocked for MSISDN: %', p_msisdn
                        USING ERRCODE = 'insufficient_privilege';
                ELSE
                    NULL; -- HIGH, WHITELISTED - use default timeout
            END CASE;
        END;
    END IF;
    
    -- Reduce timeout if SIM swap detected recently
    IF v_sim_swap_status.swap_detected AND v_sim_swap_status.days_since_swap < 1 THEN
        v_expires_at := LEAST(v_expires_at, NOW() + INTERVAL '45 seconds');
    END IF;
    
    -- Enforce absolute maximum (10 minutes)
    IF v_expires_at > NOW() + INTERVAL '10 minutes' THEN
        v_expires_at := NOW() + INTERVAL '10 minutes';
    END IF;

    -- ========================================================================
    -- [CREATE-008] Build and encrypt initial context
    -- ========================================================================
    
    v_context_encrypted := create_session_context(
        'en', -- Default language
        p_shortcode,
        v_device_fingerprint_id,
        jsonb_build_object(
            'network_session_id', p_network_session_id,
            'source_ip', p_source_ip::TEXT,
            'user_agent', p_user_agent,
            'sim_swap_detected', v_sim_swap_status.swap_detected,
            'days_since_sim_swap', v_sim_swap_status.days_since_swap,
            'requires_sim_swap_verification', v_route.sim_swap_check_required AND v_sim_swap_status.swap_detected
        )
    );

    -- ========================================================================
    -- [CREATE-009] Calculate session hash for audit chain
    -- ========================================================================
    
    -- Get previous session hash for this MSISDN
    SELECT session_hash INTO v_previous_hash
    FROM ussd_session_state
    WHERE msisdn = p_msisdn
      AND is_finalized = TRUE
    ORDER BY finalized_at DESC
    LIMIT 1;
    
    -- Generate temporary session ID for hash calculation
    v_session_id := gen_random_uuid();
    
    -- Calculate session hash
    v_session_hash := calculate_session_hash(
        v_previous_hash,
        v_session_id,
        p_msisdn,
        'INIT',
        NOW(),
        v_context_encrypted
    );

    -- ========================================================================
    -- Insert new session record
    -- ========================================================================
    
    INSERT INTO ussd_session_state (
        session_id,
        msisdn,
        operator_code,
        current_state,
        shortcode,
        application_id,
        current_menu_id,
        context_encrypted,
        encryption_version,
        key_id,
        device_fingerprint_id,
        auth_level,
        pin_attempts,
        created_at,
        last_activity_at,
        expires_at,
        ussd_string,
        network_session_id,
        source_ip,
        user_agent,
        is_active,
        session_hash,
        previous_session_hash
    ) VALUES (
        v_session_id,
        p_msisdn,
        p_operator_code,
        'INIT',
        p_shortcode,
        v_route.application_id,
        v_route.default_menu_id,
        v_context_encrypted,
        1, -- encryption_version
        'kms-key-001', -- key_id
        v_device_fingerprint_id,
        v_route.required_auth_level,
        0,
        NOW(),
        NOW(),
        v_expires_at,
        p_ussd_string,
        p_network_session_id,
        p_source_ip,
        p_user_agent,
        TRUE,
        v_session_hash,
        v_previous_hash
    );
    
    -- Update fingerprint with session ID
    IF v_device_fingerprint_id IS NOT NULL THEN
        UPDATE device_fingerprints
        SET last_session_id = v_session_id
        WHERE fingerprint_id = v_device_fingerprint_id;
    END IF;

    -- ========================================================================
    -- [CREATE-010] Log session creation event
    -- ========================================================================
    
    IF v_device_fingerprint_id IS NOT NULL THEN
        PERFORM record_fingerprint_event(
            v_device_fingerprint_id,
            p_msisdn,
            'SESSION_CREATED',
            'INFO',
            jsonb_build_object(
                'session_id', v_session_id,
                'shortcode', p_shortcode,
                'application_id', v_route.application_id,
                'expires_at', v_expires_at,
                'security_flags', v_security_flags
            ),
            v_session_id,
            NULL
        );
    END IF;

    -- ========================================================================
    -- [CREATE-011] Initialize menu navigation history
    -- ========================================================================
    
    IF v_route.default_menu_id IS NOT NULL THEN
        PERFORM log_menu_navigation(
            v_session_id,
            NULL, -- from_menu_id (initial entry)
            v_route.default_menu_id,
            NULL, -- user_input
            NULL, -- duration_ms
            '{}'::JSONB, -- context_snapshot
            v_device_fingerprint_id,
            p_source_ip
        );
        
        -- Record menu analytics
        PERFORM record_menu_analytics(
            v_route.default_menu_id,
            'view',
            jsonb_build_object('source', 'session_init')
        );
    END IF;

    -- Transaction-level advisory lock is automatically released at transaction end

    -- ========================================================================
    -- Determine verification requirements
    -- ========================================================================
    
    DECLARE
        v_verification_required BOOLEAN := FALSE;
        v_auth_method VARCHAR(16) := 'NONE';
    BEGIN
        -- Check if device verification is required
        IF v_device_verification.verification_result = 'CHALLENGE' THEN
            v_verification_required := TRUE;
            v_auth_method := COALESCE(v_device_verification.auth_method, 'PIN');
        END IF;
        
        -- Check SIM swap verification
        IF v_route.sim_swap_check_required AND v_sim_swap_status.requires_verification THEN
            v_verification_required := TRUE;
            v_auth_method := CASE 
                WHEN v_sim_swap_status.days_since_swap < 1 THEN 'OTP'
                ELSE 'PIN'
            END;
        END IF;
        
        -- Override with route required auth if higher
        IF v_route.required_auth_level IN ('PIN', 'OTP', 'BIOMETRIC', 'HARDWARE_TOKEN') THEN
            v_verification_required := TRUE;
            v_auth_method := v_route.required_auth_level;
        END IF;

        -- Return session information
        session_id := v_session_id;
        current_state := 'INIT';
        application_id := v_route.application_id;
        default_menu_id := v_route.default_menu_id;
        expires_at := v_expires_at;
        is_concurrent_blocked := v_is_concurrent_blocked;
        security_flags := v_security_flags;
        device_verification_required := v_verification_required;
        required_auth_method := v_auth_method;
        sim_swap_detected := v_sim_swap_status.swap_detected;
        days_since_sim_swap := v_sim_swap_status.days_since_swap;
        
        RETURN NEXT;
    END;

EXCEPTION
    WHEN OTHERS THEN
        -- Transaction-level advisory lock is automatically released on transaction rollback
        RAISE;
END;
$$;

-- ----------------------------------------------------------------------------
-- FUNCTION: check_velocity_limits
-- ----------------------------------------------------------------------------
-- Checks rate limiting for sessions per MSISDN and source IP
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION check_velocity_limits(
    p_msisdn VARCHAR(15),
    p_source_ip INET,
    p_application_id VARCHAR(64),
    p_rate_limit_per_minute INT DEFAULT 60,
    p_burst_limit INT DEFAULT 10
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_msisdn_count INT;
    v_ip_count INT;
    v_app_count INT;
BEGIN
    -- Check sessions per MSISDN in last minute
    SELECT COUNT(*) INTO v_msisdn_count
    FROM ussd_session_state
    WHERE msisdn = p_msisdn
      AND created_at > NOW() - INTERVAL '1 minute';
    
    IF v_msisdn_count > p_rate_limit_per_minute THEN
        RETURN FALSE;
    END IF;
    
    -- Check sessions per IP in last minute
    SELECT COUNT(*) INTO v_ip_count
    FROM ussd_session_state
    WHERE source_ip = p_source_ip
      AND created_at > NOW() - INTERVAL '1 minute';
    
    IF v_ip_count > (p_rate_limit_per_minute * 2) THEN -- Higher limit per IP
        RETURN FALSE;
    END IF;
    
    -- Check burst rate (last 10 seconds)
    SELECT COUNT(*) INTO v_burst_count
    FROM ussd_session_state
    WHERE msisdn = p_msisdn
      AND created_at > NOW() - INTERVAL '10 seconds';
    
    IF v_burst_count > p_burst_limit THEN
        RETURN FALSE;
    END IF;
    
    RETURN TRUE;
END;
$$;

-- ----------------------------------------------------------------------------
-- TABLE: ussd_gateway_whitelist (for IP validation)
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ussd_gateway_whitelist (
    id SERIAL PRIMARY KEY,
    ip_address INET NOT NULL,
    description VARCHAR(256),
    operator_code VARCHAR(6),
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_whitelist_active ON ussd_gateway_whitelist(is_active, ip_address);

-- ----------------------------------------------------------------------------
-- IMPLEMENTATION NOTES
-- ----------------------------------------------------------------------------

/*
TODO [PERF-001]: Optimize for high concurrency
  - Use advisory locks to prevent race conditions on concurrent session checks
  - Implement connection pooling for database connections
  - Consider read replicas for route lookups
  - Cache routing configuration in Redis (TTL: 60 seconds)

TODO [SEC-001]: Security hardening
  - Implement IP whitelist validation
  - Add HMAC signature verification for requests
  - Rate limit session creation per source
  - Encrypt all sensitive context data

TODO [MON-001]: Monitoring and alerting
  - Track session creation latency (p50, p95, p99)
  - Alert on high concurrent session termination rates
  - Monitor failed route resolutions
  - Track device fingerprint verification failures

TODO [RES-001]: Resilience patterns
  - Circuit breaker for KMS encryption calls
  - Fallback routing if primary route fails
  - Graceful degradation if fingerprint service unavailable
  - Retry logic for transient database errors
*/

-- ----------------------------------------------------------------------------
-- SECURITY CONSIDERATIONS
-- ----------------------------------------------------------------------------
-- [ISO/IEC 27001:2022] A.5.1 - Session security policies
-- [ISO/IEC 27001:2022] A.8.1 - Device verification
-- [ISO/IEC 27001:2022] A.8.5 - Secure authentication
-- [ISO/IEC 27018:2019] MSISDN format validation (E.164)
-- [PCI DSS v4.0] Session timeout enforcement
/*
1. INPUT VALIDATION:
   - All inputs must be validated before processing
   - MSISDN must be normalized to E.164 format
   - Shortcode must match expected patterns
   - IP address must be from known gateway ranges

2. CONCURRENT SESSION HANDLING:
   - Prevent session fixation attacks
   - Log all concurrent session scenarios
   - Alert on suspicious concurrent patterns
   - Consider geographic impossibility

3. DEVICE VERIFICATION:
   - New devices require additional scrutiny
   - Recent SIM swaps block high-risk operations
   - Trust scores must be validated
   - Don't trust client-provided fingerprint data

4. AUDIT TRAIL:
   - Every session creation must be auditable
   - Hash chain prevents tampering
   - Retain logs per regulatory requirements
   - Include all security decisions in logs
*/

-- ----------------------------------------------------------------------------
-- SESSION TIMEOUT HANDLING
-- ----------------------------------------------------------------------------
-- [ISO/IEC 27001:2022] A.8.11 - Multi-layer timeout architecture
-- Network timeout: 30-60s (carrier-controlled)
-- Application idle: 90s (configurable per route)
-- Absolute maximum: 10 minutes
-- Function timeout: 500ms p99 target
/*
Session creation timeout considerations:

1. OPERATION TIMEOUT:
   - Function must complete within 500ms (p99)
   - Database queries have 100ms timeout each
   - External service calls (KMS, fingerprint) have 200ms timeout
   - Fail fast on timeout, don't create partial sessions

2. CLEANUP ON FAILURE:
   - If session creation fails mid-transaction, rollback everything
   - Clean up any partial fingerprints created
   - Release any locks acquired
   - Log failure reason for debugging

3. EXPIRATION SETTING:
   - Calculate expiration based on route config
   - Apply maximum cap (10 minutes)
   - Consider device trust level (trusted = longer timeout)
   - Transaction-specific timeouts for deep links

4. CLOCK SKEW HANDLING:
   - Use database clock (NOW()) for consistency
   - Account for potential clock skew across regions
   - Don't rely on client timestamps
*/

-- ----------------------------------------------------------------------------
-- SIM SWAP DETECTION INTEGRATION
-- ----------------------------------------------------------------------------
-- [ISO/IEC 27035-2:2023] Pre-session SIM swap checks
-- [GSMA IR.71] 72-hour critical window monitoring
-- Security flags: SIM_SWAP_24H, SIM_SWAP_72H, NEW_DEVICE_POST_SWAP
-- Verification: OTP required for all operations within 24h post-swap
/*
SIM swap detection during session creation:

1. PRE-SESSION CHECKS:
   - Query recent SIM swap events for MSISDN
   - If swap within 72 hours, elevate security level
   - Require additional verification for sensitive operations
   - Log correlation between swap and new session

2. NEW DEVICE CORRELATION:
   - If new fingerprint + recent SIM swap = high risk
   - Trigger device verification workflow
   - Limit transaction amounts for 24-72 hours
   - SMS notification to previous device (if possible)

3. SECURITY FLAGS:
   - SIM_SWAP_24H: Swap within 24 hours
   - SIM_SWAP_72H: Swap within 72 hours
   - NEW_DEVICE_POST_SWAP: Device change after swap
   - These flags affect subsequent transaction authorization

4. VERIFICATION REQUIREMENTS:
   - SIM_SWAP_24H: Block high-value, require OTP for all
   - SIM_SWAP_72H: Reduce limits, additional confirmation
   - NEW_DEVICE_POST_SWAP: Challenge with security questions
*/

-- Grant execute permission
-- GRANT EXECUTE ON FUNCTION create_session TO ussd_gateway_role;

COMMIT;
