-- Migration: V006__core_movement_legs
-- Description: Core table: movement_legs
-- Dependencies: V005
-- Generated: 2026-04-02 16:56:45 UTC

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- USSD KERNEL CORE SCHEMA - MOVEMENT LEGS
-- Enterprise-Grade Immutable Ledger System
-- FILENAME:    003_movement_legs.sql
-- SCHEMA:      core
-- 1. Fixed schema comment: ussd_core → core
-- 2. Added schema creation at top
-- 3. Added IF NOT EXISTS to CREATE TABLE
-- 4. Added FK validation trigger for partitioned table reference
-- 5. Added role creation before RLS policies
-- 6. Added SECURITY DEFINER to trigger functions
-- 7. Added missing indexes on FK columns

-- Ensure schema exists
CREATE SCHEMA IF NOT EXISTS core;
-- TABLE:       movement_legs
-- DESCRIPTION: Individual debit/credit entries forming double-entry movements.
--              Each leg represents one side of an accounting transaction.


-- CREATE TABLE: movement_legs

CREATE TABLE IF NOT EXISTS core.movement_legs (
    -- Primary identifier
    leg_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Parent movement reference (links to transaction)
    transaction_id BIGINT NOT NULL,
    partition_date DATE NOT NULL,
    
    -- Multi-tenancy support (denormalized for RLS performance)
    application_id UUID,
    
    -- Sequence within the movement
    leg_sequence INTEGER NOT NULL,
    
    -- Account affected
    account_id UUID NOT NULL REFERENCES core.account_registry(account_id) ON DELETE RESTRICT,
    
    -- Direction and amount
    direction VARCHAR(6) NOT NULL CHECK (direction IN ('DEBIT', 'CREDIT')),
    amount NUMERIC(20, 8) NOT NULL CHECK (amount > 0),
    currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    
    -- Chart of accounts reference
    coa_code VARCHAR(50) NOT NULL,  -- References chart_of_accounts
    
    -- Narrative
    description TEXT,
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    posted_at TIMESTAMPTZ,  -- When movement was posted
    
    -- Constraints
    UNIQUE (transaction_id, partition_date, leg_sequence),
    CONSTRAINT chk_no_self_referential CHECK (transaction_id IS NOT NULL)
);

-- Add composite foreign key reference to transaction_log
-- Note: Cannot add direct FK due to partitioning, enforced via trigger

-- INDEXES

-- Movement lookup
CREATE INDEX IF NOT EXISTS idx_movement_legs_transaction 
    ON core.movement_legs(transaction_id, partition_date);

-- Account balance queries
CREATE INDEX IF NOT EXISTS idx_movement_legs_account 
    ON core.movement_legs(account_id, posted_at DESC);

-- Account + currency for balance calculations
CREATE INDEX IF NOT EXISTS idx_movement_legs_account_currency 
    ON core.movement_legs(account_id, currency, posted_at DESC);

-- Chart of accounts queries
CREATE INDEX IF NOT EXISTS idx_movement_legs_coa 
    ON core.movement_legs(coa_code, posted_at DESC);

-- Direction filtering
CREATE INDEX IF NOT EXISTS idx_movement_legs_direction 
    ON core.movement_legs(direction) 
    WHERE posted_at IS NOT NULL;

-- Posted date for period queries
CREATE INDEX IF NOT EXISTS idx_movement_legs_posted 
    ON core.movement_legs(posted_at DESC) 
    WHERE posted_at IS NOT NULL;

-- Multi-tenancy index
CREATE INDEX IF NOT EXISTS idx_movement_legs_application 
    ON core.movement_legs(application_id) 
    WHERE application_id IS NOT NULL;

-- IMMUTABILITY TRIGGERS

-- Prevent updates on immutable table
DROP TRIGGER IF EXISTS trg_movement_legs_prevent_update ON core.movement_legs;
CREATE TRIGGER trg_movement_legs_prevent_update
    BEFORE UPDATE ON core.movement_legs
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

-- Prevent deletes on immutable table
DROP TRIGGER IF EXISTS trg_movement_legs_prevent_delete ON core.movement_legs;
CREATE TRIGGER trg_movement_legs_prevent_delete
    BEFORE DELETE ON core.movement_legs
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

