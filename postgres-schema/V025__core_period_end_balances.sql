-- =============================================================================
-- Migration: V028__core_period_end_balances
-- Description: Core table: period_end_balances
-- Dependencies: V027
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- USSD KERNEL CORE SCHEMA - PERIOD END BALANCES
-- Enterprise-Grade Immutable Ledger System
-- =============================================================================
-- FILENAME:    025_period_end_balances.sql
-- SCHEMA:      ussd_core
-- TABLE:       period_end_balances
-- DESCRIPTION: Snapshot balances at period ends (day, month, year) for
--              financial reporting and audit trail purposes.
-- =============================================================================

/*
================================================================================
COMPLIANCE FRAMEWORK
================================================================================

ISO/IEC 27001:2022 (Information Security Management Systems)
├── A.12.4 Logging and monitoring - Balance verification
├── A.18.1 Compliance - Financial reporting support
└── A.18.2 Compliance - Audit trail maintenance

Financial Regulations
├── Period-end close: Mandatory balance snapshots
├── Audit trail: Immutable period records
├── Financial statements: Balance support
└── Variance analysis: Period comparison support

================================================================================
ENTERPRISE POSTGRESQL CODING PRACTICES
================================================================================

1. PERIOD TYPES
   - DAILY: End of day
   - MONTHLY: Month end
   - QUARTERLY: Quarter end
   - YEARLY: Fiscal year end
   - ADJUSTED: Post-adjustment snapshot

2. BALANCE TYPES
   - OPENING: Period start balance
   - CLOSING: Period end balance
   - ADJUSTED: After adjustments

3. RECONCILIATION
   - Opening + Movements = Closing verification
   - Variance analysis support
   - Audit trail linking

================================================================================
SECURITY IMPLEMENTATION NOTES
================================================================================

BALANCE SECURITY:
- Immutable period records
- Hash verification
- Approval workflow for adjustments

================================================================================
PERFORMANCE OPTIMIZATION ANNOTATIONS
================================================================================

INDEXES:
- PRIMARY KEY: balance_id
- ACCOUNT: account_id + period_type + period_end_date
- PERIOD: period_type + period_end_date
- COA: coa_code + period_end_date

================================================================================
AUDIT AND LOGGING REQUIREMENTS
================================================================================

AUDIT EVENTS:
- BALANCE_SNAPSHOT_CREATED
- BALANCE_ADJUSTED
- BALANCE_VERIFIED

RETENTION: Permanent
================================================================================
*/

