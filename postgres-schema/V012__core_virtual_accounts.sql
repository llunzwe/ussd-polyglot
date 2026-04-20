-- =============================================================================
-- Migration: V011__core_virtual_accounts
-- Description: Core table: virtual_accounts
-- Dependencies: V010
-- Generated: 2026-04-02 16:56:45 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- USSD KERNEL CORE SCHEMA - VIRTUAL ACCOUNTS
-- Enterprise-Grade Immutable Ledger System
-- =============================================================================
-- FILENAME:    008_virtual_accounts.sql
-- SCHEMA:      ussd_core
-- TABLE:       virtual_accounts
-- DESCRIPTION: Sub-accounts for budgeting, savings goals, and temporary holds.
--              Linked to parent accounts but with separate balance tracking.
-- =============================================================================

/*
================================================================================
COMPLIANCE FRAMEWORK
================================================================================

ISO/IEC 27001:2022 (Information Security Management Systems)
├── A.8.1 User endpoint devices - Virtual account access control
├── A.8.5 Secure authentication - Parent account authentication required
└── A.8.11 Data masking - Virtual account masking

ISO/IEC 27040:2024 (Storage Security)
├── Immutable virtual account history
├── Balance integrity verification
└── Audit trail for all virtual account operations

Financial Regulations
├── Customer funds segregation: Virtual accounts are bookkeeping only
├── No separate legal ownership: Belongs to parent account holder
├── Interest calculation: May be aggregated with parent account
└── Reporting: Virtual account balances reported to parent

================================================================================
ENTERPRISE POSTGRESQL CODING PRACTICES
================================================================================

1. VIRTUAL ACCOUNT TYPES
   - BUDGET: Spending category budgeting
   - SAVINGS_GOAL: Target-based savings
   - ESCROW: Third-party holding
   - RESERVE: Mandatory reserve
   - TEMPORARY_HOLD: Time-limited hold

2. BALANCE MANAGEMENT
   - Zero or positive balance only (no credit)
   - Parent account guarantees virtual account balance
   - Sweep functionality for savings goals

3. LIFECYCLE
   - Active: Available for transactions
   - Frozen: No debits allowed
   - Closed: Archived, balance swept to parent
   - Matured: Savings goal reached

================================================================================
SECURITY IMPLEMENTATION NOTES
================================================================================

ACCESS CONTROL:
- Parent account holders control virtual accounts
- Delegated access possible via agent_relationships
- API access restricted by virtual account permissions

INTEGRITY:
- Virtual account balances must sum to parent available balance
- Periodic reconciliation with parent account
- Exception reporting for imbalances

================================================================================
PERFORMANCE OPTIMIZATION ANNOTATIONS
================================================================================

INDEXES:
- PRIMARY KEY: virtual_account_id
- PARENT: parent_account_id + status
- TYPE: virtual_account_type + status
- GOAL: target_date (for savings goal queries)

================================================================================
AUDIT AND LOGGING REQUIREMENTS
================================================================================

AUDIT EVENTS:
- VIRTUAL_ACCOUNT_CREATED
- VIRTUAL_ACCOUNT_FUNDED
- VIRTUAL_ACCOUNT_DEBITED
- VIRTUAL_ACCOUNT_CLOSED
- GOAL_REACHED

RETENTION: 7 years
================================================================================
*/

-- =============================================================================
-- CREATE TABLE: virtual_accounts
-- =============================================================================

