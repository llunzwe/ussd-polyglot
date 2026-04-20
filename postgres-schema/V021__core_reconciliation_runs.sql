-- =============================================================================
-- Migration: V017__core_reconciliation_runs
-- Description: Core table: reconciliation_runs
-- Dependencies: V016
-- Generated: 2026-04-02 16:56:45 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- USSD KERNEL CORE SCHEMA - RECONCILIATION RUNS
-- Enterprise-Grade Immutable Ledger System
-- =============================================================================
-- FILENAME:    014_reconciliation_runs.sql
-- SCHEMA:      ussd_core
-- TABLE:       reconciliation_runs
-- DESCRIPTION: Master records for reconciliation processes tracking
--              comparison runs between internal and external systems.
-- =============================================================================

/*
================================================================================
COMPLIANCE FRAMEWORK
================================================================================

ISO/IEC 27001:2022 (Information Security Management Systems)
├── A.12.4 Logging and monitoring - Reconciliation monitoring
├── A.16.1 Management of information security incidents - Discrepancy handling
└── A.18.1 Compliance - Regulatory reconciliation requirements

Financial Regulations
├── Daily reconciliation: End-of-day position matching
├── Exception management: Unmatched item investigation
├── Audit trail: Complete reconciliation history
└── Regulatory reporting: Reconciliation status reports

================================================================================
ENTERPRISE POSTGRESQL CODING PRACTICES
================================================================================

1. RECONCILIATION TYPES
   - INTERNAL: Internal system reconciliation
   - BANK: Bank statement reconciliation
   - CARD: Card scheme reconciliation
   - WALLET: Wallet provider reconciliation
   - AGENT: Agent float reconciliation

2. RUN STATES
   - PENDING: Awaiting execution
   - RUNNING: In progress
   - COMPLETED: Successfully finished
   - FAILED: Error occurred
   - APPROVED: Exceptions approved

3. SCHEDULING
   - Daily automated runs
   - Ad-hoc manual runs
   - Scheduled frequency configuration

================================================================================
SECURITY IMPLEMENTATION NOTES
================================================================================

RECONCILIATION SECURITY:
- Data integrity verification
- External file validation
- Unauthorized modification detection

EXCEPTION HANDLING:
- Investigation workflow
- Approval requirements
- Audit trail for adjustments

================================================================================
PERFORMANCE OPTIMIZATION ANNOTATIONS
================================================================================

INDEXES:
- PRIMARY KEY: run_id
- TYPE: reconciliation_type + run_date
- STATUS: status + started_at
- DATE: run_date (reporting)

ARCHIVAL:
- Archive completed runs after 2 years
- Retain summary statistics

================================================================================
AUDIT AND LOGGING REQUIREMENTS
================================================================================

AUDIT EVENTS:
- RECONCILIATION_STARTED
- RECONCILIATION_COMPLETED
- DISCREPANCY_FOUND
- EXCEPTION_APPROVED

RETENTION: 7 years
================================================================================
*/

-- =============================================================================
-- CREATE TABLE: reconciliation_runs
-- =============================================================================

