-- =============================================================================
-- Migration: V066__financial_commission_commission_tables
-- Description: Financial commission: commission_tables
-- Dependencies: V065
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- USSD KERNEL FINANCIAL SCHEMA - Commission Management
-- Enterprise-Grade Immutable Ledger System
-- =============================================================================
-- FILENAME:    000_commission_tables.sql
-- SCHEMA:      core
-- TABLES:      commission_schedules, commission_transactions
-- DESCRIPTION: Commission structure and payout tracking
-- 
-- COMPLIANCE:  IFRS 15 (Revenue Recognition)
--              GAAP Expense Recognition
-- =============================================================================

-- =============================================================================
-- TABLE: commission_schedules - Commission Structure
-- =============================================================================

CREATE TABLE IF NOT EXISTS core.commission_schedules (
    schedule_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    schedule_code VARCHAR(50) UNIQUE NOT NULL,
    schedule_name VARCHAR(100) NOT NULL,
    
    commission_type VARCHAR(50) NOT NULL 
        CHECK (commission_type IN ('AGENT', 'REFERRAL', 'PARTNER', 'AFFILIATE', 'MERCHANT', 'SUB_AGENT')),
    
    calculation_method VARCHAR(50) NOT NULL 
        CHECK (calculation_method IN ('FLAT', 'PERCENTAGE', 'TIERED', 'VOLUME', 'HYBRID')),
    
    flat_commission NUMERIC(20,8),
    percentage_rate NUMERIC(10,6),
    minimum_commission NUMERIC(20,8) DEFAULT 0,
    maximum_commission NUMERIC(20,8),
    
    tier_configuration JSONB,
    
    -- Mobile Money Provider Specific Commission (NULL = use default/generic commission)
    -- NOTE: Business APIs only support merchant payments, not agent operations
    provider_specific_commission JSONB,
    /*
    provider_specific_commission JSONB structure (Business Merchant APIs Only):
    {
        "provider": "ecocash", -- ecocash|telecash|onemoney
        "merchant_tiers": [
            {
                "tier_name": "standard_merchant",
                "qualification": {"min_transactions": 100, "min_volume": 10000},
                "transaction_types": {
                    "merchant_payment_received": {"type": "percentage", "rate": 1.5},
                    "payout_sent": {"type": "fixed", "amount": 0.50}
                }
            },
            {
                "tier_name": "premium_merchant",
                "qualification": {"min_transactions": 500, "min_volume": 50000},
                "transaction_types": {
                    "merchant_payment_received": {"type": "percentage", "rate": 1.0},
                    "payout_sent": {"type": "fixed", "amount": 0.25}
                }
            }
        ],
        "platform_fees": {
            "merchant_payment_received": 1.5,
            "payout_sent": 0.5,
            "refund": 0.0
        },
        "monthly_targets": {
            "target_transactions": 100,
            "target_volume": 10000,
            "bonus_amount": 100.00
        }
    }
    -- NOTE: cash_in, cash_out, peer_transfer are AGENT operations not available via business APIs
    -- This schema is for BUSINESS receiving payments, not for mobile money agents
    */
    
    applicable_transaction_types UUID[],
    applicable_currencies VARCHAR(3)[],
    applicable_providers VARCHAR(20)[], -- For provider-specific commission plans
    
    allow_hierarchy_override BOOLEAN DEFAULT FALSE,
    parent_commission_share NUMERIC(5,4) DEFAULT 0, -- Share passed to parent agent
    
    valid_from DATE NOT NULL DEFAULT CURRENT_DATE,
    valid_until DATE,
    
    status VARCHAR(20) DEFAULT 'ACTIVE' CHECK (status IN ('DRAFT', 'ACTIVE', 'DEPRECATED')),
    
    expense_account_code VARCHAR(50) REFERENCES core.chart_of_accounts(coa_code),
    payable_account_code VARCHAR(50) REFERENCES core.chart_of_accounts(coa_code),
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    record_hash VARCHAR(64) NOT NULL DEFAULT 'PENDING'
);

CREATE INDEX IF NOT EXISTS idx_commission_schedules_type ON core.commission_schedules(commission_type, status);
CREATE INDEX IF NOT EXISTS idx_commission_schedules_active ON core.commission_schedules(schedule_id) WHERE status = 'ACTIVE';

-- =============================================================================
-- TABLE: commission_transactions - Commission Payout Records
-- =============================================================================

