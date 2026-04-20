-- =============================================================================
-- Migration: V016__consolidated_suspense
-- Description: Consolidated Suspense Table (replaces V019, V020)
-- Dependencies: V001-V015
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- CONSOLIDATED SUSPENSE ITEMS
-- Replaces: suspense_items + suspense_resolutions
-- =============================================================================

CREATE TABLE IF NOT EXISTS core.suspense_items (
    suspense_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Identification
    suspense_reference VARCHAR(100) NOT NULL UNIQUE,
    
    -- Source transaction
    source_transaction_id BIGINT,
    source_transaction_type VARCHAR(50),
    
    -- Amount
    amount NUMERIC(20, 8) NOT NULL,
    currency VARCHAR(3) NOT NULL,
    
    -- Suspense account
    suspense_account_id UUID NOT NULL,
    
    -- Categorization
    category VARCHAR(50) NOT NULL 
        CHECK (category IN ('UNIDENTIFIED', 'PENDING_DOCS', 'DISPUTED', 'INVESTIGATION', 'AWAITING_APPROVAL')),
    priority VARCHAR(20) DEFAULT 'normal' 
        CHECK (priority IN ('low', 'normal', 'high', 'critical')),
    
    -- Status
    status VARCHAR(20) DEFAULT 'open' 
        CHECK (status IN ('open', 'under_review', 'pending_approval', 'resolved', 'written_off')),
    
    -- Description
    description TEXT,
    source_info JSONB, -- Flexible storage for source details
    
    -- Aging
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    days_in_suspense INTEGER DEFAULT 0,
    
    -- Escalation
    escalation_level INTEGER DEFAULT 0,
    escalated_at TIMESTAMPTZ,
    escalated_to UUID,
    
    -- Resolution (embedded from suspense_resolutions)
    resolution_type VARCHAR(50) CHECK (resolution_type IN ('TRANSFER', 'RETURN', 'WRITE_OFF', 'RECLASSIFY', 'ADJUST')),
    resolution_date TIMESTAMPTZ,
    resolution_notes TEXT,
    resolved_by UUID,
    approved_by UUID,
    
    -- Transfer details (if applicable)
    destination_account_id UUID,
    transfer_transaction_id BIGINT,
    
    -- Write-off details (if applicable)
    write_off_authorized_by UUID,
    write_off_authorized_at TIMESTAMPTZ,
    write_off_reason TEXT,
    
    -- Audit
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_suspense_status 
    ON core.suspense_items(status, category);

CREATE INDEX IF NOT EXISTS idx_suspense_account 
    ON core.suspense_items(suspense_account_id, status);

CREATE INDEX IF NOT EXISTS idx_suspense_aging 
    ON core.suspense_items(days_in_suspense, priority) 
    WHERE status = 'open';

CREATE INDEX IF NOT EXISTS idx_suspense_escalation 
    ON core.suspense_items(escalation_level, escalated_at) 
    WHERE status = 'open';

CREATE INDEX IF NOT EXISTS idx_suspense_resolved 
    ON core.suspense_items(resolution_date) 
    WHERE status = 'resolved';

COMMENT ON TABLE core.suspense_items IS 'Consolidated suspense items with embedded resolution tracking';

-- =============================================================================
-- SUSPENSE ACTIVITY LOG
-- Separate table for activity history
-- =============================================================================

CREATE TABLE IF NOT EXISTS core.suspense_activity_log (
    activity_id UUID DEFAULT gen_random_uuid(),
    
    suspense_id UUID NOT NULL REFERENCES core.suspense_items(suspense_id),
    
    -- Activity details
    activity_type VARCHAR(50) NOT NULL 
        CHECK (activity_type IN ('CREATED', 'CLASSIFIED', 'ESCALATED', 'REVIEWED', 'RESOLVED', 'REOPENED')),
    
    -- Change details
    from_status VARCHAR(50),
    to_status VARCHAR(50),
    from_category VARCHAR(50),
    to_category VARCHAR(50),
    
    -- Context
    performed_by UUID,
    notes TEXT,
    metadata JSONB,
    
    -- Timestamp
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Partition key
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT pk_core_suspense_activity_log_activity_id_created_at PRIMARY KEY (activity_id, created_at));

-- Convert to hypertable
SELECT create_hypertable(
    'core.suspense_activity_log',
    'created_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_suspense_activity_suspense 
    ON core.suspense_activity_log(suspense_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_suspense_activity_type 
    ON core.suspense_activity_log(activity_type, created_at DESC);

COMMENT ON TABLE core.suspense_activity_log IS 'Suspense item activity history';

-- =============================================================================
-- WORM TRIGGERS
-- =============================================================================

CREATE TRIGGER trg_suspense_items_prevent_update
    BEFORE UPDATE ON core.suspense_items
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_suspense_items_prevent_delete
    BEFORE DELETE ON core.suspense_items
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

CREATE TRIGGER trg_suspense_activity_log_prevent_update
    BEFORE UPDATE ON core.suspense_activity_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_suspense_activity_log_prevent_delete
    BEFORE DELETE ON core.suspense_activity_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

COMMIT;