CREATE TABLE IF NOT EXISTS core.reconciliation_runs (
    -- Primary identifier
    run_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    run_reference VARCHAR(100) UNIQUE NOT NULL,
    
    -- Reconciliation definition
    reconciliation_type VARCHAR(50) NOT NULL
        CHECK (reconciliation_type IN ('INTERNAL', 'BANK', 'CARD', 'WALLET', 'MOBILE_MONEY', 'AGENT', 'EXCHANGE')),
    counterparty_id UUID,  -- Bank, provider, etc.
    counterparty_name VARCHAR(255),
    mobile_money_provider VARCHAR(20) CHECK (mobile_money_provider IN ('ecocash', 'telecash', 'onemoney')),
    mobile_money_reconciliation_details JSONB, -- Provider-specific reconciliation data (NULL if not applicable)
    /*
    mobile_money_reconciliation_details JSONB structure (Business Merchant APIs):
    {
        "provider": "ecocash",
        "statement_date": "2024-01-15",
        "statement_reference": "ECO_STMT_20240115",
        "provider_merchant_id": "ECO123456",
        "opening_balance": 150000.00,
        "closing_balance": 175000.00,
        "statement_totals": {
            "total_payments_received": 50000.00,
            "total_payouts_sent": 25000.00,
            "total_refunds": 0.00,
            "transaction_count": 1250
        },
        "ledger_totals": {
            "total_payments_received": 50000.00,
            "total_payouts_sent": 25000.00,
            "total_refunds": 0.00,
            "transaction_count": 1248
        },
        "variance_analysis": {
            "amount_variance": 0.00,
            "count_variance": 2,
            "matched_transactions": 1245,
            "unmatched_ledger": 3,
            "unmatched_statement": 2
        },
        "matching_criteria": {
            "match_by": ["wallet_transaction_id", "amount", "timestamp"],
            "tolerance_amount": 0.01,
            "tolerance_time_seconds": 300
        },
        "discrepancies": [
            {
                "type": "missing_in_ledger",
                "provider_txn_id": "TXN123456",
                "amount": 100.00,
                "timestamp": "2024-01-15T10:30:00Z"
            }
        ],
        "file_metadata": {
            "file_name": "ECO_STMT_20240115.csv",
            "file_hash": "sha256:...",
            "received_at": "2024-01-16T08:00:00Z"
        }
    }
    -- NOTE: Reconciliation for BUSINESS MERCHANT accounts only.
    -- No cash-in/cash-out/agent float reconciliation - this is not an agent system.
    */
    
    -- Period
    run_date DATE NOT NULL,
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    
    -- Status
    status VARCHAR(50) DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'RUNNING', 'COMPLETED', 'FAILED', 'APPROVED')),
    
    -- Summary statistics
    internal_record_count INTEGER,
    external_record_count INTEGER,
    matched_count INTEGER,
    unmatched_internal_count INTEGER,
    unmatched_external_count INTEGER,
    discrepancy_count INTEGER,
    
    -- Amounts
    internal_total_amount NUMERIC(20, 8),
    external_total_amount NUMERIC(20, 8),
    discrepancy_amount NUMERIC(20, 8),
    
    -- External reference
    external_file_name VARCHAR(255),
    external_file_hash VARCHAR(64),
    external_file_format VARCHAR(50),
    
    -- Timing
    scheduled_at TIMESTAMPTZ,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    duration_ms INTEGER,
    
    -- Approval
    approved_by UUID,
    approved_at TIMESTAMPTZ,
    approval_notes TEXT,
    
    -- Error handling
    error_message TEXT,
    error_details JSONB,
    retry_count INTEGER DEFAULT 0,
    max_retries INTEGER DEFAULT 3,
    
    -- Configuration
    matching_rules JSONB DEFAULT '{}',  -- Rules used for this run
    tolerance_amount NUMERIC(20, 8) DEFAULT 0.01,
    tolerance_percent NUMERIC(5, 4) DEFAULT 0.0001,
    
    -- Metadata
    metadata JSONB DEFAULT '{}',
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT chk_period_valid CHECK (period_end >= period_start),
    CONSTRAINT chk_completed_has_stats CHECK (
        status NOT IN ('COMPLETED', 'APPROVED') OR internal_record_count IS NOT NULL
    )
);

-- =============================================================================
-- INDEXES
-- =============================================================================

-- Run reference lookup
CREATE INDEX IF NOT EXISTS idx_reconciliation_runs_reference ON core.reconciliation_runs(run_reference);

-- Type and date
CREATE INDEX IF NOT EXISTS idx_reconciliation_runs_type_date ON core.reconciliation_runs(reconciliation_type, run_date DESC);

-- Status monitoring
CREATE INDEX IF NOT EXISTS idx_reconciliation_runs_status ON core.reconciliation_runs(status, started_at);

-- Pending runs
CREATE INDEX IF NOT EXISTS idx_reconciliation_runs_pending ON core.reconciliation_runs(run_id)
    WHERE status IN ('PENDING', 'RUNNING');

-- Counterparty lookup
CREATE INDEX IF NOT EXISTS idx_reconciliation_runs_counterparty ON core.reconciliation_runs(counterparty_id, run_date DESC);

-- Run date range
CREATE INDEX IF NOT EXISTS idx_reconciliation_runs_date ON core.reconciliation_runs(run_date DESC);

-- Period queries
CREATE INDEX IF NOT EXISTS idx_reconciliation_runs_period ON core.reconciliation_runs(period_start, period_end);

-- Approval tracking
CREATE INDEX IF NOT EXISTS idx_reconciliation_runs_approval ON core.reconciliation_runs(approved_by, approved_at)
    WHERE approved_by IS NOT NULL;

-- =============================================================================
-- UPDATE TIMESTAMP TRIGGER
-- =============================================================================

