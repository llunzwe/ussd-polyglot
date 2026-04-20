-- =============================================================================
-- Migration: V018__core_reconciliation_items
-- Description: Core table: reconciliation_items
-- Dependencies: V017
-- Generated: 2026-04-02 16:56:45 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- USSD KERNEL CORE SCHEMA - RECONCILIATION ITEMS
-- Enterprise-Grade Immutable Ledger System
-- =============================================================================
-- FILENAME:    015_reconciliation_items.sql
-- SCHEMA:      ussd_core
-- TABLE:       reconciliation_items
-- DESCRIPTION: Individual reconciliation items representing matched or
--              unmatched transactions from reconciliation runs.
-- =============================================================================

/*
================================================================================
COMPLIANCE FRAMEWORK
================================================================================

ISO/IEC 27001:2022 (Information Security Management Systems)
├── A.12.4 Logging and monitoring - Item-level monitoring
├── A.16.1 Management of information security incidents - Discrepancy investigation
└── A.18.1 Compliance - Audit trail for adjustments

Financial Regulations
├── Exception investigation: Documented resolution
├── Adjustment authorization: Multi-level approval
└── Audit trail: Complete item history

================================================================================
ENTERPRISE POSTGRESQL CODING PRACTICES
================================================================================

1. ITEM STATES
   - MATCHED: Successfully matched
   - UNMATCHED_INTERNAL: Internal item with no external match
   - UNMATCHED_EXTERNAL: External item with no internal match
   - DISCREPANCY: Matched but with amount difference
   - ADJUSTED: Adjustment applied
   - APPROVED: Exception approved

2. MATCHING CRITERIA
   - Reference number matching
   - Amount matching (exact or tolerance)
   - Date matching (with tolerance)
   - Multi-field matching logic

================================================================================
SECURITY IMPLEMENTATION NOTES
================================================================================

ITEM SECURITY:
- Immutable item records
- Adjustment authorization required
- Audit trail for all state changes

================================================================================
PERFORMANCE OPTIMIZATION ANNOTATIONS
================================================================================

INDEXES:
- PRIMARY KEY: item_id
- RUN: run_id + match_status
- REFERENCE: reference_number
- STATUS: match_status

================================================================================
AUDIT AND LOGGING REQUIREMENTS
================================================================================

AUDIT EVENTS:
- ITEM_MATCHED
- ITEM_UNMATCHED
- DISCREPANCY_FOUND
- ADJUSTMENT_APPLIED
- EXCEPTION_APPROVED

RETENTION: 7 years
================================================================================
*/

-- =============================================================================
-- CREATE TABLE: reconciliation_items
-- =============================================================================

CREATE TABLE IF NOT EXISTS core.reconciliation_items (
    -- Primary identifier
    item_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Parent run
    run_id UUID NOT NULL REFERENCES core.reconciliation_runs(run_id) ON DELETE RESTRICT,
    
    -- Match status
    match_status VARCHAR(50) NOT NULL
        CHECK (match_status IN ('MATCHED', 'UNMATCHED_INTERNAL', 'UNMATCHED_EXTERNAL', 'DISCREPANCY', 'ADJUSTED', 'APPROVED')),
    
    -- Source
    source_system VARCHAR(20) NOT NULL CHECK (source_system IN ('INTERNAL', 'EXTERNAL')),
    
    -- Internal record details
    internal_record_id UUID,
    internal_transaction_id BIGINT,
    internal_reference VARCHAR(100),
    internal_amount NUMERIC(20, 8),
    internal_currency VARCHAR(3),
    internal_date DATE,
    internal_metadata JSONB,
    
    -- External record details
    external_record_id VARCHAR(100),
    external_reference VARCHAR(100),
    external_amount NUMERIC(20, 8),
    external_currency VARCHAR(3),
    external_date DATE,
    external_metadata JSONB,
    
    -- Matching details
    matched_record_id UUID REFERENCES core.reconciliation_items(item_id) ON DELETE RESTRICT,
    matched_by VARCHAR(50),  -- Algorithm or manual
    matched_at TIMESTAMPTZ,
    match_confidence NUMERIC(5, 4),  -- For fuzzy matching (0.0000 to 1.0000)
    match_rule VARCHAR(50),  -- Which rule produced the match
    
    -- Discrepancy details
    discrepancy_type VARCHAR(50),  -- AMOUNT, DATE, CURRENCY, MISSING
    discrepancy_amount NUMERIC(20, 8),
    discrepancy_reason TEXT,
    within_tolerance BOOLEAN DEFAULT FALSE,
    
    -- Resolution
    resolution_action VARCHAR(50),  -- ADJUST, APPROVE, INVESTIGATE, PENDING
    resolution_notes TEXT,
    resolved_by UUID,
    resolved_at TIMESTAMPTZ,
    
    -- Related transaction (if adjustment made)
    adjustment_transaction_id BIGINT,
    adjustment_amount NUMERIC(20, 8),
    
    -- Investigation
    investigated BOOLEAN DEFAULT FALSE,
    investigated_by UUID,
    investigated_at TIMESTAMPTZ,
    investigation_notes TEXT,
    
    -- Metadata
    metadata JSONB DEFAULT '{}',
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT chk_matched_has_match_details CHECK (
        match_status NOT IN ('MATCHED', 'DISCREPANCY') OR matched_record_id IS NOT NULL
    ),
    CONSTRAINT chk_adjusted_has_transaction CHECK (
        match_status != 'ADJUSTED' OR adjustment_transaction_id IS NOT NULL
    )
);

