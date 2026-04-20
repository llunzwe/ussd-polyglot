-- =============================================================================
-- Migration: V191__triggers_account_triggers
-- Description: triggers: account_triggers
-- Dependencies: V190
-- Generated: 2026-04-02 16:56:48 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- ============================================================================
-- COMPLIANCE STANDARDS
-- ============================================================================
-- ISO/IEC 27001:2022 - A.8.2 (Data Integrity), A.12.4 (Logging)
-- ISO/IEC 27040:2024 - Storage Security
-- ============================================================================

-- Trigger: Prevent account record update (immutability)
CREATE OR REPLACE FUNCTION core.prevent_account_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = core, public
AS $$
BEGIN
    -- Allow updates only to is_current, valid_to, superseded_by (versioning)
    -- and balance fields (operational)
    IF OLD.account_number != NEW.account_number OR
       OLD.account_type != NEW.account_type OR
       OLD.currency_code != NEW.currency_code OR
       OLD.created_at != NEW.created_at OR
       OLD.created_by != NEW.created_by THEN
        RAISE EXCEPTION 'Account record is immutable. Create new version instead.';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_account_registry_immutability ON core.account_registry;
CREATE TRIGGER trg_account_registry_immutability
    BEFORE UPDATE ON core.account_registry
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_account_update();

COMMENT ON TRIGGER trg_account_registry_immutability ON core.account_registry IS 'Enforces immutability on core account fields';

-- Trigger: Calculate record hash on insert
CREATE OR REPLACE FUNCTION core.calculate_account_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = core, public
AS $$
DECLARE
    v_currency VARCHAR(3);
BEGIN
    v_currency := COALESCE(NEW.metadata->>'currency', 'TZS');
    NEW.record_hash := encode(
        digest(
            NEW.account_id::text || 
            NEW.primary_identifier || 
            NEW.account_type || 
            v_currency || 
            NEW.created_at::text ||
            COALESCE(NEW.parent_account_id::text, ''),
            'sha256'
        ),
        'hex'
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_account_registry_hash ON core.account_registry;
CREATE TRIGGER trg_account_registry_hash
    BEFORE INSERT ON core.account_registry
    FOR EACH ROW
    EXECUTE FUNCTION core.calculate_account_hash();

-- Trigger: Audit account changes
CREATE OR REPLACE FUNCTION core.audit_account_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = core, public
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO core.audit_trail (
            audit_reference,
            audit_event,
            audit_category,
            audit_level,
            action,
            action_status,
            table_name,
            record_id,
            old_data,
            new_data,
            actor_name,
            audit_description
        ) VALUES (
            'AUTO-' || substr(md5(random()::text), 1, 16),
            'ACCOUNT_CREATED',
            'DATA_CHANGE',
            'INFO',
            'INSERT',
            'SUCCESS',
            'account_registry',
            NEW.account_id::text,
            '{}'::jsonb,
            jsonb_build_object(
                'account_id', NEW.account_id,
                'account_type', NEW.account_type,
                'primary_identifier', NEW.primary_identifier
            ),
            current_user,
            jsonb_build_object(
                'txid', txid_current()
            )::text
        );
        RETURN NEW;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_account_registry_audit ON core.account_registry;
CREATE TRIGGER trg_account_registry_audit
    AFTER INSERT ON core.account_registry
    FOR EACH ROW
    EXECUTE FUNCTION core.audit_account_change();

COMMIT;
