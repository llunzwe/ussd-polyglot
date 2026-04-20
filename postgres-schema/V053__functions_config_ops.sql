-- =============================================================================
-- Migration: V130__functions_config_ops
-- Description: functions: config_ops
-- Dependencies: V129
-- Generated: 2026-04-02 16:56:47 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- ============================================================================
-- App Schema - Configuration Operations
-- ============================================================================

-- Function: Set configuration value
CREATE OR REPLACE FUNCTION app.set_config(
    p_application_id UUID,
    p_config_key VARCHAR(100),
    p_config_value JSONB,
    p_description TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app, public
AS $$
DECLARE
    v_config_id UUID;
    v_old_value JSONB;
BEGIN
    -- Get old value for audit
    SELECT config_value INTO v_old_value
    FROM app.configuration_store
    WHERE application_id = p_application_id
    AND config_key = p_config_key
    AND is_current = TRUE;

    -- Mark old version as superseded
    UPDATE app.configuration_store
    SET is_current = FALSE,
        valid_to = now(),
        superseded_by = gen_random_uuid()
    WHERE application_id = p_application_id
    AND config_key = p_config_key
    AND is_current = TRUE;

    -- Insert new version
    v_config_id := gen_random_uuid();

    INSERT INTO app.configuration_store (
        config_id,
        application_id,
        config_key,
        config_value,
        description,
        valid_from,
        valid_to,
        superseded_by,
        is_current,
        previous_value,
        changed_by,
        change_reason,
        created_at
    ) VALUES (
        v_config_id,
        p_application_id,
        p_config_key,
        p_config_value,
        p_description,
        now(),
        'infinity'::timestamptz,
        NULL,
        TRUE,
        v_old_value,
        current_user,
        'Configuration update',
        now()
    );

    RETURN v_config_id;
END;
$$;

COMMENT ON FUNCTION app.set_config IS 'Sets configuration value with versioning';

-- Function: Get configuration value
CREATE OR REPLACE FUNCTION app.get_config(
    p_application_id UUID,
    p_config_key VARCHAR(100),
    p_default_value JSONB DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SET search_path = app, public
AS $$
DECLARE
    v_value JSONB;
BEGIN
    SELECT config_value INTO v_value
    FROM app.configuration_store
    WHERE application_id = p_application_id
    AND config_key = p_config_key
    AND is_current = TRUE;

    RETURN COALESCE(v_value, p_default_value);
END;
$$;

COMMENT ON FUNCTION app.get_config IS 'Gets current configuration value';

-- Function: Toggle feature flag
CREATE OR REPLACE FUNCTION app.toggle_feature(
    p_application_id UUID,
    p_feature_name VARCHAR(64),
    p_enabled BOOLEAN
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app, public
AS $$
DECLARE
    v_flag_id UUID;
BEGIN
    SELECT flag_id INTO v_flag_id
    FROM app.feature_flags
    WHERE application_id = p_application_id
    AND feature_name = p_feature_name
    AND is_current = TRUE;

    IF v_flag_id IS NULL THEN
        INSERT INTO app.feature_flags (
            flag_id, application_id, feature_name, enabled,
            rollout_percentage, valid_from, valid_to, superseded_by,
            is_current, created_at, created_by
        ) VALUES (
            gen_random_uuid(), p_application_id, p_feature_name, p_enabled,
            CASE WHEN p_enabled THEN 100 ELSE 0 END,
            now(), 'infinity'::timestamptz, NULL, TRUE, now(), current_user
        );
    ELSE
        UPDATE app.feature_flags
        SET enabled = p_enabled,
            rollout_percentage = CASE WHEN p_enabled THEN 100 ELSE 0 END
        WHERE flag_id = v_flag_id;
    END IF;

    RETURN TRUE;
END;
$$;

COMMENT ON FUNCTION app.toggle_feature IS 'Enables or disables feature flag';

-- Function: Check feature enabled
CREATE OR REPLACE FUNCTION app.is_feature_enabled(
    p_application_id UUID,
    p_feature_name VARCHAR(64)
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SET search_path = app, public
AS $$
DECLARE
    v_enabled BOOLEAN;
    v_percentage INTEGER;
BEGIN
    SELECT enabled, rollout_percentage 
    INTO v_enabled, v_percentage
    FROM app.feature_flags
    WHERE application_id = p_application_id
    AND feature_name = p_feature_name
    AND is_current = TRUE;

    IF v_enabled IS NULL THEN
        RETURN FALSE;
    END IF;

    -- Check rollout percentage
    IF v_percentage < 100 THEN
        -- Hash user identifier for consistent rollout
        RETURN (abs(hashtext(current_user)) % 100) < v_percentage;
    END IF;

    RETURN v_enabled;
END;
$$;

COMMENT ON FUNCTION app.is_feature_enabled IS 'Checks if feature is enabled for user';

COMMIT;