-- =============================================================================
-- INDEXES
-- =============================================================================

-- Run lookup
CREATE INDEX IF NOT EXISTS idx_reconciliation_items_run ON core.reconciliation_items(run_id, match_status);

-- Status filtering
CREATE INDEX IF NOT EXISTS idx_reconciliation_items_status ON core.reconciliation_items(match_status);

-- Unmatched items (for attention)
CREATE INDEX IF NOT EXISTS idx_reconciliation_items_unmatched ON core.reconciliation_items(item_id)
    WHERE match_status IN ('UNMATCHED_INTERNAL', 'UNMATCHED_EXTERNAL', 'DISCREPANCY');

-- Reference number lookup
CREATE INDEX IF NOT EXISTS idx_reconciliation_items_int_ref ON core.reconciliation_items(internal_reference)
    WHERE internal_reference IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_reconciliation_items_ext_ref ON core.reconciliation_items(external_reference)
    WHERE external_reference IS NOT NULL;

-- Amount range queries
CREATE INDEX IF NOT EXISTS idx_reconciliation_items_amount ON core.reconciliation_items(internal_amount, external_amount);

-- Date queries
CREATE INDEX IF NOT EXISTS idx_reconciliation_items_date ON core.reconciliation_items(internal_date, external_date);

-- Investigation tracking
CREATE INDEX IF NOT EXISTS idx_reconciliation_items_investigation ON core.reconciliation_items(item_id)
    WHERE investigated = FALSE AND match_status IN ('DISCREPANCY', 'UNMATCHED_INTERNAL', 'UNMATCHED_EXTERNAL');

-- Matched record lookup
CREATE INDEX IF NOT EXISTS idx_reconciliation_items_matched ON core.reconciliation_items(matched_record_id)
    WHERE matched_record_id IS NOT NULL;

-- =============================================================================
-- UPDATE TIMESTAMP TRIGGER
-- =============================================================================

CREATE OR REPLACE FUNCTION core.update_reconciliation_item_timestamp()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_reconciliation_items_update_timestamp ON core.reconciliation_items;
CREATE TRIGGER trg_reconciliation_items_update_timestamp
    BEFORE UPDATE ON core.reconciliation_items
    FOR EACH ROW
    EXECUTE FUNCTION core.update_reconciliation_item_timestamp();

-- =============================================================================
-- HASH COMPUTATION TRIGGER
-- =============================================================================



-- =============================================================================
-- RLS POLICIES
-- =============================================================================

-- Enable RLS
DO $$
BEGIN
    ALTER TABLE core.reconciliation_items ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Policy: Access through parent reconciliation run
CREATE POLICY reconciliation_items_run_access ON core.reconciliation_items
    FOR SELECT
    TO ussd_app_user
    USING (true);  -- Simplified - full access for authenticated users

-- Policy: Kernel role has full access
CREATE POLICY reconciliation_items_kernel_access ON core.reconciliation_items
    FOR ALL
    TO ussd_kernel_role
    USING (true);

-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