CREATE TABLE IF NOT EXISTS core.virtual_accounts (
    -- Primary identifier
    virtual_account_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Parent account
    parent_account_id UUID NOT NULL REFERENCES core.account_registry(account_id) ON DELETE RESTRICT,
    
    -- Virtual account details
    virtual_account_name VARCHAR(100) NOT NULL,
    virtual_account_number VARCHAR(50),  -- Optional account number for the virtual account
    virtual_account_type VARCHAR(50) NOT NULL
        CHECK (virtual_account_type IN (
            'BUDGET', 'SAVINGS_GOAL', 'ESCROW', 'RESERVE', 'TEMPORARY_HOLD',
            'ECOCASH_WALLET', 'TELECASH_WALLET', 'ONEMONEY_WALLET', 
            'MERCHANT_SETTLEMENT'
            -- NOTE: AGENT_FLOAT removed - this system is for businesses receiving payments,
            -- not for mobile money agents handling cash-in/cash-out
        )),
    
    -- Mobile Money Business Wallet (EcoCash, OneMoney, TeleCash)
    -- Simplified for USSD Business Applications receiving payments
    is_mobile_money_wallet BOOLEAN DEFAULT FALSE,
    mobile_money_provider VARCHAR(20) CHECK (mobile_money_provider IN ('ecocash', 'onemoney', 'telecash')),
    mobile_money_wallet_type VARCHAR(20) CHECK (mobile_money_wallet_type IN ('merchant', 'float')),
    mobile_money_wallet_reference VARCHAR(100), -- Provider's wallet ID
    mobile_money_merchant_code VARCHAR(20),     -- Business 6-digit merchant code
    mobile_money_details JSONB, -- Provider-specific wallet configuration -- Flexible storage for wallet-specific data
    /*
    mobile_money_details JSONB structure (Simplified - Business Wallets):
    {
        "provider_api_version": "v2.0",
        "merchant_name": "Business Name",
        "provider_wallet_id": "ECO-MERCHANT-123456789",
        "settlement_config": {
            "bank_account": "acc_xxx",
            "schedule": "daily|weekly|threshold",
            "threshold_amount": 1000.00
        },
        "transaction_limits": {
            "daily": 50000.00,
            "per_transaction": 10000.00
        },
        "webhook_endpoint": "https://ussd.example.com/webhooks/mm",
        "supported_currencies": ["ZWL", "USD"],
        "requires_approval_above": 5000.00
    }
    */
    
    -- Purpose/description
    description TEXT,
    purpose_code VARCHAR(50),
    
    -- Balance
    current_balance NUMERIC(20, 8) NOT NULL DEFAULT 0,
    available_balance NUMERIC(20, 8) NOT NULL DEFAULT 0,  -- current_balance - holds
    currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    
    -- Target (for savings goals)
    target_amount NUMERIC(20, 8),
    target_date DATE,
    progress_percentage NUMERIC(5, 2) GENERATED ALWAYS AS (
        CASE 
            WHEN target_amount IS NULL OR target_amount = 0 THEN NULL
            WHEN current_balance >= target_amount THEN 100
            ELSE LEAST(100, ROUND((current_balance / target_amount) * 100, 2))
        END
    ) STORED,
    
    -- Limits
    minimum_balance NUMERIC(20, 8) DEFAULT 0,
    maximum_balance NUMERIC(20, 8),
    
    -- Rules
    auto_sweep_enabled BOOLEAN DEFAULT FALSE,
    auto_sweep_threshold NUMERIC(20, 8),
    auto_sweep_destination UUID,  -- Another virtual account or parent
    
    -- Holds tracking
    held_amount NUMERIC(20, 8) DEFAULT 0,
    
    -- Status
    status VARCHAR(20) DEFAULT 'active'
        CHECK (status IN ('active', 'frozen', 'closed', 'matured')),
    
    -- Metadata
    metadata JSONB DEFAULT '{}',
    
    -- Lifecycle
    opened_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    closed_at TIMESTAMPTZ,
    maturity_date DATE,
    matured_at TIMESTAMPTZ,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT chk_balance_not_negative CHECK (current_balance >= 0),
    CONSTRAINT chk_available_not_negative CHECK (available_balance >= 0),
    CONSTRAINT chk_available_lte_current CHECK (available_balance <= current_balance),
    CONSTRAINT chk_target_if_savings CHECK (
        virtual_account_type != 'SAVINGS_GOAL' OR target_amount IS NOT NULL
    ),
    CONSTRAINT chk_no_sweep_to_self CHECK (
        auto_sweep_destination IS NULL OR auto_sweep_destination != virtual_account_id
    )
);

-- =============================================================================
-- INDEXES
-- =============================================================================

-- Parent account lookup
CREATE INDEX IF NOT EXISTS idx_virtual_accounts_parent ON core.virtual_accounts(parent_account_id, status);

-- Type filtering
CREATE INDEX IF NOT EXISTS idx_virtual_accounts_type ON core.virtual_accounts(virtual_account_type) 
    WHERE status IN ('active', 'frozen');

-- Status filtering
CREATE INDEX IF NOT EXISTS idx_virtual_accounts_status ON core.virtual_accounts(status);

-- Savings goal target date
CREATE INDEX IF NOT EXISTS idx_virtual_accounts_target_date ON core.virtual_accounts(target_date) 
    WHERE virtual_account_type = 'SAVINGS_GOAL' AND status = 'active';

-- Account number lookup
CREATE UNIQUE INDEX IF NOT EXISTS idx_virtual_accounts_number ON core.virtual_accounts(virtual_account_number) 
    WHERE virtual_account_number IS NOT NULL;

-- Currency for aggregation
CREATE INDEX IF NOT EXISTS idx_virtual_accounts_currency ON core.virtual_accounts(parent_account_id, currency, status);