-- TRANSACTION VALIDATION TRIGGER

-- First, create a function to validate the complete transaction
CREATE OR REPLACE FUNCTION core.validate_movement_complete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_debit_sum NUMERIC(20, 8);
    v_credit_sum NUMERIC(20, 8);
    v_leg_count INTEGER;
    v_expected_legs INTEGER;
BEGIN
    -- Get expected leg count from transaction log (if available)
    SELECT COALESCE((payload->>'expected_leg_count')::INTEGER, 0)
    INTO v_expected_legs
    FROM core.transaction_log
    WHERE transaction_id = NEW.transaction_id;
    
    -- Count actual legs inserted
    SELECT COUNT(*) INTO v_leg_count
    FROM core.movement_legs
    WHERE transaction_id = NEW.transaction_id
    AND partition_date = NEW.partition_date;
    
    -- Only validate if we have all expected legs or if no expectation set (backward compat)
    IF v_expected_legs = 0 OR v_leg_count >= v_expected_legs THEN
        -- Calculate totals for this transaction
        SELECT 
            COALESCE(SUM(CASE WHEN direction = 'DEBIT' THEN amount ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN direction = 'CREDIT' THEN amount ELSE 0 END), 0)
        INTO v_debit_sum, v_credit_sum
        FROM core.movement_legs
        WHERE transaction_id = NEW.transaction_id
        AND partition_date = NEW.partition_date;
        
        -- CRITICAL FIX: Check for double-entry balance
        -- Allow small tolerance for rounding (0.00000001)
        IF ABS(v_debit_sum - v_credit_sum) > 0.00000001 THEN
            RAISE EXCEPTION 'DOUBLE_ENTRY_IMBALANCE: Debits (%) must equal Credits (%) for transaction %',
                v_debit_sum, v_credit_sum, NEW.transaction_id
                USING ERRCODE = 'P0007',
                      HINT = 'Ensure the sum of all DEBIT legs equals the sum of all CREDIT legs';
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$;

-- Per-row validation (currency consistency only)
CREATE OR REPLACE FUNCTION core.validate_movement_legs()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_transaction_currency VARCHAR(3);
BEGIN
    -- Get the currency from the first leg of this transaction
    SELECT currency INTO v_transaction_currency
    FROM core.movement_legs
    WHERE transaction_id = NEW.transaction_id
    AND partition_date = NEW.partition_date
    ORDER BY leg_sequence
    LIMIT 1;
    
    -- Check currency consistency if this is not the first leg
    IF v_transaction_currency IS NOT NULL AND v_transaction_currency != NEW.currency THEN
        RAISE EXCEPTION 'CURRENCY_MISMATCH: All legs in a movement must have the same currency. Expected: %, Got: %',
            v_transaction_currency, NEW.currency;
    END IF;
    
    RETURN NEW;
END;
$$;

-- Per-row trigger for currency validation
DROP TRIGGER IF EXISTS trg_movement_legs_validate ON core.movement_legs;
CREATE TRIGGER trg_movement_legs_validate
    BEFORE INSERT ON core.movement_legs
    FOR EACH ROW
    EXECUTE FUNCTION core.validate_movement_legs();

-- This runs at transaction commit, after all legs are inserted
DROP TRIGGER IF EXISTS trg_movement_legs_balance ON core.movement_legs;
CREATE CONSTRAINT TRIGGER trg_movement_legs_balance
    AFTER INSERT ON core.movement_legs
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION core.validate_movement_complete();

DROP TRIGGER IF EXISTS trg_movement_legs_prevent_truncate ON core.movement_legs;
CREATE TRIGGER trg_movement_legs_prevent_truncate
    BEFORE TRUNCATE ON core.movement_legs
    FOR EACH STATEMENT
    EXECUTE FUNCTION core.prevent_truncate();

-- RLS POLICIES

-- Create required roles if they don't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ussd_app_user') THEN
        CREATE ROLE ussd_app_user WITH NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ussd_kernel_role') THEN
        CREATE ROLE ussd_kernel_role WITH NOLOGIN;
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Role creation handling: %', SQLERRM;
END;
$$;