CREATE OR REPLACE FUNCTION core.update_reconciliation_timestamp()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    
    -- Calculate duration when completing
    IF NEW.status IN ('COMPLETED', 'APPROVED', 'FAILED') AND OLD.status = 'RUNNING' THEN
        NEW.duration_ms := EXTRACT(EPOCH FROM (NOW() - OLD.started_at)) * 1000;
    END IF;
    
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_reconciliation_runs_update_timestamp ON core.reconciliation_runs;
CREATE TRIGGER trg_reconciliation_runs_update_timestamp
    BEFORE UPDATE ON core.reconciliation_runs
    FOR EACH ROW
    EXECUTE FUNCTION core.update_reconciliation_timestamp();

-- =============================================================================
-- HASH COMPUTATION TRIGGER
-- =============================================================================



-- =============================================================================
-- RLS POLICIES
-- =============================================================================

-- Enable RLS
DO $$
BEGIN
    ALTER TABLE core.reconciliation_runs ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Policy: All authenticated users can view reconciliation runs
CREATE POLICY reconciliation_runs_read ON core.reconciliation_runs
    FOR SELECT
    TO ussd_app_user
    USING (true);

-- Policy: Kernel role has full access
CREATE POLICY reconciliation_runs_kernel_access ON core.reconciliation_runs
    FOR ALL
    TO ussd_kernel_role
    USING (true);

-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

