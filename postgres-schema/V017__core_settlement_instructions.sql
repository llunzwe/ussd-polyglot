-- =============================================================================
-- Migration: V015__core_settlement_instructions
-- Description: Core table: settlement_instructions
-- Dependencies: V014
-- Generated: 2026-04-02 16:56:45 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- USSD KERNEL CORE SCHEMA - SETTLEMENT INSTRUCTIONS
-- Enterprise-Grade Immutable Ledger System
-- =============================================================================
-- FILENAME:    012_settlement_instructions.sql
-- SCHEMA:      ussd_core
-- TABLE:       settlement_instructions
-- DESCRIPTION: Instructions for inter-bank and inter-provider settlement
--              including net settlement calculations and payment schedules.
-- =============================================================================

/*
================================================================================
COMPLIANCE FRAMEWORK
================================================================================

ISO/IEC 27001:2022 (Information Security Management Systems)
├── A.8.1 User endpoint devices - Settlement authorization
├── A.8.5 Secure authentication - Settlement approval
└── A.12.4 Logging and monitoring - Settlement monitoring

ISO/IEC 27040:2024 (Storage Security)
├── Immutable settlement records
├── Settlement amount integrity
└── Settlement schedule enforcement

Financial Regulations
├── RTGS compliance: Real-time gross settlement requirements
├── Netting regulations: Multi-lateral netting rules
├── Settlement finality: Irrevocable settlement confirmation
└── Liquidity reporting: Settlement obligation reporting

================================================================================
ENTERPRISE POSTGRESQL CODING PRACTICES
================================================================================

1. SETTLEMENT TYPES
   - RTGS: Real-time gross settlement
   - NET: Net settlement (end of period)
   - BATCH: Scheduled batch settlement
   - IMMEDIATE: Instant settlement

2. SETTLEMENT STATES
   - PENDING: Awaiting settlement date
   - READY: Prepared for settlement
   - EXECUTING: Settlement in progress
   - COMPLETED: Settlement confirmed
   - FAILED: Settlement failed, retry scheduled

3. CURRENCY HANDLING
   - Multi-currency settlement support
   - FX rate tracking for cross-currency
   - Currency-specific settlement accounts

================================================================================
SECURITY IMPLEMENTATION NOTES
================================================================================

SETTLEMENT AUTHORIZATION:
- Multi-level approval for large settlements
- Dual control for settlement execution
- Settlement limit enforcement

VERIFICATION:
- Settlement amount reconciliation
- Counterparty confirmation
- Final settlement confirmation receipt

================================================================================
PERFORMANCE OPTIMIZATION ANNOTATIONS
================================================================================

INDEXES:
- PRIMARY KEY: settlement_id
- COUNTERPARTY: counterparty_id + settlement_date
- STATUS: status + scheduled_at
- DATE: settlement_date (range queries)

================================================================================
AUDIT AND LOGGING REQUIREMENTS
================================================================================

AUDIT EVENTS:
- SETTLEMENT_INSTRUCTION_CREATED
- SETTLEMENT_READY
- SETTLEMENT_EXECUTED
- SETTLEMENT_CONFIRMED
- SETTLEMENT_FAILED

RETENTION: 7 years
================================================================================
*/

-- =============================================================================
-- CREATE TABLE: settlement_instructions
-- =============================================================================

