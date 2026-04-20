-- =============================================================================
-- Migration: V123__functions_account_ops
-- Description: functions: account_ops
-- Dependencies: V122
-- Generated: 2026-04-02 16:56:47 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- ============================================================================
-- App Schema - Application Operations
-- ============================================================================

-- PRODUCTION FIX: Updated to match actual V030 table schema (app_name not application_name, etc.)

-- Function: Register new application
CREATE OR REPLACE FUNCTION app.register_application(
    p_app_name VARCHAR(255),
    p_app_code VARCHAR(50),
    p_description TEXT DEFAULT NULL,
    p_app_tier VARCHAR(20) DEFAULT 'standard'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app, public
AS $$
DECLARE
    v_application_id UUID;
    v_tenant_id UUID;
BEGIN
    v_application_id := gen_random_uuid();
    v_tenant_id := gen_random_uuid();

    INSERT INTO app.application_registry (
        application_id,
        app_code,
        app_name,
        app_description,
        app_category,
        app_tier,
        default_owner_account_id,
        api_key_hash,
        status,
        max_transactions_per_minute,
        max_storage_gb,
        max_concurrent_sessions,
        version,
        created_at,
        updated_at,
        created_by,
        updated_by,
        ledger_tenant_id,
        metadata,
        is_current
    ) VALUES (
        v_application_id,
        p_app_code,
        p_app_name,
        p_description,
        'general',
        p_app_tier,
        '00000000-0000-0000-0000-000000000000'::UUID, -- Placeholder - should be set properly
        encode(digest(gen_random_uuid()::text, 'sha256'), 'hex'),
        'pending',
        CASE p_app_tier 
            WHEN 'basic' THEN 100
            WHEN 'standard' THEN 1000
            WHEN 'premium' THEN 10000
            WHEN 'enterprise' THEN 100000
            ELSE 1000
        END,
        CASE p_app_tier
            WHEN 'basic' THEN 10
            WHEN 'standard' THEN 100
            WHEN 'premium' THEN 500
            WHEN 'enterprise' THEN 1000
            ELSE 100
        END,
        CASE p_app_tier
            WHEN 'basic' THEN 10
            WHEN 'standard' THEN 100
            WHEN 'premium' THEN 500
            WHEN 'enterprise' THEN 1000
            ELSE 100
        END,
        1,
        now(),
        now(),
        current_user::UUID,
        current_user::UUID,
        v_tenant_id,
        '{}'::JSONB,
        TRUE
    );

    RETURN v_application_id;
END;
$$;

COMMENT ON FUNCTION app.register_application IS 'Registers a new multi-tenant application';

-- Function: Activate application
CREATE OR REPLACE FUNCTION app.activate_application(
    p_application_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app, public
AS $$
BEGIN
    UPDATE app.application_registry
    SET status = 'active',
        activated_at = now()
    WHERE application_id = p_application_id
    AND status = 'pending';

    RETURN FOUND;
END;
$$;

COMMENT ON FUNCTION app.activate_application IS 'Activates a pending application';

-- Function: Enroll account in application
-- NOTE: Requires V032 app.account_membership table
CREATE OR REPLACE FUNCTION app.enroll_account(
    p_application_id UUID,
    p_account_id UUID,
    p_role_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app, public
AS $$
DECLARE
    v_membership_id UUID;
BEGIN
    v_membership_id := gen_random_uuid();

    INSERT INTO app.account_membership (
        membership_id,
        account_id,
        application_id,
        role_id,
        status,
        created_at,
        created_by
    ) VALUES (
        v_membership_id,
        p_account_id,
        p_application_id,
        p_role_id,
        'active',
        now(),
        current_user::UUID
    );

    RETURN v_membership_id;
END;
$$;

COMMENT ON FUNCTION app.enroll_account IS 'Enrolls an account in an application';

COMMIT;
