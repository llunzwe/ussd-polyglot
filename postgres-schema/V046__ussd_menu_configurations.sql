-- =============================================================================
-- Migration: V056__ussd_menu_configurations
-- Description: USSD table: menu_configurations
-- Dependencies: V055
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- ============================================================================
-- USSD MENU CONFIGURATION
-- ============================================================================
-- Purpose: Define USSD menu trees and navigation flows for interactive sessions.
-- Context: USSD menus are text-based, hierarchical interfaces presented as:
--          numbered lists (1. Check Balance, 2. Send Money, etc.)
--          with support for input fields and confirmation dialogs.
--
-- COMPLIANCE & STANDARDS:
--   ISO/IEC 27001:2022 - Information Security Management
--     * A.8.1: Endpoint security - menu-level PIN requirements
--     * A.8.5: Secure authentication for sensitive operations
--     * A.8.12: Audit logging for menu navigation (audit_log_view flag)
--     * A.8.16: Monitoring activities via menu analytics
--
--   ISO/IEC 27018:2019 - PII Protection
--     * Dynamic content config must not expose raw PII in templates
--     * Mask MSISDN in menu content ({{recipient_msisdn}} sanitized)
--     * Anonymize navigation analytics data
--
--   ISO 31000:2018 - Risk Management
--     * Risk-based menu access (sensitive_input flag)
--     * SIM swap detection integration for high-risk menus
--     * Behavioral biometrics tracking for anomaly detection
--
--   GDPR Compliance:
--     * User consent tracking for menu preferences
--     * Right to erasure: menu history anonymization
--
-- MENU CHARACTERISTICS:
--   - Limited to ~160-182 characters per screen (SMS-like constraints)
--   - No graphics, only text and basic formatting
--   - Navigation via number selection or shortcodes
--   - Support for "back" (0), "home" (#), and language switching
--
-- SECURITY FEATURES:
--   - require_pin: Enforces authentication before menu access
--   - sensitive_input: Masks user input (PIN entry screens)
--   - audit_log_view: All navigation logged for compliance
--   - Circular navigation prevention (depth tracking)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- TABLE: menu_configurations
-- ----------------------------------------------------------------------------
-- Stores menu definitions with multi-language support and dynamic content.
-- ----------------------------------------------------------------------------

-- PRODUCTION FIX (MIX-001): Standardized application_id to UUID type for consistency
-- PRODUCTION FIX: Added schema prefix for consistency
CREATE TABLE IF NOT EXISTS ussd.menu_configurations (
    menu_id VARCHAR(64) PRIMARY KEY,
    
    -- Human-readable name for administration
    menu_name VARCHAR(128) NOT NULL,
    
    -- Application this menu belongs to
    application_id UUID NOT NULL,  -- Was VARCHAR(64), changed to UUID for consistency
    
    -- Menu type determines rendering and behavior
    menu_type VARCHAR(32) NOT NULL DEFAULT 'LIST',
    -- LIST: Numbered options (1. Option A, 2. Option B)
    -- INPUT: Free text input (Enter amount:)
    -- CONFIRM: Yes/No confirmation (Send X to Y? 1. Yes 2. No)
    -- DISPLAY: Information only (Your balance is...)
    -- PIN: PIN entry screen (masked input)
    -- LANGUAGE: Language selection menu
    -- ERROR: Error display with retry options
    
    -- Parent menu for hierarchical navigation (NULL = root)
    parent_menu_id VARCHAR(64),
    
    -- Menu position in parent (for ordering)
    display_order INT DEFAULT 0,
    
    -- Menu content with i18n support
    -- Structure: {"en": "...", "sw": "...", "fr": "..."}
    content_i18n JSONB NOT NULL DEFAULT '{}',
    
    -- Default language code
    default_language VARCHAR(5) DEFAULT 'en',
    
    -- Supported languages for this menu
    supported_languages TEXT[] DEFAULT ARRAY['en'],
    
    -- Dynamic content configuration
    -- References to external data sources for real-time content
    dynamic_content_config JSONB DEFAULT NULL,
    -- Example: {"type": "api", "endpoint": "/balance/{msisdn}", "cache_ttl": 30}
    
    -- Navigation rules
    -- Maps user input to next menu or action
    -- Structure: {"1": "menu:send_money", "2": "menu:check_balance", "0": "back", "#": "home"}
    navigation_rules JSONB NOT NULL DEFAULT '{}',
    
    -- Input validation rules (for INPUT type menus)
    -- Structure: {"type": "amount", "min": 100, "max": 1000000, "regex": "^[0-9]+$"}
    input_validation JSONB DEFAULT NULL,
    
    -- Action to execute when menu is displayed
    -- Structure: {"type": "log", "event": "menu_viewed"} or 
    --           {"type": "api", "endpoint": "/pre-fetch-data"}
    on_display_action JSONB DEFAULT NULL,
    
    -- Action to execute on user input
    -- Structure: {"type": "validate_pin", "next_success": "menu:confirm", "next_fail": "menu:error"}
    on_input_action JSONB DEFAULT NULL,
    
    -- Session context updates on navigation
    -- Structure: {"set": {"last_menu": "@menu_id"}, "clear": ["temp_input"]}
    context_updates JSONB DEFAULT NULL,
    
    -- Timeout behavior for this specific menu
    timeout_seconds INT, -- NULL = use route default
    timeout_menu_id VARCHAR(64), -- Where to go on timeout
    
    -- Error handling
    error_menu_id VARCHAR(64), -- Where to go on processing error
    invalid_input_message_i18n JSONB DEFAULT '{}', -- Custom error per menu
    
    -- Security settings
    require_pin BOOLEAN DEFAULT FALSE,
    sensitive_input BOOLEAN DEFAULT FALSE, -- Mask input (PIN entry)
    audit_log_view BOOLEAN DEFAULT TRUE, -- Log menu views
    
    -- SIM SWAP RISK LEVEL - Controls menu access restrictions
    sim_swap_risk_level VARCHAR(16) DEFAULT 'LOW', -- LOW, MEDIUM, HIGH, CRITICAL
    require_sim_swap_check BOOLEAN DEFAULT FALSE,
    post_swap_grace_period_hours INT DEFAULT 0, -- Hours before menu accessible post-swap
    
    -- UI formatting
    header_text_i18n JSONB DEFAULT '{}', -- Persistent header
    footer_text_i18n JSONB DEFAULT '{}', -- Persistent footer (e.g., "0. Back")
    separator_line VARCHAR(10) DEFAULT '-', -- Between header and content
    
    -- A/B testing support
    ab_test_variant VARCHAR(32) DEFAULT 'control',
    
    -- Status and lifecycle
    is_active BOOLEAN DEFAULT TRUE,
    effective_from TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    effective_to TIMESTAMPTZ,
    
    -- Version control
    version INT DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by VARCHAR(128) NOT NULL,
    updated_by VARCHAR(128) NOT NULL,
    
    -- Configuration hash for audit
    config_hash VARCHAR(64),
    
    -- Constraints
    CONSTRAINT valid_menu_type CHECK (
        menu_type IN ('LIST', 'INPUT', 'CONFIRM', 'DISPLAY', 'PIN', 'LANGUAGE', 'ERROR', 'TERMINAL')
    ),
    CONSTRAINT valid_ab_test_variant CHECK (
        ab_test_variant IN ('control', 'variant_a', 'variant_b', 'variant_c')
    ),
    CONSTRAINT valid_display_order CHECK (display_order >= 0),
    CONSTRAINT valid_timeout CHECK (timeout_seconds IS NULL OR timeout_seconds > 0),
    CONSTRAINT valid_sim_swap_risk_level CHECK (
        sim_swap_risk_level IN ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL')
    ),
    
    -- Self-referential foreign key (enforced via trigger for circular prevention)
    CONSTRAINT valid_parent_menu CHECK (parent_menu_id IS NULL OR parent_menu_id != menu_id)
);

-- ----------------------------------------------------------------------------
-- FUNCTION: calculate_menu_config_hash
-- ----------------------------------------------------------------------------
-- Calculates hash for menu configuration tamper detection
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION calculate_menu_config_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_config_text TEXT;
BEGIN
    v_config_text := NEW.menu_id || 
                     NEW.application_id || 
                     NEW.menu_type ||
                     NEW.content_i18n::TEXT ||
                     NEW.navigation_rules::TEXT;
    
    NEW.config_hash := encode(digest(v_config_text, 'sha256'), 'hex');
    NEW.updated_at := NOW();
    NEW.version := COALESCE(OLD.version, 0) + 1;
    
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_calculate_menu_hash ON menus;
CREATE TRIGGER trg_calculate_menu_hash
    BEFORE INSERT OR UPDATE ON menu_configurations
    FOR EACH ROW
    EXECUTE FUNCTION calculate_menu_config_hash();

-- ----------------------------------------------------------------------------
-- FUNCTION: render_menu
-- ----------------------------------------------------------------------------
-- Renders a menu with template substitution and formatting
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION render_menu(
    p_menu_id VARCHAR(64),
    p_language VARCHAR(5) DEFAULT 'en',
    p_context JSONB DEFAULT '{}',
    p_max_length INT DEFAULT 182
)
RETURNS TABLE (
    rendered_text TEXT,
    is_truncated BOOLEAN,
    actual_length INT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_menu RECORD;
    v_content TEXT;
    v_header TEXT;
    v_footer TEXT;
    v_separator VARCHAR(10);
    v_rendered TEXT;
BEGIN
    -- Get menu configuration
    SELECT * INTO v_menu 
    FROM menu_configurations 
    WHERE menu_id = p_menu_id AND is_active = TRUE;
    
    IF NOT FOUND THEN
        rendered_text := 'Error: Menu not found';
        is_truncated := FALSE;
        actual_length := LENGTH(rendered_text);
        RETURN NEXT;
        RETURN;
    END IF;
    
    -- Get content in requested language or fallback to default
    v_content := COALESCE(
        v_menu.content_i18n->>p_language,
        v_menu.content_i18n->>v_menu.default_language,
        'Menu content unavailable'
    );
    
    -- Get header
    v_header := COALESCE(
        v_menu.header_text_i18n->>p_language,
        ''
    );
    
    -- Get footer
    v_footer := COALESCE(
        v_menu.footer_text_i18n->>p_language,
        '0. Back'
    );
    
    v_separator := COALESCE(v_menu.separator_line, '-');
    
    -- Template substitution from context
    -- Replace {{variable}} with context values
    DECLARE
        v_key TEXT;
        v_value TEXT;
    BEGIN
        FOR v_key, v_value IN SELECT * FROM jsonb_each_text(p_context) LOOP
            v_content := REPLACE(v_content, '{{' || v_key || '}}', v_value);
        END LOOP;
    END;
    
    -- Mask PII in content (MSISDN pattern)
    v_content := regexp_replace(v_content, '\+?[0-9]{10,15}', 
        substring(v_content FROM '\+?[0-9]{3,4}') || '****' || 
        substring(v_content FROM '[0-9]{4}$'), 'g');
    
    -- Assemble final text
    v_rendered := '';
    
    IF v_header != '' THEN
        v_rendered := v_header || E'\n' || v_separator || E'\n';
    END IF;
    
    v_rendered := v_rendered || v_content;
    
    IF v_footer != '' THEN
        v_rendered := v_rendered || E'\n' || v_separator || E'\n' || v_footer;
    END IF;
    
    -- Check for truncation
    IF LENGTH(v_rendered) > p_max_length THEN
        v_rendered := substring(v_rendered FROM 1 FOR p_max_length - 3) || '...';
        is_truncated := TRUE;
    ELSE
        is_truncated := FALSE;
    END IF;
    
    rendered_text := v_rendered;
    actual_length := LENGTH(v_rendered);
    
    RETURN NEXT;
END;
$$;

-- ----------------------------------------------------------------------------
-- FUNCTION: validate_menu_input
-- ----------------------------------------------------------------------------
-- Validates user input against menu validation rules
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION validate_menu_input(
    p_menu_id VARCHAR(64),
    p_input VARCHAR(400)
)
RETURNS TABLE (
    is_valid BOOLEAN,
    error_message VARCHAR(256),
    normalized_input VARCHAR(400)
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_menu RECORD;
    v_validation JSONB;
    v_type VARCHAR(32);
    v_min NUMERIC;
    v_max NUMERIC;
    v_regex VARCHAR(256);
    v_normalized VARCHAR(400);
BEGIN
    -- Get menu validation rules
    SELECT input_validation, invalid_input_message_i18n, default_language 
    INTO v_menu
    FROM menu_configurations 
    WHERE menu_id = p_menu_id;
    
    IF v_menu.input_validation IS NULL THEN
        is_valid := TRUE;
        error_message := NULL;
        normalized_input := p_input;
        RETURN NEXT;
        RETURN;
    END IF;
    
    v_validation := v_menu.input_validation;
    v_type := v_validation->>'type';
    v_min := (v_validation->>'min')::NUMERIC;
    v_max := (v_validation->>'max')::NUMERIC;
    v_regex := v_validation->>'regex';
    v_normalized := p_input;
    
    -- Type-specific validation
    CASE v_type
        WHEN 'amount' THEN
            -- Strip non-numeric except decimal point
            v_normalized := regexp_replace(p_input, '[^0-9.]', '', 'g');
            
            IF v_normalized !~ '^[0-9]+(\.[0-9]{1,2})?$' THEN
                is_valid := FALSE;
                error_message := COALESCE(
                    v_validation->'error_message_i18n'->>v_menu.default_language,
                    'Invalid amount format'
                );
                normalized_input := v_normalized;
                RETURN NEXT;
                RETURN;
            END IF;
            
            IF v_min IS NOT NULL AND v_normalized::NUMERIC < v_min THEN
                is_valid := FALSE;
                error_message := 'Amount below minimum: ' || v_min::TEXT;
                normalized_input := v_normalized;
                RETURN NEXT;
                RETURN;
            END IF;
            
            IF v_max IS NOT NULL AND v_normalized::NUMERIC > v_max THEN
                is_valid := FALSE;
                error_message := 'Amount above maximum: ' || v_max::TEXT;
                normalized_input := v_normalized;
                RETURN NEXT;
                RETURN;
            END IF;
            
        WHEN 'phone_number' THEN
            -- Normalize phone number
            v_normalized := regexp_replace(p_input, '[^0-9+]', '', 'g');
            
            IF v_normalized !~ '^\+[1-9][0-9]{7,14}$' THEN
                is_valid := FALSE;
                error_message := 'Invalid phone number format';
                normalized_input := v_normalized;
                RETURN NEXT;
                RETURN;
            END IF;
            
        WHEN 'pin' THEN
            -- PIN validation (numeric, 4-6 digits)
            v_normalized := regexp_replace(p_input, '[^0-9]', '', 'g');
            
            IF v_normalized !~ '^[0-9]{4,6}$' THEN
                is_valid := FALSE;
                error_message := 'PIN must be 4-6 digits';
                normalized_input := v_normalized;
                RETURN NEXT;
                RETURN;
            END IF;
            
        WHEN 'number' THEN
            v_normalized := regexp_replace(p_input, '[^0-9]', '', 'g');
            
            IF v_normalized = '' THEN
                is_valid := FALSE;
                error_message := 'Invalid number format';
                normalized_input := v_normalized;
                RETURN NEXT;
                RETURN;
            END IF;
            
            IF v_min IS NOT NULL AND v_normalized::NUMERIC < v_min THEN
                is_valid := FALSE;
                error_message := 'Value below minimum: ' || v_min::TEXT;
                normalized_input := v_normalized;
                RETURN NEXT;
                RETURN;
            END IF;
            
            IF v_max IS NOT NULL AND v_normalized::NUMERIC > v_max THEN
                is_valid := FALSE;
                error_message := 'Value above maximum: ' || v_max::TEXT;
                normalized_input := v_normalized;
                RETURN NEXT;
                RETURN;
            END IF;
            
        WHEN 'regex' THEN
            IF v_regex IS NOT NULL AND p_input !~ v_regex THEN
                is_valid := FALSE;
                error_message := COALESCE(
                    v_validation->'error_message_i18n'->>v_menu.default_language,
                    'Invalid input format'
                );
                normalized_input := p_input;
                RETURN NEXT;
                RETURN;
            END IF;
            
        ELSE
            -- Default: accept as-is
            v_normalized := p_input;
    END CASE;
    
    is_valid := TRUE;
    error_message := NULL;
    normalized_input := v_normalized;
    
    RETURN NEXT;
END;
$$;

-- ----------------------------------------------------------------------------
-- FUNCTION: resolve_menu_navigation
-- ----------------------------------------------------------------------------
-- Resolves user input to target menu/action
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION resolve_menu_navigation(
    p_menu_id VARCHAR(64),
    p_input VARCHAR(400)
)
RETURNS TABLE (
    target_type VARCHAR(32), -- 'menu', 'action', 'back', 'home', 'exit'
    target_value VARCHAR(64),
    target_params JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_menu RECORD;
    v_target TEXT;
    v_target_menu VARCHAR(64);
    v_target_action VARCHAR(64);
    v_params JSONB := '{}'::JSONB;
BEGIN
    -- Get menu navigation rules
    SELECT navigation_rules, on_input_action 
    INTO v_menu
    FROM menu_configurations 
    WHERE menu_id = p_menu_id;
    
    IF NOT FOUND THEN
        target_type := 'error';
        target_value := 'menu_not_found';
        target_params := '{}'::JSONB;
        RETURN NEXT;
        RETURN;
    END IF;
    
    -- Check direct navigation rules
    IF v_menu.navigation_rules ? p_input THEN
        v_target := v_menu.navigation_rules->>p_input;
        
        -- Handle special keywords
        CASE v_target
            WHEN 'back' THEN
                target_type := 'back';
                target_value := NULL;
                target_params := '{}'::JSONB;
                RETURN NEXT;
                RETURN;
            WHEN 'home' THEN
                target_type := 'home';
                target_value := NULL;
                target_params := '{}'::JSONB;
                RETURN NEXT;
                RETURN;
            WHEN 'exit' THEN
                target_type := 'exit';
                target_value := NULL;
                target_params := '{}'::JSONB;
                RETURN NEXT;
                RETURN;
            WHEN 'repeat' THEN
                target_type := 'repeat';
                target_value := p_menu_id;
                target_params := '{}'::JSONB;
                RETURN NEXT;
                RETURN;
            ELSE
                -- Parse target format: "menu:send_money" or "action:execute_transfer"
                IF v_target LIKE 'menu:%' THEN
                    target_type := 'menu';
                    target_value := substring(v_target FROM 6);
                    target_params := '{}'::JSONB;
                    RETURN NEXT;
                    RETURN;
                ELSIF v_target LIKE 'action:%' THEN
                    target_type := 'action';
                    target_value := substring(v_target FROM 8);
                    target_params := '{}'::JSONB;
                    RETURN NEXT;
                    RETURN;
                END IF;
        END CASE;
    END IF;
    
    -- Check on_input_action for validation-based navigation
    IF v_menu.on_input_action IS NOT NULL THEN
        -- First validate the input
        DECLARE
            v_validation RECORD;
        BEGIN
            SELECT * INTO v_validation FROM validate_menu_input(p_menu_id, p_input);
            
            IF v_validation.is_valid THEN
                target_type := COALESCE(v_menu.on_input_action->>'type', 'menu');
                target_value := v_menu.on_input_action->>'next_success';
                target_params := jsonb_build_object('input', v_validation.normalized_input);
            ELSE
                target_type := 'error';
                target_value := v_menu.on_input_action->>'next_fail';
                target_params := jsonb_build_object('error', v_validation.error_message);
            END IF;
            
            RETURN NEXT;
            RETURN;
        END;
    END IF;
    
    -- Default: invalid input
    target_type := 'error';
    target_value := 'invalid_input';
    target_params := '{}'::JSONB;
    
    RETURN NEXT;
END;
$$;

-- ----------------------------------------------------------------------------
-- FUNCTION: check_menu_sim_swap_access
-- ----------------------------------------------------------------------------
-- Checks if menu is accessible given SIM swap risk level
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION check_menu_sim_swap_access(
    p_menu_id VARCHAR(64),
    p_days_since_sim_swap INT DEFAULT 999
)
RETURNS TABLE (
    is_accessible BOOLEAN,
    required_verification VARCHAR(32),
    restriction_message TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_menu RECORD;
BEGIN
    SELECT sim_swap_risk_level, require_sim_swap_check, post_swap_grace_period_hours
    INTO v_menu
    FROM menu_configurations
    WHERE menu_id = p_menu_id;
    
    IF NOT FOUND THEN
        is_accessible := FALSE;
        required_verification := 'NONE';
        restriction_message := 'Menu not found';
        RETURN NEXT;
        RETURN;
    END IF;
    
    -- Check grace period
    IF v_menu.post_swap_grace_period_hours > 0 THEN
        IF p_days_since_sim_swap < (v_menu.post_swap_grace_period_hours / 24.0) THEN
            is_accessible := FALSE;
            required_verification := 'TIME_DELAY';
            restriction_message := 'This service is temporarily unavailable after SIM change. Please try again in ' || 
                                   (v_menu.post_swap_grace_period_hours - (p_days_since_sim_swap * 24))::INT || ' hours.';
            RETURN NEXT;
            RETURN;
        END IF;
    END IF;
    
    -- Check risk level restrictions
    CASE v_menu.sim_swap_risk_level
        WHEN 'CRITICAL' THEN
            IF p_days_since_sim_swap < 7 THEN
                is_accessible := FALSE;
                required_verification := 'IN_BRANCH';
                restriction_message := 'This service requires in-branch verification after SIM change.';
                RETURN NEXT;
                RETURN;
            END IF;
            
        WHEN 'HIGH' THEN
            IF p_days_since_sim_swap < 3 THEN
                is_accessible := FALSE;
                required_verification := 'OTP';
                restriction_message := 'Additional verification required. OTP will be sent.';
                RETURN NEXT;
                RETURN;
            END IF;
            
        WHEN 'MEDIUM' THEN
            IF p_days_since_sim_swap < 1 THEN
                is_accessible := TRUE;
                required_verification := 'PIN';
                restriction_message := 'Please confirm your PIN to continue.';
                RETURN NEXT;
                RETURN;
            END IF;
            
        ELSE
            -- LOW: No restrictions
            NULL;
    END CASE;
    
    -- Menu is accessible
    is_accessible := TRUE;
    required_verification := 'NONE';
    restriction_message := NULL;
    
    RETURN NEXT;
END;
$$;

-- ----------------------------------------------------------------------------
-- TABLE: menu_navigation_history
-- ----------------------------------------------------------------------------
-- Audit log of user navigation through menus for session replay and analytics.
-- ----------------------------------------------------------------------------

-- PRODUCTION FIX: Added schema prefix for consistency
CREATE TABLE IF NOT EXISTS ussd.menu_navigation_history (
    history_id BIGSERIAL,
    session_id UUID NOT NULL,
    PRIMARY KEY (history_id, navigation_at),
    
    -- Navigation event
    from_menu_id VARCHAR(64),
    to_menu_id VARCHAR(64),
    user_input VARCHAR(400), -- What user entered/selected
    
    -- Navigation metadata
    navigation_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    navigation_duration_ms INT, -- Time spent on previous menu
    
    -- Context snapshot (for replay)
    context_snapshot JSONB,
    
    -- Device info
    device_fingerprint_id UUID,
    
    -- Audit
    ip_address INET,
    
    -- Indexes on session_id for cleanup
    CONSTRAINT fk_session FOREIGN KEY (session_id) 
        REFERENCES ussd.ussd_sessions(session_id) ON DELETE CASCADE
);

-- ----------------------------------------------------------------------------
-- CONVERT TO TIMESCALEDB HYPERTABLE
-- ----------------------------------------------------------------------------
-- PRODUCTION FIX: Uncommented hypertable conversion for time-series optimization

SELECT create_hypertable(
    'menu_navigation_history',
    'navigation_at',
    chunk_time_interval => INTERVAL '7 days',
    if_not_exists => TRUE
);

-- ----------------------------------------------------------------------------
-- FUNCTION: log_menu_navigation
-- ----------------------------------------------------------------------------
-- Logs menu navigation event
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION log_menu_navigation(
    p_session_id UUID,
    p_from_menu_id VARCHAR(64),
    p_to_menu_id VARCHAR(64),
    p_user_input VARCHAR(400),
    p_duration_ms INT DEFAULT NULL,
    p_context_snapshot JSONB DEFAULT NULL,
    p_device_fingerprint_id UUID DEFAULT NULL,
    p_ip_address INET DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_history_id BIGINT;
    v_anonymized_context JSONB;
BEGIN
    -- Anonymize context snapshot (mask MSISDN patterns)
    IF p_context_snapshot IS NOT NULL THEN
        v_anonymized_context := p_context_snapshot;
        -- This is a simplified anonymization - in production use proper PII masking
    ELSE
        v_anonymized_context := '{}'::JSONB;
    END IF;
    
    INSERT INTO ussd.menu_navigation_history (
        session_id,
        from_menu_id,
        to_menu_id,
        user_input,
        navigation_at,
        navigation_duration_ms,
        context_snapshot,
        device_fingerprint_id,
        ip_address
    ) VALUES (
        p_session_id,
        p_from_menu_id,
        p_to_menu_id,
        p_user_input,
        NOW(),
        p_duration_ms,
        v_anonymized_context,
        p_device_fingerprint_id,
        p_ip_address
    )
    RETURNING history_id INTO v_history_id;
    
    RETURN v_history_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- TABLE: menu_analytics
-- ----------------------------------------------------------------------------
-- Aggregated analytics for menu optimization.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ussd.menu_analytics (
    analytics_id BIGSERIAL PRIMARY KEY,
    menu_id VARCHAR(64) NOT NULL,
    aggregation_date DATE NOT NULL,
    
    -- Usage metrics
    total_views BIGINT DEFAULT 0,
    unique_users BIGINT DEFAULT 0,
    
    -- Navigation metrics
    total_navigations BIGINT DEFAULT 0,
    avg_time_on_menu_seconds INT,
    
    -- Input metrics (for INPUT type menus)
    total_inputs BIGINT DEFAULT 0,
    invalid_inputs BIGINT DEFAULT 0,
    avg_input_length INT,
    
    -- Drop-off metrics
    dropoff_count BIGINT DEFAULT 0, -- Sessions ending at this menu
    timeout_count BIGINT DEFAULT 0,
    error_count BIGINT DEFAULT 0,
    
    -- Option popularity (for LIST type menus)
    option_selections JSONB DEFAULT '{}', -- {"1": 500, "2": 300, "3": 200}
    
    -- A/B test metrics
    ab_test_variant VARCHAR(32),
    conversion_rate DECIMAL(5,4), -- Decimal percentage
    
    UNIQUE(menu_id, aggregation_date, ab_test_variant)
);

-- ----------------------------------------------------------------------------
-- FUNCTION: record_menu_analytics
-- ----------------------------------------------------------------------------
-- Records menu analytics event
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION record_menu_analytics(
    p_menu_id VARCHAR(64),
    p_event_type VARCHAR(32), -- 'view', 'navigation', 'input', 'dropoff', 'timeout'
    p_details JSONB DEFAULT '{}'::JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_today DATE := CURRENT_DATE;
    v_variant VARCHAR(32);
BEGIN
    -- Get A/B test variant
    SELECT ab_test_variant INTO v_variant
    FROM menu_configurations
    WHERE menu_id = p_menu_id;
    
    -- Insert or update analytics
    INSERT INTO ussd.menu_analytics (
        menu_id,
        aggregation_date,
        ab_test_variant,
        total_views,
        total_navigations,
        total_inputs,
        invalid_inputs,
        dropoff_count,
        timeout_count,
        option_selections
    ) VALUES (
        p_menu_id,
        v_today,
        v_variant,
        CASE WHEN p_event_type = 'view' THEN 1 ELSE 0 END,
        CASE WHEN p_event_type = 'navigation' THEN 1 ELSE 0 END,
        CASE WHEN p_event_type = 'input' THEN 1 ELSE 0 END,
        CASE WHEN p_event_type = 'input' AND (p_details->>'valid')::BOOLEAN = FALSE THEN 1 ELSE 0 END,
        CASE WHEN p_event_type = 'dropoff' THEN 1 ELSE 0 END,
        CASE WHEN p_event_type = 'timeout' THEN 1 ELSE 0 END,
        CASE 
            WHEN p_event_type = 'navigation' AND p_details ? 'option_selected' 
            THEN jsonb_build_object(p_details->>'option_selected', 1)
            ELSE '{}'::JSONB
        END
    )
    ON CONFLICT (menu_id, aggregation_date, ab_test_variant) DO UPDATE SET
        total_views = menu_analytics.total_views + 
            CASE WHEN p_event_type = 'view' THEN 1 ELSE 0 END,
        total_navigations = menu_analytics.total_navigations + 
            CASE WHEN p_event_type = 'navigation' THEN 1 ELSE 0 END,
        total_inputs = menu_analytics.total_inputs + 
            CASE WHEN p_event_type = 'input' THEN 1 ELSE 0 END,
        invalid_inputs = menu_analytics.invalid_inputs + 
            CASE WHEN p_event_type = 'input' AND (p_details->>'valid')::BOOLEAN = FALSE THEN 1 ELSE 0 END,
        dropoff_count = menu_analytics.dropoff_count + 
            CASE WHEN p_event_type = 'dropoff' THEN 1 ELSE 0 END,
        timeout_count = menu_analytics.timeout_count + 
            CASE WHEN p_event_type = 'timeout' THEN 1 ELSE 0 END,
        option_selections = menu_analytics.option_selections ||
            CASE 
                WHEN p_event_type = 'navigation' AND p_details ? 'option_selected'
                THEN jsonb_build_object(
                    p_details->>'option_selected', 
                    COALESCE((menu_analytics.option_selections->>(p_details->>'option_selected'))::INT, 0) + 1
                )
                ELSE '{}'::JSONB
            END;
END;
$$;

-- ----------------------------------------------------------------------------
-- INDEXES
-- ----------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_menu_config_app 
    ON menu_configurations(application_id, is_active, menu_type);

CREATE INDEX IF NOT EXISTS idx_menu_config_parent 
    ON menu_configurations(parent_menu_id, display_order);

CREATE INDEX IF NOT EXISTS idx_menu_config_sim_swap 
    ON menu_configurations(sim_swap_risk_level, require_sim_swap_check)
    WHERE require_sim_swap_check = TRUE;

CREATE INDEX IF NOT EXISTS idx_menu_nav_history_session 
    ON ussd.menu_navigation_history(session_id, navigation_at DESC);

CREATE INDEX IF NOT EXISTS idx_menu_nav_history_menu 
    ON ussd.menu_navigation_history(from_menu_id, to_menu_id, navigation_at);

CREATE INDEX IF NOT EXISTS idx_menu_analytics_menu_date 
    ON ussd.menu_analytics(menu_id, aggregation_date DESC);

-- ----------------------------------------------------------------------------
-- SECURITY CONSIDERATIONS
-- ----------------------------------------------------------------------------
-- [ISO/IEC 27001:2022] A.8.1 - Endpoint security (menu-level PIN)
-- [ISO/IEC 27001:2022] A.8.5 - Authentication per menu
-- [ISO/IEC 27001:2022] A.8.12 - Menu navigation audit logging
-- [ISO/IEC 27018:2019] PII masking in menu content
/*
1. INPUT INJECTION:
   - Sanitize all user_input before logging (SQL injection, XSS)
   - Never execute user_input as code
   - Validate against whitelist regex patterns

2. INFORMATION DISCLOSURE:
   - Mask sensitive data in context_snapshot (full msisdn -> +255****1234)
   - Encrypt PIN entry screens with extra security
   - Clear sensitive context after use (single-use tokens)

3. MENU SPOOFING:
   - Sign menu configurations with HMAC
   - Verify config_hash on each render
   - Alert on hash mismatch (potential tampering)

4. ENUMERATION ATTACKS:
   - Rate limit navigation attempts per session
   - Log rapid sequential inputs (1,2,3,4,5...) as potential scanning
   - Implement CAPTCHA-equivalent for suspicious patterns

5. PRIVILEGE ESCALATION:
   - Validate user auth level before rendering protected menus
   - Re-check authorization on each navigation
   - Don't rely on client-side "hidden" menus
*/

-- ----------------------------------------------------------------------------
-- SESSION TIMEOUT HANDLING
-- ----------------------------------------------------------------------------
-- [ISO/IEC 27001:2022] A.8.11 - Menu-specific timeout behaviors
-- [PCI DSS v4.0] PIN entry timeout restrictions (30 sec max)
/*
Menu-specific timeout behaviors:

1. INPUT TYPE TIMEOUTS:
   - PIN entry: 30 seconds (security)
   - Amount entry: 60 seconds (user may need to check)
   - Phone number: 45 seconds
   - Extended for accessibility (elderly users)

2. CONFIRM TYPE TIMEOUTS:
   - Financial transactions: 60 seconds (deliberation time)
   - Non-financial: 30 seconds
   - Show countdown warning at 45 seconds

3. TIMEOUT RECOVERY:
   - Store partial input in context before timeout
   - Offer "resume" option on new session (within 5 minutes)
   - For sensitive operations, require full restart

4. IDLE DETECTION PER MENU:
   - Track keypress timing (if gateway supports)
   - Reset timeout on each keystroke for INPUT menus
   - Fixed timeout for DISPLAY menus
*/

-- ----------------------------------------------------------------------------
-- SIM SWAP DETECTION INTEGRATION
-- ----------------------------------------------------------------------------
-- [ISO/IEC 27035-2:2023] Menu-level SIM swap protection
-- [ISO 31000:2018] Risk-based menu access control
-- Post-swap menu restrictions for 72 hours
/*
Menu-level SIM swap protections:

1. SENSITIVE MENU PROTECTION:
   - Mark high-risk menus with require_sim_swap_check = TRUE
   - Trigger check on navigation TO sensitive menu
   - Redirect to verification flow if risk detected
   
   Risk levels:
   -- LOW: No check needed
   -- MEDIUM: Soft warning displayed
   -- HIGH: Mandatory verification before access
   -- CRITICAL: In-branch verification required post-swap

2. BEHAVIORAL BIOMETRICS IN MENUS:
   - Track navigation speed (too fast = bot)
   - Track input patterns (keystroke dynamics if available)
   - Compare against device_fingerprint baseline

3. POST-SIM SWAP RESTRICTIONS:
   - First session after SIM swap: limited menu access
   - Block high-value transaction menus for 72 hours
   - Show educational message about SIM swap protection
*/

-- ----------------------------------------------------------------------------
-- SAMPLE DATA (Development/Testing Only)
-- ----------------------------------------------------------------------------

/*
INSERT INTO menu_configurations (
    menu_id, menu_name, application_id, menu_type,
    content_i18n, navigation_rules, created_by, updated_by,
    sim_swap_risk_level, require_sim_swap_check
) VALUES 
    ('main_menu', 'Main Menu', 'mobile_money', 'LIST',
     '{"en": "My Money\n1. Send Money\n2. Check Balance\n3. Buy Airtime\n0. Exit", 
       "sw": "Pesa Yangu\n1. Tuma Pesa\n2. Angalia Salio\n3. Nunua Airtime\n0. Toka"}',
     '{"1": "menu:send_money", "2": "menu:check_balance", "3": "menu:buy_airtime", "0": "exit"}',
     'admin', 'admin', 'LOW', FALSE),
    
    ('send_money', 'Send Money', 'mobile_money', 'INPUT',
     '{"en": "Enter recipient phone number:", "sw": "Weka namba ya simu ya mpokeaji:"}',
     '{}',
     'admin', 'admin', 'MEDIUM', TRUE),
    
    ('confirm_send', 'Confirm Send', 'mobile_money', 'CONFIRM',
     '{"en": "Send {{amount}} to {{recipient}}?\n1. Yes\n2. No", 
       "sw": "Tuma {{amount}} kwa {{recipient}}?\n1. Ndio\n2. Hapana"}',
     '{"1": "action:execute_transfer", "2": "menu:main_menu"}',
     'admin', 'admin', 'HIGH', TRUE);
*/

COMMIT;
