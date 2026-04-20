-- =============================================================================
-- Migration: V021__core_control_batches
-- Description: Core table: control_batches
-- Dependencies: V020
-- Generated: 2026-04-02 16:56:45 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- USSD KERNEL CORE SCHEMA - CONTROL BATCHES
-- Enterprise-Grade Immutable Ledger System
-- =============================================================================
-- FILENAME:    018_control_batches.sql
-- SCHEMA:      ussd_core
-- TABLE:       control_batches
-- DESCRIPTION: Control totals and batch processing records for validating
--              bulk operations and ensuring transaction integrity.
-- =============================================================================

/*
================================================================================
COMPLIANCE FRAMEWORK
================================================================================

ISO/IEC 27001:2022 (Information Security Management Systems)
├── A.12.4 Logging and monitoring - Batch processing monitoring
├── A.12.6 Technical vulnerability management - Batch validation
└── A.16.1 Management of information security incidents - Batch failure handling

Financial Regulations
├── Batch control: Control total verification
├── Balancing: Debits must equal credits
└── Audit trail: Complete batch history

================================================================================
ENTERPRISE POSTGRESQL CODING PRACTICES
================================================================================

1. BATCH TYPES
   - PAYROLL: Salary/wage payments
   - DIVIDEND: Dividend distributions
   - REFUND: Customer refunds
   - SETTLEMENT: Inter-party settlements
   - ADJUSTMENT: Bulk adjustments

2. CONTROL TOTALS
   - Transaction count
   - Total debits
   - Total credits
   - Hash total (for validation)

3. STATES
   - PENDING: Awaiting processing
   - VALIDATING: Control totals being checked
   - PROCESSING: Transactions being executed
   - COMPLETED: Successfully processed
   - FAILED: Processing failed

================================================================================
SECURITY IMPLEMENTATION NOTES
================================================================================

BATCH SECURITY:
- Control total verification before processing
- Authorization for batch execution
- Audit trail for batch lifecycle

VALIDATION:
- Pre-processing validation
- Control total matching
- Exception handling

================================================================================
PERFORMANCE OPTIMIZATION ANNOTATIONS
================================================================================

INDEXES:
- PRIMARY KEY: batch_id
- TYPE: batch_type + status
- DATE: scheduled_date (range queries)
- STATUS: status + created_at

================================================================================
AUDIT AND LOGGING REQUIREMENTS
================================================================================

AUDIT EVENTS:
- BATCH_CREATED
- BATCH_VALIDATED
- BATCH_PROCESSING_STARTED
- BATCH_COMPLETED
- BATCH_FAILED

RETENTION: 7 years
================================================================================
*/

-- -----------------------------------------------------------------------------
-- CREATE TABLE: control_batches
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.control_batches (
    -- Primary identifier
    batch_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    batch_reference VARCHAR(100) UNIQUE NOT NULL,
    
    -- Batch definition
    batch_type VARCHAR(50) NOT NULL
        CHECK (batch_type IN ('PAYROLL', 'DIVIDEND', 'REFUND', 'SETTLEMENT', 'ADJUSTMENT', 'INTEREST', 'FEE_ASSESSMENT')),
    batch_name VARCHAR(200) NOT NULL,
    batch_description TEXT,
    
    -- Application scope
    application_id UUID,
    
    -- Status
    status VARCHAR(50) DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'VALIDATING', 'VALIDATED', 'PROCESSING', 'COMPLETED', 'FAILED', 'CANCELLED')),
    
    -- Control totals (expected)
    expected_count INTEGER NOT NULL CHECK (expected_count > 0),
    expected_total_amount NUMERIC(20, 8) NOT NULL CHECK (expected_total_amount >= 0),
    expected_debits NUMERIC(20, 8),
    expected_credits NUMERIC(20, 8),
    hash_total VARCHAR(64),
    
    -- Actual results
    actual_count INTEGER CHECK (actual_count >= 0),
    actual_total_amount NUMERIC(20, 8) CHECK (actual_total_amount >= 0),
    actual_debits NUMERIC(20, 8),
    actual_credits NUMERIC(20, 8),
    
    -- Discrepancy
    discrepancy_count INTEGER,
    discrepancy_amount NUMERIC(20, 8),
    
    -- Scheduling
    scheduled_date DATE NOT NULL,
    scheduled_time TIMESTAMPTZ,
    timezone VARCHAR(50) DEFAULT 'UTC',
    
    -- Processing
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    processing_duration_ms INTEGER,
    
    -- Approval
    submitted_by UUID NOT NULL,
    approved_by UUID,
    approved_at TIMESTAMPTZ,
    
    -- Error handling
    error_message TEXT,
    error_details JSONB,
    retry_count INTEGER DEFAULT 0,
    max_retries INTEGER DEFAULT 3,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    record_hash VARCHAR(64) NOT NULL DEFAULT 'PENDING'
);