-- Function to create a reconciliation run
CREATE OR REPLACE FUNCTION core.create_reconciliation_run(
    p_run_reference VARCHAR,
    p_reconciliation_type VARCHAR,
    p_period_start DATE,
    p_period_end DATE,
    p_counterparty_id UUID DEFAULT NULL,
    p_counterparty_name VARCHAR DEFAULT NULL,
    p_external_file_name VARCHAR DEFAULT NULL,
    p_matching_rules JSONB DEFAULT '{}',
    p_tolerance_amount NUMERIC DEFAULT 0.01,
    p_created_by UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_id UUID;
BEGIN
    INSERT INTO core.reconciliation_runs (
        run_reference,
        reconciliation_type,
        run_date,
        period_start,
        period_end,
        counterparty_id,
        counterparty_name,
        external_file_name,
        matching_rules,
        tolerance_amount,
        created_by
    ) VALUES (
        p_run_reference,
        p_reconciliation_type,
        CURRENT_DATE,
        p_period_start,
        p_period_end,
        p_counterparty_id,
        p_counterparty_name,
        p_external_file_name,
        p_matching_rules,
        p_tolerance_amount,
        p_created_by
    )
    RETURNING run_id INTO v_run_id;
    
    RETURN v_run_id;
END;
$$;

-- Function to start a reconciliation run
CREATE OR REPLACE FUNCTION core.start_reconciliation_run(
    p_run_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE core.reconciliation_runs
    SET 
        status = 'RUNNING',
        started_at = NOW()
    WHERE run_id = p_run_id
    AND status = 'PENDING';
    
    RETURN FOUND;
END;
$$;

-- Function to complete a reconciliation run
CREATE OR REPLACE FUNCTION core.complete_reconciliation_run(
    p_run_id UUID,
    p_internal_record_count INTEGER,
    p_external_record_count INTEGER,
    p_matched_count INTEGER,
    p_unmatched_internal_count INTEGER,
    p_unmatched_external_count INTEGER,
    p_internal_total_amount NUMERIC,
    p_external_total_amount NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_discrepancy_count INTEGER;
    v_discrepancy_amount NUMERIC(20, 8);
BEGIN
    v_discrepancy_count := p_unmatched_internal_count + p_unmatched_external_count;
    v_discrepancy_amount := ABS(COALESCE(p_internal_total_amount, 0) - COALESCE(p_external_total_amount, 0));
    
    UPDATE core.reconciliation_runs
    SET 
        status = 'COMPLETED',
        internal_record_count = p_internal_record_count,
        external_record_count = p_external_record_count,
        matched_count = p_matched_count,
        unmatched_internal_count = p_unmatched_internal_count,
        unmatched_external_count = p_unmatched_external_count,
        discrepancy_count = v_discrepancy_count,
        internal_total_amount = p_internal_total_amount,
        external_total_amount = p_external_total_amount,
        discrepancy_amount = v_discrepancy_amount,
        completed_at = NOW()
    WHERE run_id = p_run_id
    AND status = 'RUNNING';
    
    RETURN FOUND;
END;
$$;

-- Function to fail a reconciliation run
CREATE OR REPLACE FUNCTION core.fail_reconciliation_run(
    p_run_id UUID,
    p_error_message TEXT,
    p_error_details JSONB DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_retries INTEGER;
BEGIN
    SELECT retry_count INTO v_current_retries
    FROM core.reconciliation_runs
    WHERE run_id = p_run_id;
    
    UPDATE core.reconciliation_runs
    SET 
        status = CASE WHEN v_current_retries >= max_retries THEN 'FAILED' ELSE 'PENDING' END,
        error_message = p_error_message,
        error_details = p_error_details,
        retry_count = retry_count + 1,
        completed_at = CASE WHEN v_current_retries >= max_retries THEN NOW() ELSE NULL END
    WHERE run_id = p_run_id;
    
    RETURN FOUND;
END;
$$;

-- Function to approve reconciliation exceptions
CREATE OR REPLACE FUNCTION core.approve_reconciliation_exceptions(
    p_run_id UUID,
    p_approved_by UUID,
    p_notes TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE core.reconciliation_runs
    SET 
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = NOW(),
        approval_notes = p_notes
    WHERE run_id = p_run_id
    AND status = 'COMPLETED';
    
    RETURN FOUND;
END;
$$;

-- Function to get reconciliation summary
CREATE OR REPLACE FUNCTION core.get_reconciliation_summary(
    p_start_date DATE,
    p_end_date DATE,
    p_reconciliation_type VARCHAR DEFAULT NULL
)
RETURNS TABLE (
    reconciliation_type VARCHAR,
    total_runs BIGINT,
    completed_runs BIGINT,
    failed_runs BIGINT,
    total_matched BIGINT,
    total_unmatched BIGINT,
    avg_discrepancy_pct NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        rr.reconciliation_type,
        COUNT(*)::BIGINT as total_runs,
        COUNT(*) FILTER (WHERE rr.status = 'COMPLETED')::BIGINT as completed_runs,
        COUNT(*) FILTER (WHERE rr.status = 'FAILED')::BIGINT as failed_runs,
        SUM(COALESCE(rr.matched_count, 0))::BIGINT as total_matched,
        SUM(COALESCE(rr.unmatched_internal_count, 0) + COALESCE(rr.unmatched_external_count, 0))::BIGINT as total_unmatched,
        AVG(
            CASE 
                WHEN rr.internal_total_amount = 0 THEN 0
                ELSE ABS(rr.internal_total_amount - COALESCE(rr.external_total_amount, 0)) / rr.internal_total_amount * 100
            END
        )::NUMERIC(10, 4) as avg_discrepancy_pct
    FROM core.reconciliation_runs rr
    WHERE rr.run_date BETWEEN p_start_date AND p_end_date
    AND (p_reconciliation_type IS NULL OR rr.reconciliation_type = p_reconciliation_type)
    GROUP BY rr.reconciliation_type;
END;
$$;

-- Function to get pending reconciliations
CREATE OR REPLACE FUNCTION core.get_pending_reconciliations()
RETURNS TABLE (
    run_id UUID,
    run_reference VARCHAR,
    reconciliation_type VARCHAR,
    counterparty_name VARCHAR,
    run_date DATE,
    scheduled_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        rr.run_id,
        rr.run_reference,
        rr.reconciliation_type,
        rr.counterparty_name,
        rr.run_date,
        rr.scheduled_at
    FROM core.reconciliation_runs rr
    WHERE rr.status IN ('PENDING', 'RUNNING')
    ORDER BY rr.scheduled_at, rr.run_date;
END;
$$;

-- =============================================================================
-- TABLE AND COLUMN COMMENTS
-- =============================================================================

COMMENT ON TABLE core.reconciliation_runs IS 
    'Master records for reconciliation processes comparing internal and external systems.';

COMMENT ON COLUMN core.reconciliation_runs.run_id IS 
    'Unique identifier for the reconciliation run';
COMMENT ON COLUMN core.reconciliation_runs.reconciliation_type IS 
    'Type: INTERNAL, BANK, CARD, WALLET, AGENT, EXCHANGE';
COMMENT ON COLUMN core.reconciliation_runs.status IS 
    'Status: PENDING, RUNNING, COMPLETED, FAILED, APPROVED';
COMMENT ON COLUMN core.reconciliation_runs.period_start IS 
    'Start of reconciliation period';
COMMENT ON COLUMN core.reconciliation_runs.period_end IS 
    'End of reconciliation period';
COMMENT ON COLUMN core.reconciliation_runs.matched_count IS 
    'Number of successfully matched records';
COMMENT ON COLUMN core.reconciliation_runs.discrepancy_count IS 
    'Number of unmatched/discrepant records';
COMMENT ON COLUMN core.reconciliation_runs.tolerance_amount IS 
    'Amount tolerance for matching (records within this difference are considered matched)';
COMMENT ON COLUMN core.reconciliation_runs.matching_rules IS 
    'JSON configuration of matching rules used for this run';

-- =============================================================================
-- END OF FILE
-- =============================================================================

COMMIT;