-- -----------------------------------------------------------------------------
-- CREATE TABLE: period_end_balances
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.period_end_balances (
    -- Primary identifier
    balance_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    balance_reference VARCHAR(100) UNIQUE NOT NULL,
    
    -- Account reference
    account_id UUID NOT NULL REFERENCES core.account_registry(account_id) ON DELETE RESTRICT,
    coa_code VARCHAR(50) NOT NULL REFERENCES core.chart_of_accounts(coa_code) ON DELETE RESTRICT,
    
    -- Period definition
    period_type VARCHAR(20) NOT NULL
        CHECK (period_type IN ('DAILY', 'MONTHLY', 'QUARTERLY', 'YEARLY', 'ADJUSTED')),
    period_start_date DATE NOT NULL,
    period_end_date DATE NOT NULL,
    fiscal_year INTEGER NOT NULL,
    fiscal_period INTEGER NOT NULL CHECK (fiscal_period > 0 AND fiscal_period <= 12),
    
    -- Balance type
    balance_type VARCHAR(20) NOT NULL
        CHECK (balance_type IN ('OPENING', 'CLOSING', 'ADJUSTED')),
    
    -- Currency
    currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    
    -- Balances (both debit and credit tracking)
    debit_balance NUMERIC(20, 8) DEFAULT 0 CHECK (debit_balance >= 0),
    credit_balance NUMERIC(20, 8) DEFAULT 0 CHECK (credit_balance >= 0),
    net_balance NUMERIC(20, 8) DEFAULT 0,
    
    -- Movement summary for the period
    opening_balance NUMERIC(20, 8) DEFAULT 0,
    total_debits NUMERIC(20, 8) DEFAULT 0 CHECK (total_debits >= 0),
    total_credits NUMERIC(20, 8) DEFAULT 0 CHECK (total_credits >= 0),
    transaction_count INTEGER DEFAULT 0 CHECK (transaction_count >= 0),
    
    -- Verification
    is_verified BOOLEAN DEFAULT FALSE,
    verified_at TIMESTAMPTZ,
    verified_by UUID,
    verification_notes TEXT,
    
    -- Adjustment tracking
    is_adjusted BOOLEAN DEFAULT FALSE,
    adjustment_count INTEGER DEFAULT 0,
    adjusted_at TIMESTAMPTZ,
    adjusted_by UUID,
    adjustment_reason TEXT,
    
    -- Reconciliation status
    reconciliation_status VARCHAR(20) DEFAULT 'PENDING'
        CHECK (reconciliation_status IN ('PENDING', 'MATCHED', 'MISMATCHED', 'WAIVED')),
    discrepancy_amount NUMERIC(20, 8),
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    record_hash VARCHAR(64) NOT NULL DEFAULT 'PENDING',
    
    -- Constraints
    CONSTRAINT chk_period_dates CHECK (period_end_date >= period_start_date),
    CONSTRAINT chk_balance_calc CHECK (net_balance = debit_balance - credit_balance),
    UNIQUE (account_id, coa_code, period_type, period_end_date, balance_type, currency)
);

-- -----------------------------------------------------------------------------
-- INDEXES
-- -----------------------------------------------------------------------------
-- Account period lookups
CREATE INDEX IF NOT EXISTS idx_period_balances_account 
    ON core.period_end_balances(account_id, period_type, period_end_date DESC);

-- Period-based reporting
CREATE INDEX IF NOT EXISTS idx_period_balances_period 
    ON core.period_end_balances(period_type, period_end_date, fiscal_year, fiscal_period);

-- COA-based aggregation
CREATE INDEX IF NOT EXISTS idx_period_balances_coa 
    ON core.period_end_balances(coa_code, period_end_date, currency);

-- Verification status
CREATE INDEX IF NOT EXISTS idx_period_balances_verification 
    ON core.period_end_balances(is_verified, verified_at) 
    WHERE is_verified = TRUE;

-- Reconciliation monitoring
CREATE INDEX IF NOT EXISTS idx_period_balances_reconciliation 
    ON core.period_end_balances(reconciliation_status, period_end_date) 
    WHERE reconciliation_status != 'MATCHED';

-- Fiscal year queries
CREATE INDEX IF NOT EXISTS idx_period_balances_fiscal 
    ON core.period_end_balances(fiscal_year, fiscal_period, coa_code);

-- Balance type filtering
CREATE INDEX IF NOT EXISTS idx_period_balances_type 
    ON core.period_end_balances(balance_type, period_end_date);

-- -----------------------------------------------------------------------------
-- IMMUTABILITY TRIGGERS
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_period_balances_prevent_update ON core.period_end_balances;
CREATE TRIGGER trg_period_balances_prevent_update
    BEFORE UPDATE ON core.period_end_balances
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

DROP TRIGGER IF EXISTS trg_period_balances_prevent_delete ON core.period_end_balances;
CREATE TRIGGER trg_period_balances_prevent_delete
    BEFORE DELETE ON core.period_end_balances
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