-- -----------------------------------------------------------------------------
-- INDEXES
-- -----------------------------------------------------------------------------
-- Batch type and status queries
CREATE INDEX IF NOT EXISTS idx_control_batches_type_status 
    ON core.control_batches(batch_type, status);

-- Scheduled date queries
CREATE INDEX IF NOT EXISTS idx_control_batches_scheduled 
    ON core.control_batches(scheduled_date, status) 
    WHERE status IN ('PENDING', 'VALIDATING', 'VALIDATED');

-- Status monitoring
CREATE INDEX IF NOT EXISTS idx_control_batches_status_date 
    ON core.control_batches(status, created_at);

-- Application-scoped queries
CREATE INDEX IF NOT EXISTS idx_control_batches_application 
    ON core.control_batches(application_id, created_at);

-- Approval tracking
CREATE INDEX IF NOT EXISTS idx_control_batches_approval 
    ON core.control_batches(approved_by, approved_at) 
    WHERE approved_by IS NOT NULL;

-- Reference lookups
CREATE INDEX IF NOT EXISTS idx_control_batches_reference 
    ON core.control_batches(batch_reference);

-- -----------------------------------------------------------------------------
-- IMMUTABILITY TRIGGERS
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_control_batches_prevent_update ON core.control_batches;
CREATE TRIGGER trg_control_batches_prevent_update
    BEFORE UPDATE ON core.control_batches
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

DROP TRIGGER IF EXISTS trg_control_batches_prevent_delete ON core.control_batches;
CREATE TRIGGER trg_control_batches_prevent_delete
    BEFORE DELETE ON core.control_batches
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