-- Enable RLS
DO $$
BEGIN
    ALTER TABLE core.movement_legs ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE core.movement_legs FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Policy: Accounts can view legs affecting their account
-- PRODUCTION FIX: Uses safe UUID helper to prevent NULL casting issues
CREATE POLICY movement_legs_account_access ON core.movement_legs
    FOR SELECT
    TO ussd_app_user
    USING (account_id = core.get_current_setting_as_uuid('app.current_account_id'));

-- Policy: Application-scoped access through transaction
CREATE POLICY movement_legs_app_access ON core.movement_legs
    FOR SELECT
    TO ussd_app_user
    USING (
        EXISTS (
            SELECT 1 FROM core.transaction_log tl
            WHERE tl.transaction_id = movement_legs.transaction_id
            AND tl.partition_date = movement_legs.partition_date
            AND (tl.application_id = core.get_current_setting_as_uuid('app.current_application_id')
                 OR tl.application_id IS NULL)
        )
    );

-- Policy: Kernel role has full access
CREATE POLICY movement_legs_kernel_access ON core.movement_legs
    FOR ALL
    TO ussd_kernel_role
    USING (true);

-- FOREIGN KEY VALIDATION TRIGGER
-- DESCRIPTION: Validates transaction_id exists in transaction_log
-- NOTE: Required because direct FK to hypertable is not supported

CREATE OR REPLACE FUNCTION core.validate_movement_legs_transaction_fk()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Validate that the referenced transaction exists
    IF NOT EXISTS (
        SELECT 1 FROM core.transaction_log 
        WHERE transaction_id = NEW.transaction_id
        AND partition_date = NEW.partition_date
    ) THEN
        RAISE EXCEPTION 'FOREIGN_KEY_VIOLATION: Transaction % with partition date % does not exist in transaction_log',
            NEW.transaction_id, NEW.partition_date
            USING ERRCODE = '23503';
    END IF;
    
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION core.validate_movement_legs_transaction_fk() IS 
    'Validates transaction_id exists in transaction_log (FK enforcement for partitioned tables)';

-- Apply the FK validation trigger
DROP TRIGGER IF EXISTS trg_movement_legs_fk_validation ON core.movement_legs;
CREATE TRIGGER trg_movement_legs_fk_validation
    BEFORE INSERT ON core.movement_legs
    FOR EACH ROW
    EXECUTE FUNCTION core.validate_movement_legs_transaction_fk();

-- ADDITIONAL INDEXES ON FOREIGN KEYS

-- Index on account_id for FK performance
CREATE INDEX IF NOT EXISTS idx_movement_legs_account_fk 
    ON core.movement_legs(account_id);

-- Index on transaction_id for FK validation performance
CREATE INDEX IF NOT EXISTS idx_movement_legs_transaction_fk 
    ON core.movement_legs(transaction_id, partition_date);

-- HELPER FUNCTIONS

