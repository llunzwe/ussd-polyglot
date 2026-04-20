-- Migration: V007__core_movement_postings
-- Description: Core table: movement_postings
-- Dependencies: V006
-- Generated: 2026-04-02 16:56:45 UTC

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- USSD KERNEL CORE SCHEMA - MOVEMENT POSTINGS
-- Enterprise-Grade Immutable Ledger System
-- FILENAME:    004_movement_postings.sql
-- SCHEMA:      ussd_core
-- TABLE:       movement_postings
-- DESCRIPTION: Posted movement legs representing committed double-entry
--              transactions. Immutable record of all account balance changes.


-- CREATE TABLE: movement_postings (partitioned)

CREATE TABLE IF NOT EXISTS core.movement_postings (
    -- Primary identifier (composite key for hypertable)
    posting_id UUID DEFAULT gen_random_uuid(),
    
    -- Source transaction reference
    transaction_id BIGINT NOT NULL,
    partition_date DATE NOT NULL,
    
    -- Source movement leg
    leg_id UUID NOT NULL REFERENCES core.movement_legs(leg_id) ON DELETE RESTRICT,
    
    -- Multi-tenancy support (denormalized for RLS performance)
    application_id UUID,
    
    -- Affected account
    account_id UUID NOT NULL REFERENCES core.account_registry(account_id) ON DELETE RESTRICT,
    
    -- Posting details
    direction VARCHAR(6) NOT NULL CHECK (direction IN ('DEBIT', 'CREDIT')),
    amount NUMERIC(20, 8) NOT NULL CHECK (amount > 0),
    currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    
    -- Running balance after this posting
    running_balance NUMERIC(20, 8) NOT NULL,
    
    -- Chart of accounts
    coa_code VARCHAR(50) NOT NULL,  -- References chart_of_accounts
    
    -- Accounting dates
    accounting_date DATE NOT NULL,
    value_date DATE NOT NULL,
    
    -- Narrative
    description TEXT,
    
    -- Reversal tracking
    is_reversal BOOLEAN DEFAULT FALSE,
    reversed_posting_id UUID,  -- Self-reference deferred due to composite PK
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    posted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Partition key
    partition_date_posting DATE NOT NULL DEFAULT CURRENT_DATE,
    
    -- Constraints
    CONSTRAINT pk_movement_postings PRIMARY KEY (posting_id, accounting_date),
    CONSTRAINT chk_value_date_valid CHECK (value_date >= accounting_date - INTERVAL '30 days'),
    CONSTRAINT chk_no_self_reversal CHECK (reversed_posting_id IS NULL OR reversed_posting_id != posting_id)
);

-- CONVERT TO TIMESCALEDB HYPERTABLE

