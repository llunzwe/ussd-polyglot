-- =============================================================================
-- Migration: V067__financial_fees_fee_tables
-- Description: Financial fees: fee_tables
-- Dependencies: V066
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- USSD KERNEL FINANCIAL SCHEMA - Fee Management
-- Enterprise-Grade Immutable Ledger System
-- =============================================================================
-- FILENAME:    000_fee_tables.sql
-- SCHEMA:      core
-- TABLES:      fee_schedules, fee_transactions
-- DESCRIPTION: Fee structure configuration and transaction logging
-- 
-- COMPLIANCE:  IFRS 15 (Revenue Recognition)
--              GAAP Revenue Recognition
--              PCI DSS (if fee involves card transactions)
-- =============================================================================

-- =============================================================================
-- TABLE: fee_schedules - Fee Structure Configuration
-- =============================================================================

CREATE TABLE IF NOT EXISTS core.fee_schedules (
    schedule_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    schedule_code VARCHAR(50) UNIQUE NOT NULL,
    schedule_name VARCHAR(100) NOT NULL,
    schedule_description TEXT,
    
    -- Fee classification
    fee_type VARCHAR(50) NOT NULL 
        CHECK (fee_type IN ('TRANSACTION', 'MONTHLY', 'ANNUAL', 'PERCENTAGE', 'TIERED', 'VOLUME_BASED', 'PENALTY')),
    fee_category VARCHAR(50) NOT NULL 
        CHECK (fee_category IN ('SERVICE', 'PENALTY', 'PROCESSING', 'MAINTENANCE', 'OVERDRAFT', 'LATE_PAYMENT', 'FX')),
    
    -- Applicability
    applicable_transaction_types UUID[],
    applicable_account_types VARCHAR[],
    applicable_channels VARCHAR[], -- MOBILE, WEB, API, USSD, POS
    
    -- Calculation method
    calculation_method VARCHAR(50) NOT NULL 
        CHECK (calculation_method IN ('FLAT', 'PERCENTAGE', 'TIERED', 'VOLUME', 'HYBRID', 'MIN_MAX')),
    
    -- Fee amounts
    flat_fee_amount NUMERIC(20,8),
    percentage_rate NUMERIC(10,6),
    minimum_fee NUMERIC(20,8) DEFAULT 0,
    maximum_fee NUMERIC(20,8),
    
    -- Tier configuration
    tier_configuration JSONB,
    volume_discount_config JSONB,
    
    -- Mobile Money Provider Specific Fees (NULL = use default/generic fees)
    -- NOTE: Business APIs only support merchant payments and payouts, not agent operations
    mobile_money_fee_config JSONB,
    /*
    mobile_money_fee_config JSONB structure (Business Merchant APIs Only):
    {
        "provider": "ecocash", -- ecocash|telecash|onemoney
        "transaction_fees": {
            "merchant_payment_received": {
                "customer_fee": {"type": "fixed", "amount": 0.0},
                "merchant_fee": {"type": "percentage", "rate": 1.5},
                "platform_fee": {"type": "percentage", "rate": 0.5}
            },
            "payout_sent": {
                "sender_fee": {"type": "fixed", "amount": 0.50},
                "platform_fee": {"type": "percentage", "rate": 0.3}
            },
            "refund": {
                "customer_fee": {"type": "fixed", "amount": 0.0},
                "merchant_fee": {"type": "fixed", "amount": 0.0},
                "platform_fee": {"type": "fixed", "amount": 0.0}
            }
        },
        "limits": {
            "min_transaction": 1.00,
            "max_transaction": 5000.00,
            "daily_limit": 10000.00,
            "monthly_limit": 100000.00
        }
    }
    -- NOTE: cash_in, cash_out, peer_transfer, bill_payment, airtime_purchase are 
    -- CONSUMER/AGENT operations not available via business merchant APIs.
    -- This schema is for BUSINESSES receiving payments, not mobile money agents.
    */
    
    -- Applicability rules
    currency VARCHAR(3),
    applicable_providers VARCHAR(20)[], -- For provider-specific fee schedules
    min_transaction_amount NUMERIC(20,8),
    max_transaction_amount NUMERIC(20,8),
    min_account_balance NUMERIC(20,8),
    max_monthly_waivers INTEGER DEFAULT 0,
    
    -- Waiver conditions
    waiver_conditions JSONB, -- {premium_accounts: true, min_balance: 1000}
    
    -- Timing
    valid_from DATE NOT NULL DEFAULT CURRENT_DATE,
    valid_until DATE,
    
    -- Status
    status VARCHAR(20) DEFAULT 'ACTIVE' CHECK (status IN ('DRAFT', 'ACTIVE', 'DEPRECATED')),
    
    -- GL posting
    revenue_account_code VARCHAR(50) REFERENCES core.chart_of_accounts(coa_code),
    deferred_revenue_account_code VARCHAR(50) REFERENCES core.chart_of_accounts(coa_code),
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID REFERENCES core.account_registry(account_id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by UUID REFERENCES core.account_registry(account_id),
    approved_by UUID REFERENCES core.account_registry(account_id),
    approved_at TIMESTAMPTZ,
    record_hash VARCHAR(64) NOT NULL DEFAULT 'PENDING'
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_fee_schedules_type ON core.fee_schedules(fee_type, status);
CREATE INDEX IF NOT EXISTS idx_fee_schedules_active ON core.fee_schedules(schedule_id) WHERE status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS idx_fee_schedules_valid ON core.fee_schedules(valid_from, valid_until);

-- =============================================================================
-- TABLE: fee_transactions - Fee Application Log
-- =============================================================================

CREATE TABLE IF NOT EXISTS core.fee_transactions (
    fee_transaction_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    fee_reference VARCHAR(100) UNIQUE NOT NULL,
    
    -- Source
    source_transaction_id BIGINT, -- References core.transaction_log (composite PK prevents direct FK)
    source_schedule_id UUID REFERENCES core.fee_schedules(schedule_id),
    
    -- Fee details
    fee_type VARCHAR(50) NOT NULL,
    fee_description TEXT,
    
    -- Calculation basis
    base_amount NUMERIC(20,8) NOT NULL,
    fee_amount NUMERIC(20,8) NOT NULL,
    fee_currency VARCHAR(3) NOT NULL,
    fee_percentage NUMERIC(10,6),
    
    -- Accounts
    charged_account_id UUID NOT NULL REFERENCES core.account_registry(account_id),
    revenue_account_code VARCHAR(50) REFERENCES core.chart_of_accounts(coa_code),
    
    -- Status
    charge_status VARCHAR(20) DEFAULT 'PENDING' 
        CHECK (charge_status IN ('PENDING', 'CHARGED', 'REVERSED', 'WAIVED', 'FAILED')),
    
    -- Reversal/Waiver
    reversed_at TIMESTAMPTZ,
    reversed_by UUID REFERENCES core.account_registry(account_id),
    reversal_reason TEXT,
    reversal_authorized_by UUID,
    
    waived_at TIMESTAMPTZ,
    waived_by UUID REFERENCES core.account_registry(account_id),
    waiver_reason TEXT,
    waiver_approval_reference VARCHAR(100),
    
    -- GL posting
    posted_to_gl BOOLEAN DEFAULT FALSE,
    gl_posting_reference VARCHAR(100),
    posted_at TIMESTAMPTZ,
    posting_transaction_id BIGINT,
    
    -- Timing
    calculated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    charged_at TIMESTAMPTZ,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    record_hash VARCHAR(64) NOT NULL DEFAULT 'PENDING'
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_fee_txn_source ON core.fee_transactions(source_transaction_id);
CREATE INDEX IF NOT EXISTS idx_fee_txn_account ON core.fee_transactions(charged_account_id, charged_at DESC);
CREATE INDEX IF NOT EXISTS idx_fee_txn_status ON core.fee_transactions(charge_status, fee_type);
CREATE INDEX IF NOT EXISTS idx_fee_txn_gl ON core.fee_transactions(posted_to_gl) WHERE posted_to_gl = FALSE;

-- =============================================================================
-- TRIGGERS
-- =============================================================================

CREATE OR REPLACE FUNCTION core.compute_fee_schedule_hash()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := NOW();
    NEW.record_hash := core.generate_hash(
        NEW.schedule_id::TEXT || NEW.schedule_code || NEW.fee_type || 
        NEW.calculation_method || NEW.status || NEW.created_at::TEXT
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_fee_schedule_hash ON Fee;
CREATE TRIGGER trg_fee_schedule_hash BEFORE INSERT OR UPDATE ON core.fee_schedules
    FOR EACH ROW EXECUTE FUNCTION core.compute_fee_schedule_hash();

CREATE OR REPLACE FUNCTION core.compute_fee_transaction_hash()
RETURNS TRIGGER AS $$
BEGIN
    NEW.record_hash := core.generate_hash(
        NEW.fee_transaction_id::TEXT || NEW.fee_reference || 
        NEW.charged_account_id::TEXT || NEW.fee_amount::TEXT || NEW.calculated_at::TEXT
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_fee_transaction_hash ON core.fee_transactions;
CREATE TRIGGER trg_fee_transaction_hash BEFORE INSERT ON core.fee_transactions
    FOR EACH ROW EXECUTE FUNCTION core.compute_fee_transaction_hash();

-- =============================================================================
-- HELPER FUNCTION: Calculate Fee
-- =============================================================================

CREATE OR REPLACE FUNCTION core.calculate_fee(
    p_schedule_id UUID,
    p_base_amount NUMERIC,
    p_currency VARCHAR(3)
)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_schedule RECORD;
    v_fee_amount NUMERIC := 0;
    v_tier JSONB;
BEGIN
    SELECT * INTO v_schedule FROM core.fee_schedules 
    WHERE schedule_id = p_schedule_id AND status = 'ACTIVE';
    
    IF v_schedule IS NULL THEN
        RETURN 0;
    END IF;
    
    CASE v_schedule.calculation_method
        WHEN 'FLAT' THEN
            v_fee_amount := COALESCE(v_schedule.flat_fee_amount, 0);
        WHEN 'PERCENTAGE' THEN
            v_fee_amount := p_base_amount * COALESCE(v_schedule.percentage_rate, 0);
        WHEN 'TIERED' THEN
            FOR v_tier IN SELECT * FROM jsonb_array_elements(v_schedule.tier_configuration)
            LOOP
                IF p_base_amount >= (v_tier->>'from')::NUMERIC 
                   AND p_base_amount <= COALESCE((v_tier->>'to')::NUMERIC, 999999999999) THEN
                    IF v_tier ? 'flat_fee' THEN
                        v_fee_amount := (v_tier->>'flat_fee')::NUMERIC;
                    ELSE
                        v_fee_amount := p_base_amount * COALESCE((v_tier->>'rate')::NUMERIC, 0);
                    END IF;
                    EXIT;
                END IF;
            END LOOP;
        WHEN 'HYBRID' THEN
            v_fee_amount := COALESCE(v_schedule.flat_fee_amount, 0) + 
                           (p_base_amount * COALESCE(v_schedule.percentage_rate, 0));
    END CASE;
    
    -- Apply min/max constraints
    v_fee_amount := GREATEST(v_fee_amount, COALESCE(v_schedule.minimum_fee, 0));
    IF v_schedule.maximum_fee IS NOT NULL THEN
        v_fee_amount := LEAST(v_fee_amount, v_schedule.maximum_fee);
    END IF;
    
    RETURN ROUND(v_fee_amount, 8);
END;
$$;

-- =============================================================================
-- RLS POLICIES
-- =============================================================================

DO $$
BEGIN
    ALTER TABLE core.fee_schedules ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE core.fee_transactions ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

CREATE POLICY fee_schedules_kernel ON core.fee_schedules FOR ALL TO ussd_kernel_role USING (true);
CREATE POLICY fee_transactions_kernel ON core.fee_transactions FOR ALL TO ussd_kernel_role USING (true);

-- =============================================================================
-- INITIAL DATA
-- =============================================================================

INSERT INTO core.fee_schedules (schedule_code, schedule_name, fee_type, fee_category, calculation_method, flat_fee_amount, percentage_rate, minimum_fee, maximum_fee, status, revenue_account_code) VALUES
('TXN-FEE-001', 'Standard Transaction Fee', 'TRANSACTION', 'PROCESSING', 'HYBRID', 0.50, 0.005, 0.50, 10.00, 'ACTIVE', '4200'),
('MONTHLY-FEE-001', 'Monthly Account Fee', 'MONTHLY', 'MAINTENANCE', 'FLAT', 5.00, NULL, 5.00, 5.00, 'ACTIVE', '4200'),
('FX-FEE-001', 'Foreign Exchange Fee', 'TRANSACTION', 'FX', 'PERCENTAGE', NULL, 0.025, 1.00, 50.00, 'ACTIVE', '4200');

-- =============================================================================
-- END OF FILE
-- =============================================================================

COMMIT;