-- -----------------------------------------------------------------------------
-- HASH COMPUTATION TRIGGER
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.compute_batch_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.record_hash := core.generate_hash(
        NEW.batch_id::TEXT || 
        NEW.batch_reference || 
        NEW.batch_type ||
        NEW.batch_name ||
        COALESCE(NEW.application_id::TEXT, '') ||
        NEW.status ||
        NEW.expected_count::TEXT ||
        NEW.expected_total_amount::TEXT ||
        NEW.scheduled_date::TEXT ||
        NEW.created_at::TEXT
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_control_batches_compute_hash ON core.control_batches;
CREATE TRIGGER trg_control_batches_compute_hash
    BEFORE INSERT ON core.control_batches
    FOR EACH ROW
    EXECUTE FUNCTION core.compute_batch_hash();

-- -----------------------------------------------------------------------------
-- HELPER FUNCTIONS
-- -----------------------------------------------------------------------------

-- Function to create a new batch
CREATE OR REPLACE FUNCTION core.create_control_batch(
    p_batch_type VARCHAR(50),
    p_batch_name VARCHAR(200),
    p_batch_description TEXT,
    p_expected_count INTEGER,
    p_expected_total_amount NUMERIC,
    p_scheduled_date DATE,
    p_submitted_by UUID,
    p_application_id UUID DEFAULT NULL,
    p_expected_debits NUMERIC DEFAULT NULL,
    p_expected_credits NUMERIC DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_batch_id UUID;
    v_reference VARCHAR(100);
BEGIN
    -- Generate reference
    v_reference := 'BCH-' || UPPER(p_batch_type) || '-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || SUBSTRING(MD5(RANDOM()::TEXT), 1, 6);
    
    INSERT INTO core.control_batches (
        batch_reference,
        batch_type,
        batch_name,
        batch_description,
        application_id,
        expected_count,
        expected_total_amount,
        expected_debits,
        expected_credits,
        scheduled_date,
        submitted_by,
        created_by
    ) VALUES (
        v_reference,
        p_batch_type,
        p_batch_name,
        p_batch_description,
        p_application_id,
        p_expected_count,
        p_expected_total_amount,
        COALESCE(p_expected_debits, p_expected_total_amount),
        COALESCE(p_expected_credits, p_expected_total_amount),
        p_scheduled_date,
        p_submitted_by,
        p_submitted_by
    ) RETURNING batch_id INTO v_batch_id;
    
    RETURN v_batch_id;
END;
$$;

-- Function to update batch results (creates new version)
CREATE OR REPLACE FUNCTION core.update_batch_results(
    p_batch_id UUID,
    p_actual_count INTEGER,
    p_actual_total_amount NUMERIC,
    p_status VARCHAR(50),
    p_error_message TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_new_batch_id UUID;
    v_old_record RECORD;
BEGIN
    SELECT * INTO v_old_record FROM core.control_batches WHERE batch_id = p_batch_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Batch % not found', p_batch_id;
    END IF;
    
    -- Create new version with updated results
    INSERT INTO core.control_batches (
        batch_reference,
        batch_type,
        batch_name,
        batch_description,
        application_id,
        status,
        expected_count,
        expected_total_amount,
        expected_debits,
        expected_credits,
        actual_count,
        actual_total_amount,
        actual_debits,
        actual_credits,
        discrepancy_count,
        discrepancy_amount,
        scheduled_date,
        submitted_by,
        approved_by,
        approved_at,
        created_by
    ) VALUES (
        v_old_record.batch_reference || '-R' || (v_old_record.retry_count + 1)::TEXT,
        v_old_record.batch_type,
        v_old_record.batch_name,
        v_old_record.batch_description,
        v_old_record.application_id,
        p_status,
        v_old_record.expected_count,
        v_old_record.expected_total_amount,
        v_old_record.expected_debits,
        v_old_record.expected_credits,
        p_actual_count,
        p_actual_total_amount,
        p_actual_total_amount,
        p_actual_total_amount,
        v_old_record.expected_count - p_actual_count,
        v_old_record.expected_total_amount - p_actual_total_amount,
        v_old_record.scheduled_date,
        v_old_record.submitted_by,
        v_old_record.approved_by,
        v_old_record.approved_at,
        v_old_record.created_by
    ) RETURNING batch_id INTO v_new_batch_id;
    
    RETURN v_new_batch_id;
END;
$$;

-- Function to get batch statistics
CREATE OR REPLACE FUNCTION core.get_batch_statistics(
    p_start_date DATE,
    p_end_date DATE,
    p_application_id UUID DEFAULT NULL
)
RETURNS TABLE (
    batch_type VARCHAR(50),
    total_batches BIGINT,
    completed_batches BIGINT,
    failed_batches BIGINT,
    total_amount NUMERIC,
    avg_processing_time_ms NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        cb.batch_type,
        COUNT(*) as total_batches,
        COUNT(*) FILTER (WHERE cb.status = 'COMPLETED') as completed_batches,
        COUNT(*) FILTER (WHERE cb.status = 'FAILED') as failed_batches,
        SUM(cb.actual_total_amount) as total_amount,
        AVG(cb.processing_duration_ms)::NUMERIC as avg_processing_time_ms
    FROM core.control_batches cb
    WHERE cb.created_at::DATE BETWEEN p_start_date AND p_end_date
      AND (p_application_id IS NULL OR cb.application_id = p_application_id)
    GROUP BY cb.batch_type
    ORDER BY total_batches DESC;
END;
$$;

-- Function to validate control totals
CREATE OR REPLACE FUNCTION core.validate_control_totals(
    p_batch_id UUID
)
RETURNS TABLE (
    is_valid BOOLEAN,
    count_match BOOLEAN,
    amount_match BOOLEAN,
    discrepancy_count INTEGER,
    discrepancy_amount NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_batch RECORD;
BEGIN
    SELECT * INTO v_batch FROM core.control_batches WHERE batch_id = p_batch_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Batch % not found', p_batch_id;
    END IF;
    
    RETURN QUERY
    SELECT 
        (v_batch.actual_count = v_batch.expected_count 
         AND v_batch.actual_total_amount = v_batch.expected_total_amount) as is_valid,
        (v_batch.actual_count = v_batch.expected_count) as count_match,
        (v_batch.actual_total_amount = v_batch.expected_total_amount) as amount_match,
        (v_batch.expected_count - COALESCE(v_batch.actual_count, 0)) as discrepancy_count,
        (v_batch.expected_total_amount - COALESCE(v_batch.actual_total_amount, 0)) as discrepancy_amount;
END;
$$;

-- -----------------------------------------------------------------------------
-- COMMENTS
-- -----------------------------------------------------------------------------
COMMENT ON TABLE core.control_batches IS 'Control totals and batch processing records for bulk operations';
COMMENT ON COLUMN core.control_batches.batch_id IS 'Unique identifier for the batch';
COMMENT ON COLUMN core.control_batches.status IS 'Current status in the batch lifecycle';
COMMENT ON COLUMN core.control_batches.expected_count IS 'Expected number of items in batch';
COMMENT ON COLUMN core.control_batches.actual_count IS 'Actual number of items processed';

-- =============================================================================
-- END OF FILE
-- =============================================================================

COMMIT;
