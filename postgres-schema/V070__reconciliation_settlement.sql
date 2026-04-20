-- =============================================================================
-- Migration: V070__reconciliation_settlement
-- Description: Reconciliation, Settlement & Dispute Resolution
-- Dependencies: V001-V069
--
-- PURPOSE: Enable business apps to reconcile their records with the kernel
-- ledger, generate settlement files, and track dispute resolution.
--
-- ADR-017: Reconciliation Data Storage
-- DECISION: Store reconciliation reports with mismatch details in JSONB
-- RATIONALE:
--   - Reconciliation generates complex mismatch data
--   - JSONB allows flexible structure for different provider formats
--   - Reports are immutable once generated
--   - TimescaleDB hypertable for automatic partitioning
-- TRADE-OFFS:
--   (+) Flexible schema for different provider formats
--   (+) Automatic time-based partitioning
--   (-) Less structured than normalized tables
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- SCHEMA: reconciliation
-- PURPOSE: Reconciliation, settlement, and dispute management
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS reconciliation;
COMMENT ON SCHEMA reconciliation IS 'Reconciliation, settlement, and dispute resolution for business applications';

-- =============================================================================
-- TABLE: reconciliation.reports
-- PURPOSE: Reconciliation report between kernel and provider statements
-- SECURITY: Application-scoped via RLS
-- =============================================================================
CREATE TABLE IF NOT EXISTS reconciliation.reports (
    report_id UUID DEFAULT gen_random_uuid(),
    
    -- Report identification
    report_reference VARCHAR(100),
    CONSTRAINT uq_reconciliation_reports_report_reference UNIQUE (report_reference, created_at), NOT NULL,
    
    -- Application context
    application_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    
    -- Scope
    reconciliation_type VARCHAR(50) NOT NULL 
        CHECK (reconciliation_type IN ('provider_statement', 'internal_audit', 'settlement_file')),
    provider_id VARCHAR(50), -- e.g., 'africastalking', 'ecocash'
    
    -- Date range
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    
    -- Source data
    source_file_name VARCHAR(255),
    source_file_hash VARCHAR(64), -- SHA-256 of uploaded statement
    source_record_count INTEGER,
    
    -- Kernel data summary
    kernel_transaction_count INTEGER,
    kernel_total_amount NUMERIC(20, 8),
    kernel_total_fees NUMERIC(20, 8),
    
    -- Provider data summary
    provider_transaction_count INTEGER,
    provider_total_amount NUMERIC(20, 8),
    provider_total_fees NUMERIC(20, 8),
    
    -- Reconciliation results
    matched_count INTEGER DEFAULT 0,
    matched_amount NUMERIC(20, 8) DEFAULT 0,
    unmatched_kernel_count INTEGER DEFAULT 0,
    unmatched_kernel_amount NUMERIC(20, 8) DEFAULT 0,
    unmatched_provider_count INTEGER DEFAULT 0,
    unmatched_provider_amount NUMERIC(20, 8) DEFAULT 0,
    
    -- Status
    status VARCHAR(20) DEFAULT 'pending' 
        CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
    
    -- Report file
    report_file_location VARCHAR(500),
    report_generated_at TIMESTAMPTZ,
    
    -- Timing
    started_at TIMESTAMPTZ DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    
    -- Audit
    created_by UUID REFERENCES core.account_registry(account_id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_reconciliation_reports_report_id_created_at PRIMARY KEY (report_id, created_at));

-- Convert to hypertable
SELECT create_hypertable(
    'reconciliation.reports',
    'created_at',
    chunk_time_interval => INTERVAL '30 days',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_reconciliation_reports_app ON reconciliation.reports(application_id, period_start DESC);
CREATE INDEX IF NOT EXISTS idx_reconciliation_reports_status ON reconciliation.reports(status, created_at);
CREATE INDEX IF NOT EXISTS idx_reconciliation_reports_provider ON reconciliation.reports(provider_id, period_start);

COMMENT ON TABLE reconciliation.reports IS 
'Reconciliation reports comparing kernel ledger with provider statements';

-- =============================================================================
-- TABLE: reconciliation.mismatches
-- PURPOSE: Individual mismatched transactions from reconciliation
-- SECURITY: Application-scoped via RLS
-- =============================================================================
CREATE TABLE IF NOT EXISTS reconciliation.mismatches (
    mismatch_id UUID DEFAULT gen_random_uuid(),
    
    -- Reference
    report_id UUID NOT NULL,
    
    -- Mismatch classification
    mismatch_type VARCHAR(50) NOT NULL 
        CHECK (mismatch_type IN (
            'kernel_only',      -- In kernel, not in provider
            'provider_only',    -- In provider, not in kernel
            'amount_diff',      -- Both present, amounts differ
            'status_diff',      -- Both present, status differs
            'fee_diff',         -- Fee amounts differ
            'duplicate',        -- Duplicate in one system
            'date_mismatch'     -- Transaction dates differ
        )),
    
    -- Kernel record
    kernel_transaction_id UUID REFERENCES core.transactions(transaction_id),
    kernel_reference VARCHAR(255),
    kernel_amount NUMERIC(20, 8),
    kernel_status VARCHAR(50),
    kernel_date TIMESTAMPTZ,
    
    -- Provider record
    provider_reference VARCHAR(255),
    provider_amount NUMERIC(20, 8),
    provider_status VARCHAR(50),
    provider_date TIMESTAMPTZ,
    provider_raw_data JSONB, -- Original provider row
    
    -- Difference details
    amount_difference NUMERIC(20, 8),
    discrepancy_reason TEXT,
    
    -- Resolution
    resolution_status VARCHAR(20) DEFAULT 'open' 
        CHECK (resolution_status IN ('open', 'investigating', 'resolved', 'disputed')),
    resolution_notes TEXT,
    resolved_by UUID REFERENCES core.account_registry(account_id),
    resolved_at TIMESTAMPTZ,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_reconciliation_mismatches_mismatch_id_created_at PRIMARY KEY (mismatch_id, created_at));

-- Convert to hypertable
SELECT create_hypertable(
    'reconciliation.mismatches',
    'created_at',
    chunk_time_interval => INTERVAL '30 days',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_mismatches_report ON reconciliation.mismatches(report_id, mismatch_type);
CREATE INDEX IF NOT EXISTS idx_mismatches_status ON reconciliation.mismatches(resolution_status, created_at);
CREATE INDEX IF NOT EXISTS idx_mismatches_kernel ON reconciliation.mismatches(kernel_transaction_id) WHERE kernel_transaction_id IS NOT NULL;

COMMENT ON TABLE reconciliation.mismatches IS 
'Individual transaction mismatches identified during reconciliation';

-- =============================================================================
-- TABLE: reconciliation.settlement_files
-- PURPOSE: Generated settlement files for mobile money providers
-- SECURITY: Application-scoped via RLS
-- =============================================================================
CREATE TABLE IF NOT EXISTS reconciliation.settlement_files (
    file_id UUID DEFAULT gen_random_uuid(),
    
    -- File identification
    file_reference VARCHAR(100),
    CONSTRAINT uq_reconciliation_settlement_files_file_reference UNIQUE (file_reference, created_at), NOT NULL,
    
    -- Application context
    application_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    
    -- Settlement scope
    provider_id VARCHAR(50) NOT NULL,
    settlement_type VARCHAR(30) NOT NULL 
        CHECK (settlement_type IN ('daily', 'weekly', 'monthly', 'adhoc')),
    settlement_period_start DATE NOT NULL,
    settlement_period_end DATE NOT NULL,
    
    -- File details
    file_format VARCHAR(10) NOT NULL CHECK (file_format IN ('csv', 'xml', 'json')),
    file_location VARCHAR(500) NOT NULL,
    file_size_bytes BIGINT,
    checksum_sha256 VARCHAR(64),
    
    -- Content summary
    record_count INTEGER,
    total_amount NUMERIC(20, 8),
    total_fees NUMERIC(20, 8),
    total_settlement NUMERIC(20, 8),
    currency_code VARCHAR(3),
    
    -- Provider-specific fields
    provider_batch_id VARCHAR(100), -- Provider's reference when submitted
    provider_submitted_at TIMESTAMPTZ,
    provider_acknowledged_at TIMESTAMPTZ,
    
    -- Status
    status VARCHAR(20) DEFAULT 'generated' 
        CHECK (status IN ('generated', 'submitted', 'acknowledged', 'settled', 'rejected')),
    
    -- Error handling
    rejection_reason TEXT,
    retry_count INTEGER DEFAULT 0,
    
    -- Timing
    generated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '90 days'),
    
    -- Audit
    generated_by UUID REFERENCES core.account_registry(account_id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_reconciliation_settlement_files_file_id_created_at PRIMARY KEY (file_id, created_at));

-- Convert to hypertable
SELECT create_hypertable(
    'reconciliation.settlement_files',
    'created_at',
    chunk_time_interval => INTERVAL '30 days',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_settlement_files_app ON reconciliation.settlement_files(application_id, settlement_period_start DESC);
CREATE INDEX IF NOT EXISTS idx_settlement_files_provider ON reconciliation.settlement_files(provider_id, status);
CREATE INDEX IF NOT EXISTS idx_settlement_files_ref ON reconciliation.settlement_files(file_reference);

COMMENT ON TABLE reconciliation.settlement_files IS 
'Generated settlement files for mobile money providers';

-- =============================================================================
-- TABLE: reconciliation.disputes
-- PURPOSE: Chargeback and dispute tracking with full history
-- SECURITY: Application-scoped via RLS
-- =============================================================================
CREATE TABLE IF NOT EXISTS reconciliation.disputes (
    dispute_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Dispute identification
    dispute_reference VARCHAR(100) UNIQUE NOT NULL,
    
    -- Application context
    application_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    
    -- Original transaction
    original_transaction_id UUID NOT NULL REFERENCES core.transactions(transaction_id),
    reversal_transaction_id UUID REFERENCES core.transactions(transaction_id),
    
    -- Dispute details
    dispute_type VARCHAR(50) NOT NULL 
        CHECK (dispute_type IN ('chargeback', 'refund_request', 'duplicate_charge', 'fraud_claim', 'error_correction')),
    dispute_reason TEXT NOT NULL,
    dispute_amount NUMERIC(20, 8) NOT NULL,
    currency_code VARCHAR(3) NOT NULL,
    
    -- Filed by
    filed_by VARCHAR(100), -- Customer, business, provider
    filed_by_contact VARCHAR(255),
    
    -- Provider info (if provider-initiated)
    provider_id VARCHAR(50),
    provider_dispute_id VARCHAR(100),
    
    -- Status workflow
    status VARCHAR(30) DEFAULT 'open' 
        CHECK (status IN ('open', 'under_review', 'evidence_required', 'accepted', 'rejected', 'resolved', 'escalated')),
    
    -- Resolution
    resolution VARCHAR(50) CHECK (resolution IN ('favor_customer', 'favor_merchant', 'partial_refund', 'write_off')),
    resolved_amount NUMERIC(20, 8),
    resolution_notes TEXT,
    resolved_by UUID REFERENCES core.account_registry(account_id),
    resolved_at TIMESTAMPTZ,
    
    -- Financial impact
    fee_reversal_amount NUMERIC(20, 8),
    chargeback_fee NUMERIC(20, 8),
    
    -- Timestamps
    filed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    evidence_deadline TIMESTAMPTZ,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_disputes_app ON reconciliation.disputes(application_id, status);
CREATE INDEX IF NOT EXISTS idx_disputes_transaction ON reconciliation.disputes(original_transaction_id);
CREATE INDEX IF NOT EXISTS idx_disputes_status ON reconciliation.disputes(status, filed_at);
CREATE INDEX IF NOT EXISTS idx_disputes_deadline ON reconciliation.disputes(evidence_deadline) 
    WHERE status IN ('open', 'evidence_required');

COMMENT ON TABLE reconciliation.disputes IS 
'Dispute tracking for chargebacks, refunds, and fraud claims with full resolution history';

-- =============================================================================
-- TABLE: reconciliation.dispute_history
-- PURPOSE: Audit trail of all dispute status changes and actions
-- SECURITY: Application-scoped via RLS
-- WORM: Immutable audit trail
-- =============================================================================
CREATE TABLE IF NOT EXISTS reconciliation.dispute_history (
    history_id UUID DEFAULT gen_random_uuid(),
    
    dispute_id UUID NOT NULL REFERENCES reconciliation.disputes(dispute_id) ON DELETE CASCADE,
    
    -- Change details
    from_status VARCHAR(30),
    to_status VARCHAR(30) NOT NULL,
    action_taken VARCHAR(100) NOT NULL,
    action_details JSONB,
    
    -- Financial impact of change
    amount_changed NUMERIC(20, 8),
    
    -- Actor
    performed_by UUID REFERENCES core.account_registry(account_id),
    performed_by_role VARCHAR(50),
    
    -- Timestamp
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_reconciliation_dispute_history_history_id_created_at PRIMARY KEY (history_id, created_at));

-- Convert to hypertable
SELECT create_hypertable(
    'reconciliation.dispute_history',
    'created_at',
    chunk_time_interval => INTERVAL '90 days',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_dispute_history_dispute ON reconciliation.dispute_history(dispute_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_dispute_history_status ON reconciliation.dispute_history(to_status, created_at);

COMMENT ON TABLE reconciliation.dispute_history IS 
'Immutable audit trail of all dispute status changes and actions';

-- =============================================================================
-- FUNCTIONS: Reconciliation Operations
-- =============================================================================

-- Function: Auto-match transactions
CREATE OR REPLACE FUNCTION reconciliation.auto_match_transactions(
    p_report_id UUID,
    p_tolerance_amount NUMERIC DEFAULT 0.01
)
RETURNS TABLE (matched INTEGER, unmatched_kernel INTEGER, unmatched_provider INTEGER) AS $$
DECLARE
    v_matched INTEGER := 0;
    v_unmatched_kernel INTEGER := 0;
    v_unmatched_provider INTEGER := 0;
BEGIN
    -- This is a simplified matching logic
    -- Real implementation would use more sophisticated fuzzy matching
    
    -- Match by exact reference and amount within tolerance
    -- Implementation depends on specific provider formats
    
    -- Update report with counts
    UPDATE reconciliation.reports
    SET matched_count = v_matched,
        unmatched_kernel_count = v_unmatched_kernel,
        unmatched_provider_count = v_unmatched_provider,
        status = 'completed',
        completed_at = NOW()
    WHERE report_id = p_report_id;
    
    matched := v_matched;
    unmatched_kernel := v_unmatched_kernel;
    unmatched_provider := v_unmatched_provider;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION reconciliation.auto_match_transactions(UUID, NUMERIC) IS 
'Automatically matches kernel and provider transactions by reference and amount';

-- Function: Create dispute from mismatch
CREATE OR REPLACE FUNCTION reconciliation.create_dispute_from_mismatch(
    p_mismatch_id UUID,
    p_filed_by VARCHAR,
    p_reason TEXT
)
RETURNS UUID AS $$
DECLARE
    v_mismatch RECORD;
    v_dispute_id UUID;
    v_reference VARCHAR(100);
BEGIN
    -- Get mismatch details
    SELECT * INTO v_mismatch
    FROM reconciliation.mismatches
    WHERE mismatch_id = p_mismatch_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Mismatch % not found', p_mismatch_id;
    END IF;
    
    -- Generate reference
    v_reference := 'DSP-' || encode(gen_random_bytes(6), 'hex');
    
    -- Create dispute
    INSERT INTO reconciliation.disputes (
        dispute_reference,
        application_id,
        original_transaction_id,
        dispute_type,
        dispute_reason,
        dispute_amount,
        currency_code,
        filed_by,
        status
    ) VALUES (
        v_reference,
        (SELECT application_id FROM reconciliation.reports WHERE report_id = v_mismatch.report_id),
        v_mismatch.kernel_transaction_id,
        'error_correction',
        p_reason,
        COALESCE(v_mismatch.amount_difference, 0),
        'USD', -- Would derive from context
        p_filed_by,
        'open'
    )
    RETURNING dispute_id INTO v_dispute_id;
    
    -- Update mismatch with dispute reference
    UPDATE reconciliation.mismatches
    SET resolution_status = 'disputed'
    WHERE mismatch_id = p_mismatch_id;
    
    RETURN v_dispute_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION reconciliation.create_dispute_from_mismatch(UUID, VARCHAR, TEXT) IS 
'Creates a formal dispute from an identified reconciliation mismatch';

-- Function: Record dispute status change
CREATE OR REPLACE FUNCTION reconciliation.record_dispute_change()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO reconciliation.dispute_history (
            dispute_id,
            from_status,
            to_status,
            action_taken,
            action_details,
            performed_by
        ) VALUES (
            NEW.dispute_id,
            OLD.status,
            NEW.status,
            'status_change',
            jsonb_build_object(
                'resolution', NEW.resolution,
                'resolved_amount', NEW.resolved_amount
            ),
            COALESCE(NEW.resolved_by, NEW.updated_at)
        );
    END IF;
    
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_dispute_change_log ON reconciliation.disputes;
CREATE TRIGGER trg_dispute_change_log
    AFTER UPDATE ON reconciliation.disputes
    FOR EACH ROW
    EXECUTE FUNCTION reconciliation.record_dispute_change();

-- =============================================================================
-- RLS POLICIES
-- =============================================================================

DO $$
BEGIN
    ALTER TABLE reconciliation.reports ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE reconciliation.reports FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE reconciliation.mismatches ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE reconciliation.mismatches FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE reconciliation.settlement_files ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE reconciliation.settlement_files FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE reconciliation.disputes ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE reconciliation.disputes FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE reconciliation.dispute_history ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE reconciliation.dispute_history FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Application isolation
CREATE POLICY reconciliation_reports_app_isolation ON reconciliation.reports
    FOR ALL
    TO ussd_app_user
    USING (application_id = current_setting('app.current_application_id', true)::UUID);

CREATE POLICY mismatches_app_isolation ON reconciliation.mismatches
    FOR ALL
    TO ussd_app_user
    USING (report_id IN (
        SELECT report_id FROM reconciliation.reports
        WHERE application_id = current_setting('app.current_application_id', true)::UUID
    ));

CREATE POLICY settlement_files_app_isolation ON reconciliation.settlement_files
    FOR ALL
    TO ussd_app_user
    USING (application_id = current_setting('app.current_application_id', true)::UUID);

CREATE POLICY disputes_app_isolation ON reconciliation.disputes
    FOR ALL
    TO ussd_app_user
    USING (application_id = current_setting('app.current_application_id', true)::UUID);

CREATE POLICY dispute_history_app_isolation ON reconciliation.dispute_history
    FOR ALL
    TO ussd_app_user
    USING (dispute_id IN (
        SELECT dispute_id FROM reconciliation.disputes
        WHERE application_id = current_setting('app.current_application_id', true)::UUID
    ));

-- =============================================================================
-- WORM TRIGGERS (Immutability for audit records)
-- =============================================================================

CREATE TRIGGER trg_reconciliation_reports_prevent_update
    BEFORE UPDATE ON reconciliation.reports
    FOR EACH ROW
    WHEN (OLD.status = 'completed')
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_settlement_files_prevent_update_settled
    BEFORE UPDATE ON reconciliation.settlement_files
    FOR EACH ROW
    WHEN (OLD.status = 'settled')
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_dispute_history_prevent_update
    BEFORE UPDATE ON reconciliation.dispute_history
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_dispute_history_prevent_delete
    BEFORE DELETE ON reconciliation.dispute_history
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

-- =============================================================================
-- GRANTS
-- =============================================================================

GRANT USAGE ON SCHEMA reconciliation TO ussd_app_user, ussd_gateway_role;
GRANT SELECT, INSERT ON reconciliation.reports TO ussd_app_user;
GRANT SELECT, UPDATE ON reconciliation.mismatches TO ussd_app_user;
GRANT SELECT ON reconciliation.settlement_files TO ussd_app_user;
GRANT SELECT, INSERT, UPDATE ON reconciliation.disputes TO ussd_app_user;
GRANT SELECT ON reconciliation.dispute_history TO ussd_app_user;

COMMIT;