-- Convert to hypertable for time-series optimization
-- Using accounting_date as the time column for automatic partitioning
SELECT create_hypertable(
    'core.movement_postings',
    'accounting_date',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

-- INDEXES

-- Account + date for balance queries (most important)
CREATE INDEX IF NOT EXISTS idx_movement_postings_account_date 
    ON core.movement_postings(account_id, accounting_date DESC, posting_id);

-- Account + currency for multi-currency balance
CREATE INDEX IF NOT EXISTS idx_movement_postings_account_currency 
    ON core.movement_postings(account_id, currency, accounting_date DESC);

-- Transaction lookup
CREATE INDEX IF NOT EXISTS idx_movement_postings_transaction 
    ON core.movement_postings(transaction_id, accounting_date);

-- Leg lookup
CREATE INDEX IF NOT EXISTS idx_movement_postings_leg 
    ON core.movement_postings(leg_id);

-- TIMESCALEDB OPTIMIZATIONS (optional - skipped if extension unavailable)
DO $$
BEGIN
    ALTER TABLE core.movement_postings SET (
        timescaledb.compress,
        timescaledb.compress_segmentby = 'account_id, currency'
    );
    PERFORM add_compression_policy('core.movement_postings', INTERVAL '90 days');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TimescaleDB compression setup skipped: %', SQLERRM;
END;
$$;

-- Accounting date for period queries
CREATE INDEX IF NOT EXISTS idx_movement_postings_accounting_date 
    ON core.movement_postings(accounting_date DESC);

-- Value date queries
CREATE INDEX IF NOT EXISTS idx_movement_postings_value_date 
    ON core.movement_postings(value_date DESC);

-- Chart of accounts queries
CREATE INDEX IF NOT EXISTS idx_movement_postings_coa 
    ON core.movement_postings(coa_code, accounting_date DESC);

-- Multi-tenancy index
CREATE INDEX IF NOT EXISTS idx_movement_postings_application 
    ON core.movement_postings(application_id, accounting_date DESC) 
    WHERE application_id IS NOT NULL;

-- Reversal tracking
CREATE INDEX IF NOT EXISTS idx_movement_postings_reversal 
    ON core.movement_postings(reversed_posting_id) 
    WHERE reversed_posting_id IS NOT NULL;

-- Reversal flag
CREATE INDEX IF NOT EXISTS idx_movement_postings_is_reversal 
    ON core.movement_postings(account_id, accounting_date DESC) 
    WHERE is_reversal = TRUE;

-- IMMUTABILITY TRIGGERS

-- Prevent updates on immutable table
DROP TRIGGER IF EXISTS trg_movement_postings_prevent_update ON core.movement_postings;
CREATE TRIGGER trg_movement_postings_prevent_update
    BEFORE UPDATE ON core.movement_postings
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

-- Prevent deletes on immutable table
DROP TRIGGER IF EXISTS trg_movement_postings_prevent_delete ON core.movement_postings;
CREATE TRIGGER trg_movement_postings_prevent_delete
    BEFORE DELETE ON core.movement_postings
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

-- TRUNCATE PROTECTION
DROP TRIGGER IF EXISTS trg_movement_postings_prevent_truncate ON core.movement_postings;
CREATE TRIGGER trg_movement_postings_prevent_truncate
    BEFORE TRUNCATE ON core.movement_postings
    FOR EACH STATEMENT
    EXECUTE FUNCTION core.prevent_truncate();

-- RLS POLICIES

-- Enable RLS with FORCE (critical for security - prevents table owner bypass)
DO $$
BEGIN
    ALTER TABLE core.movement_postings ENABLE ROW LEVEL SECURITY;
    ALTER TABLE core.movement_postings FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'RLS setup on movement_postings hypertable: %', SQLERRM;
END $$;

-- Policy: Accounts can view their own postings
-- PRODUCTION FIX: Uses safe UUID helper to prevent NULL casting issues
CREATE POLICY movement_postings_account_access ON core.movement_postings
    FOR SELECT
    TO ussd_app_user
    USING (account_id = core.get_current_setting_as_uuid('app.current_account_id'));

-- Policy: Application-scoped access (using denormalized application_id for performance)
CREATE POLICY movement_postings_app_access ON core.movement_postings
    FOR SELECT
    TO ussd_app_user
    USING (
        application_id = core.get_current_setting_as_uuid('app.current_application_id')
        OR application_id IS NULL
    );

-- Policy: Kernel role has full access
CREATE POLICY movement_postings_kernel_access ON core.movement_postings
    FOR ALL
    TO ussd_kernel_role
    USING (true);

-- HELPER FUNCTIONS

-- Function to get current account balance
CREATE OR REPLACE FUNCTION core.get_account_balance(
    p_account_id UUID,
    p_currency VARCHAR(3) DEFAULT NULL
)
RETURNS TABLE (
    currency VARCHAR(3),
    balance NUMERIC(20, 8),
    last_posting_id UUID,
    last_posting_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        mp.currency,
        mp.running_balance,
        mp.posting_id,
        mp.posted_at
    FROM core.movement_postings mp
    WHERE mp.account_id = p_account_id
    AND (p_currency IS NULL OR mp.currency = p_currency)
    ORDER BY mp.accounting_date DESC, mp.posting_id DESC
    LIMIT 1;
END;
$$;

-- Function to get account balance as of a specific date
CREATE OR REPLACE FUNCTION core.get_account_balance_as_of(
    p_account_id UUID,
    p_as_of_date DATE,
    p_currency VARCHAR(3) DEFAULT NULL
)
RETURNS TABLE (
    currency VARCHAR(3),
    balance NUMERIC(20, 8)
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        mp.currency,
        mp.running_balance
    FROM core.movement_postings mp
    WHERE mp.account_id = p_account_id
    AND mp.accounting_date <= p_as_of_date
    AND (p_currency IS NULL OR mp.currency = p_currency)
    ORDER BY mp.accounting_date DESC, mp.posting_id DESC
    LIMIT 1;
END;
$$;

-- Function to get posting history for an account
CREATE OR REPLACE FUNCTION core.get_account_posting_history(
    p_account_id UUID,
    p_start_date DATE,
    p_end_date DATE,
    p_currency VARCHAR(3) DEFAULT NULL
)
RETURNS TABLE (
    posting_id UUID,
    transaction_id BIGINT,
    direction VARCHAR(6),
    amount NUMERIC(20, 8),
    currency VARCHAR(3),
    running_balance NUMERIC(20, 8),
    accounting_date DATE,
    description TEXT,
    posted_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        mp.posting_id,
        mp.transaction_id,
        mp.direction,
        mp.amount,
        mp.currency,
        mp.running_balance,
        mp.accounting_date,
        mp.description,
        mp.posted_at
    FROM core.movement_postings mp
    WHERE mp.account_id = p_account_id
    AND mp.accounting_date BETWEEN p_start_date AND p_end_date
    AND (p_currency IS NULL OR mp.currency = p_currency)
    ORDER BY mp.accounting_date, mp.posting_id;
END;
$$;

-- TABLE AND COLUMN COMMENTS

COMMENT ON TABLE core.movement_postings IS 
    'Posted double-entry movements with running balances. PARTITIONED by accounting_date. Immutable.';

COMMENT ON COLUMN core.movement_postings.posting_id IS 
    'Unique identifier for the posting';
COMMENT ON COLUMN core.movement_postings.transaction_id IS 
    'Reference to parent transaction';
COMMENT ON COLUMN core.movement_postings.leg_id IS 
    'Reference to source movement leg';
COMMENT ON COLUMN core.movement_postings.direction IS 
    'DEBIT or CREDIT';
COMMENT ON COLUMN core.movement_postings.running_balance IS 
    'Account balance after this posting is applied';
COMMENT ON COLUMN core.movement_postings.accounting_date IS 
    'Date for accounting/bookkeeping purposes';
COMMENT ON COLUMN core.movement_postings.value_date IS 
    'Date when funds become available';
COMMENT ON COLUMN core.movement_postings.is_reversal IS 
    'TRUE if this posting reverses a previous posting';
COMMENT ON COLUMN core.movement_postings.reversed_posting_id IS 
    'Reference to the posting being reversed (if applicable)';

-- END OF FILE

COMMIT;