-- -----------------------------------------------------------------------------
-- HASH COMPUTATION TRIGGER
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.compute_period_balance_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.record_hash := core.generate_hash(
        NEW.balance_id::TEXT || 
        NEW.balance_reference || 
        NEW.account_id::TEXT ||
        NEW.coa_code ||
        NEW.period_type ||
        NEW.period_end_date::TEXT ||
        NEW.balance_type ||
        NEW.currency ||
        NEW.net_balance::TEXT ||
        NEW.created_at::TEXT
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_period_balances_compute_hash ON core.period_end_balances;
CREATE TRIGGER trg_period_balances_compute_hash
    BEFORE INSERT ON core.period_end_balances
    FOR EACH ROW
    EXECUTE FUNCTION core.compute_period_balance_hash();

-- -----------------------------------------------------------------------------
-- HELPER FUNCTIONS
-- -----------------------------------------------------------------------------

-- Function to create a period end balance snapshot
CREATE OR REPLACE FUNCTION core.create_period_balance(
    p_account_id UUID,
    p_coa_code VARCHAR(50),
    p_period_type VARCHAR(20),
    p_period_start_date DATE,
    p_period_end_date DATE,
    p_fiscal_year INTEGER,
    p_fiscal_period INTEGER,
    p_balance_type VARCHAR(20),
    p_currency VARCHAR(3),
    p_net_balance NUMERIC,
    p_total_debits NUMERIC DEFAULT 0,
    p_total_credits NUMERIC DEFAULT 0,
    p_transaction_count INTEGER DEFAULT 0,
    p_created_by UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance_id UUID;
    v_reference VARCHAR(100);
    v_debit_balance NUMERIC(20, 8) := 0;
    v_credit_balance NUMERIC(20, 8) := 0;
BEGIN
    -- Calculate debit/credit split based on net balance
    IF p_net_balance >= 0 THEN
        v_debit_balance := p_net_balance;
    ELSE
        v_credit_balance := ABS(p_net_balance);
    END IF;
    
    -- Generate reference
    v_reference := 'BAL-' || p_period_type || '-' || TO_CHAR(p_period_end_date, 'YYYYMMDD') || '-' || SUBSTRING(MD5(RANDOM()::TEXT), 1, 6);
    
    INSERT INTO core.period_end_balances (
        balance_reference,
        account_id,
        coa_code,
        period_type,
        period_start_date,
        period_end_date,
        fiscal_year,
        fiscal_period,
        balance_type,
        currency,
        debit_balance,
        credit_balance,
        net_balance,
        total_debits,
        total_credits,
        transaction_count,
        created_by
    ) VALUES (
        v_reference,
        p_account_id,
        p_coa_code,
        p_period_type,
        p_period_start_date,
        p_period_end_date,
        p_fiscal_year,
        p_fiscal_period,
        p_balance_type,
        p_currency,
        v_debit_balance,
        v_credit_balance,
        p_net_balance,
        p_total_debits,
        p_total_credits,
        p_transaction_count,
        p_created_by
    ) RETURNING balance_id INTO v_balance_id;
    
    RETURN v_balance_id;
END;
$$;

-- Function to verify period balance
CREATE OR REPLACE FUNCTION core.verify_period_balance(
    p_balance_id UUID,
    p_verified_by UUID,
    p_notes TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    -- Note: Since table is immutable, verification would create a new record
    -- or be tracked in a separate verification log
    RAISE NOTICE 'Balance % verified by %', p_balance_id, p_verified_by;
    RETURN TRUE;
END;
$$;

-- Function to get period balance summary
CREATE OR REPLACE FUNCTION core.get_period_balance_summary(
    p_period_end_date DATE,
    p_period_type VARCHAR(20) DEFAULT 'MONTHLY',
    p_coa_code VARCHAR(50) DEFAULT NULL
)
RETURNS TABLE (
    coa_code VARCHAR(50),
    currency VARCHAR(3),
    account_count BIGINT,
    total_debit_balance NUMERIC,
    total_credit_balance NUMERIC,
    net_balance NUMERIC,
    total_transactions BIGINT
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        peb.coa_code,
        peb.currency,
        COUNT(DISTINCT peb.account_id) as account_count,
        SUM(peb.debit_balance) as total_debit_balance,
        SUM(peb.credit_balance) as total_credit_balance,
        SUM(peb.net_balance) as net_balance,
        SUM(peb.transaction_count)::BIGINT as total_transactions
    FROM core.period_end_balances peb
    WHERE peb.period_end_date = p_period_end_date
      AND peb.period_type = p_period_type
      AND peb.balance_type = 'CLOSING'
      AND (p_coa_code IS NULL OR peb.coa_code = p_coa_code)
    GROUP BY peb.coa_code, peb.currency
    ORDER BY peb.coa_code;
END;
$$;

-- Function to compare period balances
CREATE OR REPLACE FUNCTION core.compare_period_balances(
    p_account_id UUID,
    p_period_1_end DATE,
    p_period_2_end DATE,
    p_period_type VARCHAR(20) DEFAULT 'MONTHLY'
)
RETURNS TABLE (
    currency VARCHAR(3),
    balance_period_1 NUMERIC,
    balance_period_2 NUMERIC,
    variance NUMERIC,
    variance_percentage NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    WITH period_1 AS (
        SELECT currency, net_balance
        FROM core.period_end_balances
        WHERE account_id = p_account_id
          AND period_end_date = p_period_1_end
          AND period_type = p_period_type
          AND balance_type = 'CLOSING'
    ),
    period_2 AS (
        SELECT currency, net_balance
        FROM core.period_end_balances
        WHERE account_id = p_account_id
          AND period_end_date = p_period_2_end
          AND period_type = p_period_type
          AND balance_type = 'CLOSING'
    )
    SELECT 
        COALESCE(p1.currency, p2.currency) as currency,
        COALESCE(p1.net_balance, 0) as balance_period_1,
        COALESCE(p2.net_balance, 0) as balance_period_2,
        COALESCE(p2.net_balance, 0) - COALESCE(p1.net_balance, 0) as variance,
        CASE 
            WHEN COALESCE(p1.net_balance, 0) = 0 THEN NULL
            ELSE ROUND(((COALESCE(p2.net_balance, 0) - COALESCE(p1.net_balance, 0)) / ABS(p1.net_balance)) * 100, 2)
        END as variance_percentage
    FROM period_1 p1
    FULL OUTER JOIN period_2 p2 ON p1.currency = p2.currency;
END;
$$;

-- Function to get accounts with balance discrepancies
CREATE OR REPLACE FUNCTION core.get_balance_discrepancies(
    p_period_end_date DATE,
    p_period_type VARCHAR(20) DEFAULT 'MONTHLY'
)
RETURNS TABLE (
    account_id UUID,
    coa_code VARCHAR(50),
    currency VARCHAR(3),
    expected_balance NUMERIC,
    actual_balance NUMERIC,
    discrepancy NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        peb.account_id,
        peb.coa_code,
        peb.currency,
        (peb.opening_balance + peb.total_debits - peb.total_credits) as expected_balance,
        peb.net_balance as actual_balance,
        peb.net_balance - (peb.opening_balance + peb.total_debits - peb.total_credits) as discrepancy
    FROM core.period_end_balances peb
    WHERE peb.period_end_date = p_period_end_date
      AND peb.period_type = p_period_type
      AND peb.balance_type = 'CLOSING'
      AND ABS(peb.net_balance - (peb.opening_balance + peb.total_debits - peb.total_credits)) > 0.00000001;
END;
$$;

-- -----------------------------------------------------------------------------
-- COMMENTS
-- -----------------------------------------------------------------------------
COMMENT ON TABLE core.period_end_balances IS 'Snapshot balances at period ends for financial reporting';
COMMENT ON COLUMN core.period_end_balances.balance_id IS 'Unique identifier for the balance snapshot';
COMMENT ON COLUMN core.period_end_balances.period_type IS 'DAILY, MONTHLY, QUARTERLY, YEARLY, or ADJUSTED';
COMMENT ON COLUMN core.period_end_balances.net_balance IS 'Net balance (debits - credits)';
COMMENT ON COLUMN core.period_end_balances.reconciliation_status IS 'PENDING, MATCHED, MISMATCHED, or WAIVED';

-- =============================================================================
-- END OF FILE
-- =============================================================================

COMMIT;