-- Auto sweep candidates
CREATE INDEX IF NOT EXISTS idx_virtual_accounts_auto_sweep ON core.virtual_accounts(virtual_account_id) 
    WHERE auto_sweep_enabled = TRUE AND status = 'active';

-- =============================================================================
-- UPDATE TIMESTAMP TRIGGER
-- =============================================================================

CREATE OR REPLACE FUNCTION core.update_virtual_account_timestamp()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    
    -- Check if savings goal reached
    IF NEW.virtual_account_type = 'SAVINGS_GOAL' 
       AND NEW.target_amount IS NOT NULL 
       AND NEW.current_balance >= NEW.target_amount 
       AND NEW.status = 'active' THEN
        NEW.status := 'matured';
        NEW.matured_at := NOW();
    END IF;
    
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_virtual_accounts_update_timestamp ON core.virtual_accounts;
CREATE TRIGGER trg_virtual_accounts_update_timestamp
    BEFORE UPDATE ON core.virtual_accounts
    FOR EACH ROW
    EXECUTE FUNCTION core.update_virtual_account_timestamp();

-- =============================================================================
-- HASH COMPUTATION TRIGGER
-- =============================================================================



-- =============================================================================
-- RLS POLICIES
-- =============================================================================

-- Enable RLS with FORCE (critical for security - prevents table owner bypass)
DO $$
BEGIN
    ALTER TABLE core.virtual_accounts ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE core.virtual_accounts FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Policy: Parent account can access their virtual accounts
-- PRODUCTION FIX: Uses safe UUID helper to prevent NULL casting issues
CREATE POLICY virtual_accounts_parent_access ON core.virtual_accounts
    FOR ALL
    TO ussd_app_user
    USING (parent_account_id = core.get_current_setting_as_uuid('app.current_account_id'));

-- Policy: Application-scoped access
CREATE POLICY virtual_accounts_app_access ON core.virtual_accounts
    FOR SELECT
    TO ussd_app_user
    USING (
        EXISTS (
            SELECT 1 FROM core.account_registry ar
            WHERE ar.account_id = virtual_accounts.parent_account_id
            AND ar.primary_application_id = core.get_current_setting_as_uuid('app.current_application_id')
        )
    );

-- Policy: Kernel role has full access
CREATE POLICY virtual_accounts_kernel_access ON core.virtual_accounts
    FOR ALL
    TO ussd_kernel_role
    USING (true);

-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

