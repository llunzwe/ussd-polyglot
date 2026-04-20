-- =============================================================================
-- Migration: V194__triggers_transaction_triggers
-- Description: triggers: transaction_triggers
-- Dependencies: V193
-- Generated: 2026-04-02 16:56:48 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- ============================================================================
-- Transaction and Movement Triggers
-- ============================================================================

-- Trigger: Prevent transaction deletion
CREATE OR REPLACE FUNCTION core.prevent_transaction_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = core, public
AS $$
BEGIN
    RAISE EXCEPTION 'Transactions are immutable and cannot be deleted';
END;
$$;

DROP TRIGGER IF EXISTS trg_transactions_no_delete ON core.transaction_log;
CREATE TRIGGER trg_transactions_no_delete
    BEFORE DELETE ON core.transaction_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_transaction_delete();

-- Trigger: Prevent transaction modification
CREATE OR REPLACE FUNCTION core.prevent_transaction_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = core, public
AS $$
BEGIN
    -- Allow block linkage updates (core ledger workflow)
    IF to_jsonb(OLD) - '{block_id,block_sequence}'::text[] = 
       to_jsonb(NEW) - '{block_id,block_sequence}'::text[] THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'Transactions are immutable and cannot be modified';
END;
$$;

DROP TRIGGER IF EXISTS trg_transactions_immutable ON core.transaction_log;
CREATE TRIGGER trg_transactions_immutable
    BEFORE UPDATE ON core.transaction_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_transaction_update();

-- Trigger: Prevent movement modification
CREATE OR REPLACE FUNCTION core.prevent_movement_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = core, public
AS $$
BEGIN
    -- Only allow is_reversed to be updated
    IF OLD.is_reversed != NEW.is_reversed OR
       OLD.reversed_at IS DISTINCT FROM NEW.reversed_at OR
       OLD.reversal_reason IS DISTINCT FROM NEW.reversal_reason THEN
        RETURN NEW;
    END IF;
    
    RAISE EXCEPTION 'Movements are immutable except for reversal status';
END;
$$;

DROP TRIGGER IF EXISTS trg_movements_immutable ON core.movement_postings;
CREATE TRIGGER trg_movements_immutable
    BEFORE UPDATE ON core.movement_postings
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_movement_update();

-- Trigger: Audit transaction creation
CREATE OR REPLACE FUNCTION core.audit_transaction_create()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = core, public
AS $$
BEGIN
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
        'TRANSACTION_CREATED',
        'DATA_CHANGE',
        'INFO',
        'CREATE',
        'SUCCESS',
        'transaction_log',
        NEW.transaction_id::text,
        '{}'::jsonb,
        jsonb_build_object(
            'transaction_type_id', NEW.transaction_type_id,
            'hash', NEW.transaction_hash
        ),
        current_user,
        jsonb_build_object(
            'txid', txid_current()
        )::text
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_transactions_audit ON core.transaction_log;
CREATE TRIGGER trg_transactions_audit
    AFTER INSERT ON core.transaction_log
    FOR EACH ROW
    EXECUTE FUNCTION core.audit_transaction_create();

COMMIT;