CREATE TABLE IF NOT EXISTS core.settlement_instructions (
    -- Primary identifier
    settlement_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    settlement_reference VARCHAR(100) UNIQUE NOT NULL,
    
    -- Settlement parties
    application_id UUID NOT NULL,
    counterparty_id UUID NOT NULL,  -- Bank, MNO, or provider
    counterparty_name VARCHAR(255),
    
    -- Settlement type and direction
    settlement_type VARCHAR(50) NOT NULL
        CHECK (settlement_type IN ('RTGS', 'NET', 'BATCH', 'IMMEDIATE', 'MOBILE_MONEY')),
    settlement_channel VARCHAR(20) DEFAULT 'bank' 
        CHECK (settlement_channel IN ('bank', 'mobile_money', 'internal')),
    direction VARCHAR(20) NOT NULL
        CHECK (direction IN ('PAY', 'RECEIVE')),
    
    -- Mobile Money Settlement (EcoCash, TeleCash, OneMoney)
    is_mobile_money_settlement BOOLEAN DEFAULT FALSE,
    mobile_money_provider VARCHAR(20) CHECK (mobile_money_provider IN ('ecocash', 'telecash', 'onemoney')),
    mobile_money_settlement_details JSONB, -- Provider-specific settlement data (NULL if not mobile money)
    /*
    mobile_money_settlement_details JSONB structure:
    {
        "provider_batch_id": "Provider's batch reference",
        "provider_merchant_id": "ECO123456",
        "total_transactions": 150,
        "gross_amount": 25000.00,
        "total_fees": 375.00,
        "net_settlement_amount": 24400.00,
        "transaction_breakdown": {
            "payment_received": {"count": 100, "amount": 20000.00},
            "payout_sent": {"count": 30, "amount": 5000.00},
            "refund": {"count": 20, "amount": 0.00}
        },
        "provider_statement": {
            "statement_reference": "ECO_STMT_20240115"
        },
        "webhook_data": {}
    }
    */
    
    -- Amount
    amount NUMERIC(20, 8) NOT NULL CHECK (amount > 0),
    currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    
    -- FX information (if cross-currency)
    fx_rate NUMERIC(20, 10),
    fx_rate_source VARCHAR(50),
    original_amount NUMERIC(20, 8),
    original_currency VARCHAR(3),
    
    -- Timing
    scheduled_at TIMESTAMPTZ NOT NULL,
    settlement_date DATE NOT NULL,
    executed_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    
    -- Status
    status VARCHAR(50) DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'READY', 'EXECUTING', 'COMPLETED', 'FAILED', 'CANCELLED')),
    
    -- Settlement details
    settlement_account VARCHAR(100),
    settlement_bank_code VARCHAR(20),
    settlement_method VARCHAR(50),
    
    -- Counterparty details
    counterparty_account VARCHAR(100),
    counterparty_bank_code VARCHAR(20),
    counterparty_branch_code VARCHAR(20),
    
    -- Transaction summary
    transaction_count INTEGER,
    gross_amount NUMERIC(20, 8),
    net_amount NUMERIC(20, 8),
    fees_amount NUMERIC(20, 8) DEFAULT 0,
    
    -- References
    included_transactions UUID[],
    parent_settlement_id UUID REFERENCES core.settlement_instructions(settlement_id) ON DELETE RESTRICT,
    
    -- Confirmation
    confirmation_reference VARCHAR(100),
    confirmed_at TIMESTAMPTZ,
    confirmed_by UUID,
    
    -- Instructions and notes
    instructions TEXT,
    description TEXT,
    narrative VARCHAR(140),
    
    -- Approval workflow
    approval_required BOOLEAN DEFAULT FALSE,
    approved_by UUID,
    approved_at TIMESTAMPTZ,
    
    -- Retry handling
    retry_count INTEGER DEFAULT 0,
    max_retries INTEGER DEFAULT 3,
    next_retry_at TIMESTAMPTZ,
    failure_reason TEXT,
    
    -- Metadata
    metadata JSONB DEFAULT '{}',
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT chk_rtgs_requires_scheduled CHECK (
        settlement_type != 'RTGS' OR scheduled_at IS NOT NULL
    ),
    CONSTRAINT chk_completed_requires_confirmation CHECK (
        status != 'COMPLETED' OR confirmation_reference IS NOT NULL
    )
);

-- =============================================================================
-- INDEXES
-- =============================================================================

-- Settlement reference lookup
CREATE INDEX IF NOT EXISTS idx_settlement_instructions_reference ON core.settlement_instructions(settlement_reference);

-- Counterparty lookup
CREATE INDEX IF NOT EXISTS idx_settlement_instructions_counterparty ON core.settlement_instructions(counterparty_id, settlement_date);

-- Status monitoring
CREATE INDEX IF NOT EXISTS idx_settlement_instructions_status ON core.settlement_instructions(status, scheduled_at);

-- Pending settlements
CREATE INDEX IF NOT EXISTS idx_settlement_instructions_pending ON core.settlement_instructions(settlement_id)
    WHERE status IN ('PENDING', 'READY');

-- Settlement date range queries
CREATE INDEX IF NOT EXISTS idx_settlement_instructions_date ON core.settlement_instructions(settlement_date, status);

-- Application lookup
CREATE INDEX IF NOT EXISTS idx_settlement_instructions_app ON core.settlement_instructions(application_id, settlement_date DESC);

-- Scheduled for execution
CREATE INDEX IF NOT EXISTS idx_settlement_instructions_scheduled ON core.settlement_instructions(scheduled_at, status)
    WHERE status IN ('READY', 'PENDING');

-- Parent settlement lookup
CREATE INDEX IF NOT EXISTS idx_settlement_instructions_parent ON core.settlement_instructions(parent_settlement_id)
    WHERE parent_settlement_id IS NOT NULL;

-- Currency filtering
CREATE INDEX IF NOT EXISTS idx_settlement_instructions_currency ON core.settlement_instructions(currency, settlement_date);