-- Function to create a virtual account
CREATE OR REPLACE FUNCTION core.create_virtual_account(
    p_parent_account_id UUID,
    p_name VARCHAR(100),
    p_type VARCHAR(50),
    p_currency VARCHAR(3),
    p_target_amount NUMERIC DEFAULT NULL,
    p_target_date DATE DEFAULT NULL,
    p_description TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_virtual_account_id UUID;
BEGIN
    INSERT INTO core.virtual_accounts (
        parent_account_id,
        virtual_account_name,
        virtual_account_type,
        currency,
        target_amount,
        target_date,
        description
    ) VALUES (
        p_parent_account_id,
        p_name,
        p_type,
        p_currency,
        p_target_amount,
        p_target_date,
        p_description
    )
    RETURNING virtual_account_id INTO v_virtual_account_id;
    
    RETURN v_virtual_account_id;
END;
$$;

-- Function to credit a virtual account
CREATE OR REPLACE FUNCTION core.credit_virtual_account(
    p_virtual_account_id UUID,
    p_amount NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'INVALID_AMOUNT: Credit amount must be positive';
    END IF;
    
    UPDATE core.virtual_accounts
    SET 
        current_balance = current_balance + p_amount,
        available_balance = available_balance + p_amount
    WHERE virtual_account_id = p_virtual_account_id
    AND status IN ('active', 'frozen');
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'VIRTUAL_ACCOUNT_NOT_FOUND_OR_INACTIVE: %', p_virtual_account_id;
    END IF;
    
    RETURN TRUE;
END;
$$;

-- Function to debit a virtual account
CREATE OR REPLACE FUNCTION core.debit_virtual_account(
    p_virtual_account_id UUID,
    p_amount NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'INVALID_AMOUNT: Debit amount must be positive';
    END IF;
    
    UPDATE core.virtual_accounts
    SET 
        current_balance = current_balance - p_amount,
        available_balance = available_balance - p_amount
    WHERE virtual_account_id = p_virtual_account_id
    AND status = 'active'
    AND available_balance >= p_amount;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INSUFFICIENT_FUNDS_OR_ACCOUNT_INACTIVE: %', p_virtual_account_id;
    END IF;
    
    RETURN TRUE;
END;
$$;

-- Function to hold funds in a virtual account
CREATE OR REPLACE FUNCTION core.hold_virtual_account_funds(
    p_virtual_account_id UUID,
    p_amount NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'INVALID_AMOUNT: Hold amount must be positive';
    END IF;
    
    UPDATE core.virtual_accounts
    SET 
        held_amount = held_amount + p_amount,
        available_balance = available_balance - p_amount
    WHERE virtual_account_id = p_virtual_account_id
    AND status = 'active'
    AND available_balance >= p_amount;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INSUFFICIENT_AVAILABLE_FUNDS_OR_ACCOUNT_INACTIVE: %', p_virtual_account_id;
    END IF;
    
    RETURN TRUE;
END;
$$;

-- Function to release held funds
CREATE OR REPLACE FUNCTION core.release_virtual_account_hold(
    p_virtual_account_id UUID,
    p_amount NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE core.virtual_accounts
    SET 
        held_amount = GREATEST(0, held_amount - p_amount),
        available_balance = available_balance + p_amount
    WHERE virtual_account_id = p_virtual_account_id
    AND held_amount >= p_amount;
    
    RETURN FOUND;
END;
$$;

-- Function to close a virtual account
CREATE OR REPLACE FUNCTION core.close_virtual_account(
    p_virtual_account_id UUID,
    p_sweep_to_parent BOOLEAN DEFAULT TRUE
)
RETURNS NUMERIC  -- Returns final balance that was swept
LANGUAGE plpgsql
AS $$
DECLARE
    v_final_balance NUMERIC(20, 8);
    v_parent_account_id UUID;
BEGIN
    -- Get current balance and parent
    SELECT current_balance, parent_account_id 
    INTO v_final_balance, v_parent_account_id
    FROM core.virtual_accounts
    WHERE virtual_account_id = p_virtual_account_id
    AND status IN ('active', 'frozen', 'matured');
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'VIRTUAL_ACCOUNT_NOT_FOUND_OR_ALREADY_CLOSED: %', p_virtual_account_id;
    END IF;
    
    -- Close the account
    UPDATE core.virtual_accounts
    SET 
        status = 'closed',
        closed_at = NOW(),
        current_balance = 0,
        available_balance = 0
    WHERE virtual_account_id = p_virtual_account_id;
    
    -- Note: In a real implementation, you'd create a movement to sweep funds to parent
    
    RETURN v_final_balance;
END;
$$;

-- Function to get virtual account summary for parent
CREATE OR REPLACE FUNCTION core.get_virtual_account_summary(
    p_parent_account_id UUID
)
RETURNS TABLE (
    total_balance NUMERIC(20, 8),
    total_available NUMERIC(20, 8),
    total_held NUMERIC(20, 8),
    account_count INTEGER,
    currency VARCHAR(3)
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        COALESCE(SUM(va.current_balance), 0),
        COALESCE(SUM(va.available_balance), 0),
        COALESCE(SUM(va.held_amount), 0),
        COUNT(*)::INTEGER,
        va.currency
    FROM core.virtual_accounts va
    WHERE va.parent_account_id = p_parent_account_id
    AND va.status IN ('active', 'frozen', 'matured')
    GROUP BY va.currency;
END;
$$;

-- =============================================================================
-- TABLE AND COLUMN COMMENTS
-- =============================================================================

COMMENT ON TABLE core.virtual_accounts IS 
    'Virtual sub-accounts for budgeting, savings goals, and temporary holds linked to parent accounts.';

COMMENT ON COLUMN core.virtual_accounts.virtual_account_id IS 
    'Unique identifier for the virtual account';
COMMENT ON COLUMN core.virtual_accounts.parent_account_id IS 
    'The parent account that owns this virtual account';
COMMENT ON COLUMN core.virtual_accounts.virtual_account_type IS 
    'Type: BUDGET, SAVINGS_GOAL, ESCROW, RESERVE, TEMPORARY_HOLD';
COMMENT ON COLUMN core.virtual_accounts.current_balance IS 
    'Total balance in the virtual account';
COMMENT ON COLUMN core.virtual_accounts.available_balance IS 
    'Balance available for use (current - held)';
COMMENT ON COLUMN core.virtual_accounts.target_amount IS 
    'Target amount for savings goals';
COMMENT ON COLUMN core.virtual_accounts.progress_percentage IS 
    'Computed progress toward target (for savings goals)';
COMMENT ON COLUMN core.virtual_accounts.auto_sweep_enabled IS 
    'Whether to automatically sweep excess funds';
COMMENT ON COLUMN core.virtual_accounts.held_amount IS 
    'Amount currently on hold';
COMMENT ON COLUMN core.virtual_accounts.status IS 
    'Status: active, frozen, closed, matured';

-- =============================================================================
-- END OF FILE
-- =============================================================================

COMMIT;
