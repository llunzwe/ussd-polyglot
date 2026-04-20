-- =============================================================================
-- Migration: V068__financial_interest_interest_tables
-- Description: Financial interest: interest_tables
-- Dependencies: V067
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- USSD KERNEL FINANCIAL SCHEMA - Interest Management
-- Enterprise-Grade Immutable Ledger System
-- =============================================================================
-- FILENAME:    000_interest_tables.sql
-- SCHEMA:      core
-- TABLES:      interest_rates, interest_calculations
-- DESCRIPTION: Interest rate configuration and accrual tracking
-- 
-- COMPLIANCE:  IFRS 9 (Financial Instruments)
--              IAS 39 (Financial Instruments)
--              Local Banking Regulations
-- =============================================================================

-- =============================================================================
-- TABLE: interest_rates - Interest Rate Configuration
-- =============================================================================

CREATE TABLE IF NOT EXISTS core.interest_rates (
    rate_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rate_code VARCHAR(50) UNIQUE NOT NULL,
    rate_name VARCHAR(100) NOT NULL,
    
    rate_type VARCHAR(50) NOT NULL 
        CHECK (rate_type IN ('LOAN', 'DEPOSIT', 'SAVINGS', 'OVERDRAFT', 'PENALTY', 'COMPOUND')),
    interest_calculation_method VARCHAR(50) NOT NULL 
        CHECK (interest_calculation_method IN ('SIMPLE', 'COMPOUND', 'REDUCING_BALANCE', 'FLAT', 'DAILY_BALANCE')),
    
    base_rate NUMERIC(10,6) NOT NULL, -- Annual rate as decimal
    rate_spread NUMERIC(10,6) DEFAULT 0,
    effective_rate NUMERIC(10,6) GENERATED ALWAYS AS (base_rate + rate_spread) STORED,
    
    compounding_frequency VARCHAR(20) 
        CHECK (compounding_frequency IN ('DAILY', 'WEEKLY', 'MONTHLY', 'QUARTERLY', 'ANNUALLY')),
    
    applicable_account_types VARCHAR[],
    applicable_currencies VARCHAR(3)[],
    min_balance_threshold NUMERIC(20,8),
    max_balance_threshold NUMERIC(20,8),
    
    tiered_rates JSONB,
    
    linked_reference_rate VARCHAR(50),
    reference_rate_spread NUMERIC(10,6),
    
    effective_from DATE NOT NULL,
    effective_until DATE,
    
    status VARCHAR(20) DEFAULT 'ACTIVE',
    
    revenue_account_code VARCHAR(50) REFERENCES core.chart_of_accounts(coa_code),
    expense_account_code VARCHAR(50) REFERENCES core.chart_of_accounts(coa_code),
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    record_hash VARCHAR(64) NOT NULL DEFAULT 'PENDING'
);

CREATE INDEX IF NOT EXISTS idx_interest_rates_type ON core.interest_rates(rate_type, status);

-- =============================================================================
-- TABLE: interest_calculations - Interest Accrual Log
-- =============================================================================

CREATE TABLE IF NOT EXISTS core.interest_calculations (
    calculation_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    account_id UUID NOT NULL REFERENCES core.account_registry(account_id),
    rate_id UUID REFERENCES core.interest_rates(rate_id),
    
    calculation_date DATE NOT NULL,
    period_start_date DATE NOT NULL,
    period_end_date DATE NOT NULL,
    
    opening_balance NUMERIC(20,8) NOT NULL,
    closing_balance NUMERIC(20,8) NOT NULL,
    average_daily_balance NUMERIC(20,8),
    days_in_period INTEGER NOT NULL,
    
    interest_rate NUMERIC(10,6) NOT NULL,
    interest_amount NUMERIC(20,8) NOT NULL,
    interest_currency VARCHAR(3) NOT NULL,
    
    principal_component NUMERIC(20,8),
    interest_component NUMERIC(20,8),
    remaining_principal NUMERIC(20,8),
    
    posted_to_account BOOLEAN DEFAULT FALSE,
    posted_at TIMESTAMPTZ,
    posting_transaction_id BIGINT,
    
    reversed BOOLEAN DEFAULT FALSE,
    reversed_at TIMESTAMPTZ,
    reversal_reason TEXT,
    
    calculated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    calculated_by UUID,
    record_hash VARCHAR(64) NOT NULL DEFAULT 'PENDING',
    
    UNIQUE (account_id, calculation_date, rate_id)
);

CREATE INDEX IF NOT EXISTS idx_interest_account ON core.interest_calculations(account_id, calculation_date DESC);
CREATE INDEX IF NOT EXISTS idx_interest_posting ON core.interest_calculations(posted_to_account) WHERE posted_to_account = FALSE;

-- =============================================================================
-- HELPER FUNCTION: Calculate Interest
-- =============================================================================

CREATE OR REPLACE FUNCTION core.calculate_interest(
    p_principal NUMERIC,
    p_annual_rate NUMERIC,
    p_days INTEGER,
    p_method VARCHAR DEFAULT 'SIMPLE'
)
RETURNS NUMERIC
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    v_daily_rate NUMERIC;
    v_interest NUMERIC;
BEGIN
    v_daily_rate := p_annual_rate / 365;
    
    CASE p_method
        WHEN 'SIMPLE' THEN
            v_interest := p_principal * v_daily_rate * p_days;
        WHEN 'COMPOUND_DAILY' THEN
            v_interest := p_principal * (POWER(1 + v_daily_rate, p_days) - 1);
        ELSE
            v_interest := p_principal * v_daily_rate * p_days;
    END CASE;
    
    RETURN ROUND(v_interest, 8);
END;
$$;

-- =============================================================================
-- RLS
-- =============================================================================

DO $$
BEGIN
    ALTER TABLE core.interest_rates ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE core.interest_calculations ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

CREATE POLICY interest_rates_kernel ON core.interest_rates FOR ALL TO ussd_kernel_role USING (true);
CREATE POLICY interest_calcs_kernel ON core.interest_calculations FOR ALL TO ussd_kernel_role USING (true);

-- =============================================================================
-- END OF FILE
-- =============================================================================

COMMIT;