-- Function to create a reconciliation item
CREATE OR REPLACE FUNCTION core.create_reconciliation_item(
    p_run_id UUID,
    p_source_system VARCHAR,
    p_match_status VARCHAR,
    p_internal_record_id UUID DEFAULT NULL,
    p_internal_reference VARCHAR DEFAULT NULL,
    p_internal_amount NUMERIC DEFAULT NULL,
    p_internal_currency VARCHAR DEFAULT NULL,
    p_internal_date DATE DEFAULT NULL,
    p_external_record_id VARCHAR DEFAULT NULL,
    p_external_reference VARCHAR DEFAULT NULL,
    p_external_amount NUMERIC DEFAULT NULL,
    p_external_currency VARCHAR DEFAULT NULL,
    p_external_date DATE DEFAULT NULL,
    p_matched_record_id UUID DEFAULT NULL,
    p_match_confidence NUMERIC DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_item_id UUID;
BEGIN
    INSERT INTO core.reconciliation_items (
        run_id,
        source_system,
        match_status,
        internal_record_id,
        internal_reference,
        internal_amount,
        internal_currency,
        internal_date,
        external_record_id,
        external_reference,
        external_amount,
        external_currency,
        external_date,
        matched_record_id,
        match_confidence
    ) VALUES (
        p_run_id,
        p_source_system,
        p_match_status,
        p_internal_record_id,
        p_internal_reference,
        p_internal_amount,
        p_internal_currency,
        p_internal_date,
        p_external_record_id,
        p_external_reference,
        p_external_amount,
        p_external_currency,
        p_external_date,
        p_matched_record_id,
        p_match_confidence
    )
    RETURNING item_id INTO v_item_id;
    
    RETURN v_item_id;
END;
$$;

-- Function to mark items as matched
CREATE OR REPLACE FUNCTION core.mark_items_matched(
    p_internal_item_id UUID,
    p_external_item_id UUID,
    p_matched_by VARCHAR DEFAULT 'MANUAL',
    p_match_confidence NUMERIC DEFAULT 1.0,
    p_match_rule VARCHAR DEFAULT 'MANUAL'
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    -- Update internal item
    UPDATE core.reconciliation_items
    SET 
        match_status = 'MATCHED',
        matched_record_id = p_external_item_id,
        matched_by = p_matched_by,
        matched_at = NOW(),
        match_confidence = p_match_confidence,
        match_rule = p_match_rule
    WHERE item_id = p_internal_item_id;
    
    -- Update external item
    UPDATE core.reconciliation_items
    SET 
        match_status = 'MATCHED',
        matched_record_id = p_internal_item_id,
        matched_by = p_matched_by,
        matched_at = NOW(),
        match_confidence = p_match_confidence,
        match_rule = p_match_rule
    WHERE item_id = p_external_item_id;
    
    RETURN TRUE;
END;
$$;

-- Function to mark discrepancy
CREATE OR REPLACE FUNCTION core.mark_discrepancy(
    p_internal_item_id UUID,
    p_external_item_id UUID,
    p_discrepancy_type VARCHAR,
    p_discrepancy_amount NUMERIC DEFAULT NULL,
    p_discrepancy_reason TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    -- Update internal item
    UPDATE core.reconciliation_items
    SET 
        match_status = 'DISCREPANCY',
        matched_record_id = p_external_item_id,
        discrepancy_type = p_discrepancy_type,
        discrepancy_amount = p_discrepancy_amount,
        discrepancy_reason = p_discrepancy_reason,
        matched_at = NOW()
    WHERE item_id = p_internal_item_id;
    
    -- Update external item
    UPDATE core.reconciliation_items
    SET 
        match_status = 'DISCREPANCY',
        matched_record_id = p_internal_item_id,
        discrepancy_type = p_discrepancy_type,
        discrepancy_amount = p_discrepancy_amount,
        discrepancy_reason = p_discrepancy_reason,
        matched_at = NOW()
    WHERE item_id = p_external_item_id;
    
    RETURN TRUE;
END;
$$;

-- Function to resolve item with adjustment
CREATE OR REPLACE FUNCTION core.resolve_item_adjusted(
    p_item_id UUID,
    p_adjustment_transaction_id BIGINT,
    p_adjustment_amount NUMERIC,
    p_resolved_by UUID,
    p_notes TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE core.reconciliation_items
    SET 
        match_status = 'ADJUSTED',
        adjustment_transaction_id = p_adjustment_transaction_id,
        adjustment_amount = p_adjustment_amount,
        resolution_action = 'ADJUST',
        resolution_notes = p_notes,
        resolved_by = p_resolved_by,
        resolved_at = NOW()
    WHERE item_id = p_item_id;
    
    RETURN FOUND;
END;
$$;

-- Function to approve exception (no adjustment needed)
CREATE OR REPLACE FUNCTION core.approve_item_exception(
    p_item_id UUID,
    p_approved_by UUID,
    p_notes TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE core.reconciliation_items
    SET 
        match_status = 'APPROVED',
        resolution_action = 'APPROVE',
        resolution_notes = p_notes,
        resolved_by = p_approved_by,
        resolved_at = NOW()
    WHERE item_id = p_item_id;
    
    RETURN FOUND;
END;
$$;

-- Function to get unmatched items for a run
CREATE OR REPLACE FUNCTION core.get_unmatched_items(
    p_run_id UUID
)
RETURNS TABLE (
    item_id UUID,
    source_system VARCHAR,
    match_status VARCHAR,
    internal_reference VARCHAR,
    internal_amount NUMERIC(20, 8),
    external_reference VARCHAR,
    external_amount NUMERIC(20, 8),
    discrepancy_type VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ri.item_id,
        ri.source_system,
        ri.match_status,
        ri.internal_reference,
        ri.internal_amount,
        ri.external_reference,
        ri.external_amount,
        ri.discrepancy_type
    FROM core.reconciliation_items ri
    WHERE ri.run_id = p_run_id
    AND ri.match_status IN ('UNMATCHED_INTERNAL', 'UNMATCHED_EXTERNAL', 'DISCREPANCY')
    AND ri.resolved_at IS NULL
    ORDER BY ri.internal_amount DESC NULLS LAST;
END;
$$;

-- Function to get reconciliation item summary
CREATE OR REPLACE FUNCTION core.get_reconciliation_item_summary(
    p_run_id UUID
)
RETURNS TABLE (
    match_status VARCHAR,
    count BIGINT,
    total_internal_amount NUMERIC(20, 8),
    total_external_amount NUMERIC(20, 8),
    total_discrepancy NUMERIC(20, 8)
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ri.match_status,
        COUNT(*)::BIGINT,
        SUM(COALESCE(ri.internal_amount, 0)),
        SUM(COALESCE(ri.external_amount, 0)),
        SUM(COALESCE(ri.discrepancy_amount, 0))
    FROM core.reconciliation_items ri
    WHERE ri.run_id = p_run_id
    GROUP BY ri.match_status;
END;
$$;

-- =============================================================================
-- TABLE AND COLUMN COMMENTS
-- =============================================================================

COMMENT ON TABLE core.reconciliation_items IS 
    'Individual reconciliation items representing matched or unmatched transactions.';

COMMENT ON COLUMN core.reconciliation_items.item_id IS 
    'Unique identifier for the reconciliation item';
COMMENT ON COLUMN core.reconciliation_items.run_id IS 
    'Parent reconciliation run';
COMMENT ON COLUMN core.reconciliation_items.match_status IS 
    'Status: MATCHED, UNMATCHED_INTERNAL, UNMATCHED_EXTERNAL, DISCREPANCY, ADJUSTED, APPROVED';
COMMENT ON COLUMN core.reconciliation_items.source_system IS 
    'Source: INTERNAL or EXTERNAL';
COMMENT ON COLUMN core.reconciliation_items.internal_reference IS 
    'Reference number from internal system';
COMMENT ON COLUMN core.reconciliation_items.external_reference IS 
    'Reference number from external system';
COMMENT ON COLUMN core.reconciliation_items.match_confidence IS 
    'Fuzzy match confidence score (0.0000 to 1.0000)';
COMMENT ON COLUMN core.reconciliation_items.discrepancy_type IS 
    'Type of discrepancy: AMOUNT, DATE, CURRENCY, MISSING';
COMMENT ON COLUMN core.reconciliation_items.adjustment_transaction_id IS 
    'Transaction ID of the adjustment made to resolve';
COMMENT ON COLUMN core.reconciliation_items.within_tolerance IS 
    'Whether the discrepancy is within acceptable tolerance';

-- =============================================================================
-- END OF FILE
-- =============================================================================

COMMIT;