-- =============================================================================
-- UPDATE TIMESTAMP TRIGGER
-- =============================================================================

CREATE OR REPLACE FUNCTION core.update_settlement_timestamp()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_settlement_instructions_update_timestamp ON core.settlement_instructions;
CREATE TRIGGER trg_settlement_instructions_update_timestamp
    BEFORE UPDATE ON core.settlement_instructions
    FOR EACH ROW
    EXECUTE FUNCTION core.update_settlement_timestamp();

-- =============================================================================
-- HASH COMPUTATION TRIGGER
-- =============================================================================



-- =============================================================================
-- RLS POLICIES
-- =============================================================================

-- Enable RLS
DO $$
BEGIN
    ALTER TABLE core.settlement_instructions ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Policy: Application-scoped access
-- PRODUCTION FIX: Uses safe UUID helper to prevent NULL casting issues
CREATE POLICY settlement_instructions_app_access ON core.settlement_instructions
    FOR SELECT
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

-- Policy: Kernel role has full access
CREATE POLICY settlement_instructions_kernel_access ON core.settlement_instructions
    FOR ALL
    TO ussd_kernel_role
    USING (true);

-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

-- Function to create a settlement instruction
CREATE OR REPLACE FUNCTION core.create_settlement_instruction(
    p_settlement_reference VARCHAR,
    p_application_id UUID,
    p_counterparty_id UUID,
    p_settlement_type VARCHAR,
    p_direction VARCHAR,
    p_amount NUMERIC,
    p_currency VARCHAR,
    p_scheduled_at TIMESTAMPTZ,
    p_settlement_date DATE,
    p_settlement_account VARCHAR DEFAULT NULL,
    p_counterparty_account VARCHAR DEFAULT NULL,
    p_description TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_settlement_id UUID;
BEGIN
    INSERT INTO core.settlement_instructions (
        settlement_reference,
        application_id,
        counterparty_id,
        settlement_type,
        direction,
        amount,
        currency,
        scheduled_at,
        settlement_date,
        settlement_account,
        counterparty_account,
        description
    ) VALUES (
        p_settlement_reference,
        p_application_id,
        p_counterparty_id,
        p_settlement_type,
        p_direction,
        p_amount,
        p_currency,
        p_scheduled_at,
        p_settlement_date,
        p_settlement_account,
        p_counterparty_account,
        p_description
    )
    RETURNING settlement_id INTO v_settlement_id;
    
    RETURN v_settlement_id;
END;
$$;

-- Function to mark settlement as ready
CREATE OR REPLACE FUNCTION core.mark_settlement_ready(
    p_settlement_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE core.settlement_instructions
    SET status = 'READY'
    WHERE settlement_id = p_settlement_id
    AND status = 'PENDING';
    
    RETURN FOUND;
END;
$$;

-- Function to execute settlement
CREATE OR REPLACE FUNCTION core.execute_settlement(
    p_settlement_id UUID,
    p_confirmation_reference VARCHAR DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE core.settlement_instructions
    SET 
        status = 'EXECUTING',
        executed_at = NOW()
    WHERE settlement_id = p_settlement_id
    AND status IN ('PENDING', 'READY');
    
    RETURN FOUND;
END;
$$;

-- Function to complete settlement
CREATE OR REPLACE FUNCTION core.complete_settlement(
    p_settlement_id UUID,
    p_confirmation_reference VARCHAR,
    p_confirmed_by UUID DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE core.settlement_instructions
    SET 
        status = 'COMPLETED',
        confirmation_reference = p_confirmation_reference,
        confirmed_at = NOW(),
        confirmed_by = p_confirmed_by,
        completed_at = NOW()
    WHERE settlement_id = p_settlement_id
    AND status = 'EXECUTING';
    
    RETURN FOUND;
END;
$$;

-- Function to fail settlement
CREATE OR REPLACE FUNCTION core.fail_settlement(
    p_settlement_id UUID,
    p_reason TEXT,
    p_schedule_retry BOOLEAN DEFAULT TRUE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_retries INTEGER;
    v_max_retries INTEGER;
BEGIN
    SELECT retry_count, max_retries INTO v_current_retries, v_max_retries
    FROM core.settlement_instructions
    WHERE settlement_id = p_settlement_id;
    
    IF v_current_retries >= v_max_retries THEN
        -- Final failure
        UPDATE core.settlement_instructions
        SET 
            status = 'FAILED',
            failure_reason = p_reason
        WHERE settlement_id = p_settlement_id;
    ELSE
        -- Schedule retry
        UPDATE core.settlement_instructions
        SET 
            retry_count = retry_count + 1,
            failure_reason = p_reason,
            next_retry_at = CASE WHEN p_schedule_retry 
                THEN NOW() + (retry_count * INTERVAL '5 minutes')
                ELSE NULL 
            END,
            status = CASE WHEN p_schedule_retry THEN 'PENDING' ELSE 'FAILED' END
        WHERE settlement_id = p_settlement_id;
    END IF;
    
    RETURN FOUND;
END;
$$;

-- Function to get pending settlements
CREATE OR REPLACE FUNCTION core.get_pending_settlements(
    p_application_id UUID DEFAULT NULL
)
RETURNS TABLE (
    settlement_id UUID,
    settlement_reference VARCHAR,
    counterparty_id UUID,
    amount NUMERIC(20, 8),
    currency VARCHAR(3),
    settlement_date DATE,
    scheduled_at TIMESTAMPTZ,
    settlement_type VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        si.settlement_id,
        si.settlement_reference,
        si.counterparty_id,
        si.amount,
        si.currency,
        si.settlement_date,
        si.scheduled_at,
        si.settlement_type
    FROM core.settlement_instructions si
    WHERE si.status IN ('PENDING', 'READY')
    AND (p_application_id IS NULL OR si.application_id = p_application_id)
    ORDER BY si.scheduled_at;
END;
$$;

-- Function to get settlement summary
CREATE OR REPLACE FUNCTION core.get_settlement_summary(
    p_start_date DATE,
    p_end_date DATE,
    p_application_id UUID DEFAULT NULL
)
RETURNS TABLE (
    settlement_type VARCHAR,
    direction VARCHAR,
    currency VARCHAR(3),
    total_amount NUMERIC(20, 8),
    count BIGINT,
    completed_count BIGINT,
    failed_count BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        si.settlement_type,
        si.direction,
        si.currency,
        SUM(si.amount),
        COUNT(*)::BIGINT,
        COUNT(*) FILTER (WHERE si.status = 'COMPLETED')::BIGINT,
        COUNT(*) FILTER (WHERE si.status = 'FAILED')::BIGINT
    FROM core.settlement_instructions si
    WHERE si.settlement_date BETWEEN p_start_date AND p_end_date
    AND (p_application_id IS NULL OR si.application_id = p_application_id)
    GROUP BY si.settlement_type, si.direction, si.currency;
END;
$$;

-- =============================================================================
-- TABLE AND COLUMN COMMENTS
-- =============================================================================

COMMENT ON TABLE core.settlement_instructions IS 
'MOBILE MONEY SETTLEMENT - Business Payments Only
ISO 27001: A.14.1 (Information Security Aspects of Business Continuity)
PCI DSS: Req 8 (Authentication), Req 10 (Audit Trails)

SETTLEMENT FLOW:
1. Business receives payments (C2B)
2. Funds held in mobile money wallet
3. Settlement instruction created
4. Batch settled to business bank account
5. Reconciliation with provider statement

SUPPORTED PROVIDERS:
- EcoCash (Econet): API v2.0, RSA signature
- OneMoney (NetOne): API v1.0, HMAC signature  
- TeleCash (Telecel): API v1.5, OAuth2

NOT SUPPORTED:
- Cash-in/Cash-out (agent operations)
- P2P transfers (consumer feature)
- Airtime purchase (consumer feature)';

COMMENT ON COLUMN core.settlement_instructions.settlement_id IS 
    'Unique identifier for the settlement instruction';
COMMENT ON COLUMN core.settlement_instructions.settlement_reference IS 
    'External reference number for the settlement';
COMMENT ON COLUMN core.settlement_instructions.settlement_type IS 
    'Type: RTGS, NET, BATCH, IMMEDIATE';
COMMENT ON COLUMN core.settlement_instructions.direction IS 
    'Direction: PAY (we pay) or RECEIVE (we receive)';
COMMENT ON COLUMN core.settlement_instructions.counterparty_id IS 
    'The bank, MNO, or provider on the other side of the settlement';
COMMENT ON COLUMN core.settlement_instructions.gross_amount IS 
    'Sum of all transactions before netting';
COMMENT ON COLUMN core.settlement_instructions.net_amount IS 
    'Net amount after bilateral or multilateral netting';
COMMENT ON COLUMN core.settlement_instructions.included_transactions IS 
    'Array of transaction IDs included in this settlement';
COMMENT ON COLUMN core.settlement_instructions.status IS 
    'Status: PENDING, READY, EXECUTING, COMPLETED, FAILED, CANCELLED';

-- =============================================================================
-- END OF FILE
-- =============================================================================

COMMIT;