-- Function to insert a movement leg
CREATE OR REPLACE FUNCTION core.insert_movement_leg(
    p_transaction_id BIGINT,
    p_partition_date DATE,
    p_account_id UUID,
    p_direction VARCHAR(6),
    p_amount NUMERIC,
    p_currency VARCHAR(3),
    p_coa_code VARCHAR(50),
    p_description TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_leg_id UUID;
    v_next_sequence INTEGER;
BEGIN
    -- Determine the next sequence number for this transaction
    SELECT COALESCE(MAX(leg_sequence), -1) + 1 INTO v_next_sequence
    FROM core.movement_legs
    WHERE transaction_id = p_transaction_id
    AND partition_date = p_partition_date;
    
    -- Insert the leg
    INSERT INTO core.movement_legs (
        transaction_id,
        partition_date,
        leg_sequence,
        account_id,
        direction,
        amount,
        currency,
        coa_code,
        description,
        posted_at
    ) VALUES (
        p_transaction_id,
        p_partition_date,
        v_next_sequence,
        p_account_id,
        p_direction,
        p_amount,
        p_currency,
        p_coa_code,
        p_description,
        NOW()
    )
    RETURNING leg_id INTO v_leg_id;
    
    RETURN v_leg_id;
END;
$$;

-- Function to verify movement balance
CREATE OR REPLACE FUNCTION core.verify_movement_balance(
    p_transaction_id BIGINT,
    p_partition_date DATE
)
RETURNS TABLE (
    is_balanced BOOLEAN,
    total_debits NUMERIC(20, 8),
    total_credits NUMERIC(20, 8),
    difference NUMERIC(20, 8)
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    SELECT 
        COALESCE(SUM(CASE WHEN direction = 'DEBIT' THEN amount ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN direction = 'CREDIT' THEN amount ELSE 0 END), 0)
    INTO total_debits, total_credits
    FROM core.movement_legs
    WHERE transaction_id = p_transaction_id
    AND partition_date = p_partition_date;
    
    difference := total_debits - total_credits;
    is_balanced := (difference = 0);
    
    RETURN NEXT;
END;
$$;

-- Function to get account legs for a period
CREATE OR REPLACE FUNCTION core.get_account_legs(
    p_account_id UUID,
    p_start_date DATE,
    p_end_date DATE
)
RETURNS TABLE (
    leg_id UUID,
    transaction_id BIGINT,
    direction VARCHAR(6),
    amount NUMERIC(20, 8),
    currency VARCHAR(3),
    coa_code VARCHAR(50),
    description TEXT,
    posted_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ml.leg_id,
        ml.transaction_id,
        ml.direction,
        ml.amount,
        ml.currency,
        ml.coa_code,
        ml.description,
        ml.posted_at
    FROM core.movement_legs ml
    WHERE ml.account_id = p_account_id
    AND ml.posted_at::DATE BETWEEN p_start_date AND p_end_date
    ORDER BY ml.posted_at, ml.leg_sequence;
END;
$$;

-- TABLE AND COLUMN COMMENTS

COMMENT ON TABLE core.movement_legs IS 
    'Individual debit/credit legs forming double-entry movements. Immutable.';

COMMENT ON COLUMN core.movement_legs.leg_id IS 
    'Unique identifier for the leg';
COMMENT ON COLUMN core.movement_legs.transaction_id IS 
    'Reference to parent transaction';
COMMENT ON COLUMN core.movement_legs.partition_date IS 
    'Partition key matching parent transaction';
COMMENT ON COLUMN core.movement_legs.leg_sequence IS 
    'Order of this leg within the movement (0-indexed)';
COMMENT ON COLUMN core.movement_legs.direction IS 
    'DEBIT or CREDIT';
COMMENT ON COLUMN core.movement_legs.amount IS 
    'Absolute amount (always positive)';
COMMENT ON COLUMN core.movement_legs.currency IS 
    'ISO 4217 currency code (3 characters)';
COMMENT ON COLUMN core.movement_legs.coa_code IS 
    'Chart of accounts reference';

-- COMPATIBILITY VIEWS
-- These views provide backward-compatible table names for reference in later migrations

-- Create accounts view in core schema (referenced in V066-V072 as core.accounts)
CREATE OR REPLACE VIEW core.accounts AS
SELECT 
    account_id,
    primary_identifier as account_number,
    account_type,
    account_subtype,
    status,
    metadata->>'currency' as currency,
    created_at
FROM core.account_registry;

-- Also create in public schema for broader compatibility
CREATE OR REPLACE VIEW accounts AS SELECT * FROM core.accounts;

-- Create transactions view in core schema (referenced in V066-V072 as core.transactions)
CREATE OR REPLACE VIEW core.transactions AS
SELECT 
    transaction_id,
    transaction_uuid,
    application_id,
    initiator_account_id,
    on_behalf_of_account_id,
    beneficiary_account_id,
    transaction_type_id,
    payload,
    amount,
    currency,
    status,
    committed_at
FROM core.transaction_log;

-- Also create in public schema for broader compatibility
CREATE OR REPLACE VIEW transactions AS SELECT * FROM core.transactions;

-- END OF FILE

COMMIT;