CREATE TABLE IF NOT EXISTS core.commission_transactions (
    commission_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    commission_reference VARCHAR(100) UNIQUE NOT NULL,
    
    source_transaction_id BIGINT,  -- References core.transaction_log (composite PK prevents direct FK)
    schedule_id UUID REFERENCES core.commission_schedules(schedule_id),
    
    agent_account_id UUID REFERENCES core.account_registry(account_id),
    parent_agent_id UUID REFERENCES core.account_registry(account_id),
    
    base_amount NUMERIC(20,8) NOT NULL,
    commission_amount NUMERIC(20,8) NOT NULL,
    commission_currency VARCHAR(3) NOT NULL,
    commission_rate NUMERIC(10,6),
    
    agent_share_amount NUMERIC(20,8) NOT NULL,
    parent_share_amount NUMERIC(20,8) DEFAULT 0,
    
    commission_status VARCHAR(20) DEFAULT 'PENDING' 
        CHECK (commission_status IN ('PENDING', 'APPROVED', 'PAID', 'HELD', 'REVERSED')),
    
    paid_at TIMESTAMPTZ,
    paid_by UUID,
    payment_reference VARCHAR(100),
    payment_transaction_id BIGINT,
    
    held_until TIMESTAMPTZ,
    hold_reason TEXT,
    released_at TIMESTAMPTZ,
    
    posted_to_gl BOOLEAN DEFAULT FALSE,
    
    calculated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    record_hash VARCHAR(64) NOT NULL DEFAULT 'PENDING'
);

CREATE INDEX IF NOT EXISTS idx_commission_agent ON core.commission_transactions(agent_account_id, commission_status);
CREATE INDEX IF NOT EXISTS idx_commission_source ON core.commission_transactions(source_transaction_id);
CREATE INDEX IF NOT EXISTS idx_commission_status ON core.commission_transactions(commission_status, held_until) WHERE commission_status = 'HELD';

-- =============================================================================
-- HELPER FUNCTION: Calculate Commission
-- =============================================================================

CREATE OR REPLACE FUNCTION core.calculate_commission(
    p_schedule_id UUID,
    p_base_amount NUMERIC,
    p_agent_id UUID
)
RETURNS TABLE (
    total_commission NUMERIC,
    agent_share NUMERIC,
    parent_share NUMERIC,
    parent_agent_id UUID
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_schedule RECORD;
    v_parent_agent UUID;
    v_commission NUMERIC := 0;
    v_agent_share NUMERIC;
    v_parent_share NUMERIC;
    v_tier JSONB;
BEGIN
    -- Get parent agent if exists
    SELECT ar.parent_account_id INTO v_parent_agent
    FROM core.agent_relationships ar
    WHERE ar.from_account_id = p_agent_id
      AND ar.relationship_type = 'AGENT'
      AND ar.status = 'active';
    
    SELECT * INTO v_schedule FROM core.commission_schedules 
    WHERE schedule_id = p_schedule_id AND status = 'ACTIVE';
    
    IF v_schedule IS NULL THEN
        RETURN QUERY SELECT 0::NUMERIC, 0::NUMERIC, 0::NUMERIC, NULL::UUID;
        RETURN;
    END IF;
    
    -- Calculate commission
    CASE v_schedule.calculation_method
        WHEN 'FLAT' THEN
            v_commission := COALESCE(v_schedule.flat_commission, 0);
        WHEN 'PERCENTAGE' THEN
            v_commission := p_base_amount * COALESCE(v_schedule.percentage_rate, 0);
        WHEN 'TIERED' THEN
            FOR v_tier IN SELECT * FROM jsonb_array_elements(v_schedule.tier_configuration)
            LOOP
                IF p_base_amount >= (v_tier->>'min_volume')::NUMERIC THEN
                    v_commission := p_base_amount * (v_tier->>'rate')::NUMERIC;
                END IF;
            END LOOP;
    END CASE;
    
    -- Apply constraints
    v_commission := GREATEST(v_commission, COALESCE(v_schedule.minimum_commission, 0));
    IF v_schedule.maximum_commission IS NOT NULL THEN
        v_commission := LEAST(v_commission, v_schedule.maximum_commission);
    END IF;
    
    -- Calculate split
    IF v_parent_agent IS NOT NULL AND v_schedule.allow_hierarchy_override THEN
        v_parent_share := v_commission * COALESCE(v_schedule.parent_commission_share, 0);
        v_agent_share := v_commission - v_parent_share;
    ELSE
        v_agent_share := v_commission;
        v_parent_share := 0;
    END IF;
    
    RETURN QUERY SELECT 
        ROUND(v_commission, 8),
        ROUND(v_agent_share, 8),
        ROUND(v_parent_share, 8),
        v_parent_agent;
END;
$$;

-- =============================================================================
-- RLS
-- =============================================================================

DO $$
BEGIN
    ALTER TABLE core.commission_schedules ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE core.commission_transactions ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

CREATE POLICY commission_schedules_kernel ON core.commission_schedules FOR ALL TO ussd_kernel_role USING (true);
CREATE POLICY commission_transactions_kernel ON core.commission_transactions FOR ALL TO ussd_kernel_role USING (true);

-- =============================================================================
-- END OF FILE
-- =============================================================================

COMMIT;
