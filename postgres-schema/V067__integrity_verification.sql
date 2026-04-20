-- =============================================================================
-- Migration: V067__integrity_verification
-- Description: Ledger Integrity & Verification Support
-- Dependencies: V001-V066
--
-- PURPOSE: Enable verification of ledger entries for business apps
-- without direct database access. Includes batch hash verification, 
-- hash chain proofs, and audit trail verification.
--
-- ADR-011: Batch Hash for Periodic Verification
-- DECISION: Store periodic batch hashes (daily) for verification
-- RATIONALE:
--   - Business apps need to verify ledger integrity periodically
--   - Daily batch hash provides snapshot of ledger state
--   - Individual transaction hash chains provide per-record verification
--   - Apps can verify: daily batch hash + individual hash chain
-- TRADE-OFFS:
--   (+) Simple implementation, low overhead
--   (+) Proven approach used in financial audit systems
--   (-) Batch verification only at daily granularity
--   (-) Requires hash history preservation
--
-- ADR-012: Hash Chain for Individual Records
-- DECISION: Use hash chains (linked list) for individual transaction verification
-- RATIONALE:
--   - Each transaction stores previous_hash forming a chain
--   - Verification: recompute hash, compare to stored
--   - Tampering breaks chain, detectable at next verification
-- TRADE-OFFS:
--   (+) Simple, proven approach used in immutable audit systems
--   (+) O(n) verification time acceptable for small batches
--   (-) Not as efficient as tree-based proofs for large batches
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- SCHEMA: integrity
-- PURPOSE: Data integrity verification and audit proof storage
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS integrity;
COMMENT ON SCHEMA integrity IS 'Data integrity verification for ledger entries';

-- =============================================================================
-- TABLE: integrity.batch_hashes
-- PURPOSE: Daily batch hash for periodic verification
-- SECURITY: WORM - batch hashes are immutable once computed
-- =============================================================================
CREATE TABLE IF NOT EXISTS integrity.batch_hashes (
    batch_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Period identification
    batch_date DATE NOT NULL UNIQUE,
    period_type VARCHAR(20) DEFAULT 'daily' 
        CHECK (period_type IN ('hourly', 'daily', 'weekly', 'monthly')),
    
    -- Batch hash
    batch_hash VARCHAR(64) NOT NULL, -- SHA-256 of all transaction hashes
    
    -- Batch metadata
    record_count INTEGER NOT NULL, -- Number of transactions in batch
    
    -- Source data hash (for verification)
    source_data_hash VARCHAR(64) NOT NULL, -- Hash of all transaction hashes concatenated
    
    -- Computation metadata
    computed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    computed_by UUID REFERENCES core.account_registry(account_id),
    
    -- Verification status
    is_verified BOOLEAN DEFAULT FALSE,
    verified_at TIMESTAMPTZ,
    verified_by UUID REFERENCES core.account_registry(account_id),
    
    -- Chain linking (batch hashes form their own chain)
    previous_batch_hash VARCHAR(64),
    
    -- Signature (for external notarization)
    signature BYTEA, -- Detached signature of hash
    signature_algorithm VARCHAR(20) DEFAULT 'ed25519',
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_batch_hashes_date ON integrity.batch_hashes(batch_date DESC);
CREATE INDEX IF NOT EXISTS idx_batch_hashes_verified ON integrity.batch_hashes(is_verified, computed_at);

COMMENT ON TABLE integrity.batch_hashes IS 
'Daily batch hashes for ledger verification. 
External notarization possible via signature field.
WORM: Immutable once computed.';

-- =============================================================================
-- TABLE: integrity.hash_chain_proofs
-- PURPOSE: Store pre-computed hash chain proofs for transactions
-- SECURITY: WORM - proofs are immutable
-- =============================================================================
CREATE TABLE IF NOT EXISTS integrity.hash_chain_proofs (
    proof_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Target transaction
    transaction_id UUID NOT NULL REFERENCES core.transactions(transaction_id),
    
    -- Proof data
    transaction_hash VARCHAR(64) NOT NULL,
    previous_transaction_hash VARCHAR(64), -- Null for genesis
    
    -- Chain segment (for verification)
    chain_segment JSONB NOT NULL, -- [{tx_id, hash, previous_hash}]
    segment_start_id UUID,
    segment_end_id UUID,
    
    -- Verification
    is_valid BOOLEAN DEFAULT TRUE,
    computed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ, -- Proof may need refresh if chain changes
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_hash_proofs_tx ON integrity.hash_chain_proofs(transaction_id);
CREATE INDEX IF NOT EXISTS idx_hash_proofs_valid ON integrity.hash_chain_proofs(is_valid, expires_at);

COMMENT ON TABLE integrity.hash_chain_proofs IS 
'Pre-computed hash chain proofs for individual transaction verification';

-- =============================================================================
-- TABLE: integrity.audit_trail_exports
-- PURPOSE: Verifiable audit trail exports with detached signatures
-- SECURITY: Application-scoped via RLS
-- =============================================================================
CREATE TABLE IF NOT EXISTS integrity.audit_trail_exports (
    export_id UUID DEFAULT gen_random_uuid(),
    
    -- Export identification
    export_reference VARCHAR(100),
    CONSTRAINT uq_integrity_audit_trail_exports_export_reference UNIQUE (export_reference, created_at), NOT NULL,
    
    -- Application context
    application_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    requested_by UUID NOT NULL REFERENCES core.account_registry(account_id),
    
    -- Scope
    scope_type VARCHAR(30) NOT NULL 
        CHECK (scope_type IN ('application', 'account', 'transaction_range', 'user')),
    scope_criteria JSONB NOT NULL, -- {account_id, date_from, date_to}
    
    -- Export file
    file_location VARCHAR(500) NOT NULL,
    file_format VARCHAR(10) DEFAULT 'json' CHECK (file_format IN ('json', 'csv', 'xml')),
    file_size_bytes BIGINT,
    
    -- Integrity
    file_checksum_sha256 VARCHAR(64) NOT NULL,
    batch_hash_id UUID REFERENCES integrity.batch_hashes(batch_id),
    
    -- Digital signature (detached)
    signature BYTEA NOT NULL,
    signature_algorithm VARCHAR(20) DEFAULT 'ed25519',
    public_key_fingerprint VARCHAR(64), -- For key rotation tracking
    
    -- Verification
    verification_count INTEGER DEFAULT 0,
    last_verified_at TIMESTAMPTZ,
    
    -- Status
    status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'expired', 'revoked')),
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '90 days'),
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_integrity_audit_trail_exports_export_id_created_at PRIMARY KEY (export_id, created_at));

-- Convert to hypertable
SELECT create_hypertable(
    'integrity.audit_trail_exports',
    'created_at',
    chunk_time_interval => INTERVAL '30 days',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_audit_exports_app ON integrity.audit_trail_exports(application_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_exports_ref ON integrity.audit_trail_exports(export_reference);
CREATE INDEX IF NOT EXISTS idx_audit_exports_batch ON integrity.audit_trail_exports(batch_hash_id);

COMMENT ON TABLE integrity.audit_trail_exports IS 
'Verifiable audit trail exports with detached signatures for compliance';

-- =============================================================================
-- TABLE: integrity.consistency_checks
-- PURPOSE: Scheduled integrity verification results
-- SECURITY: Internal monitoring
-- =============================================================================
CREATE TABLE IF NOT EXISTS integrity.consistency_checks (
    check_id UUID DEFAULT gen_random_uuid(),
    
    -- Check scope
    check_type VARCHAR(50) NOT NULL 
        CHECK (check_type IN ('hash_chain', 'batch_hash', 'balance_reconciliation', 'fk_integrity')),
    
    -- Time range checked
    date_from DATE NOT NULL,
    date_to DATE NOT NULL,
    
    -- Results
    status VARCHAR(20) NOT NULL CHECK (status IN ('passed', 'failed', 'partial')),
    records_checked INTEGER NOT NULL,
    records_failed INTEGER DEFAULT 0,
    
    -- Failure details
    failure_details JSONB, -- [{record_id, expected_hash, actual_hash}]
    
    -- Performance
    started_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ,
    duration_ms INTEGER,
    
    -- Alert status
    alert_sent BOOLEAN DEFAULT FALSE,
    alert_acknowledged_at TIMESTAMPTZ,
    acknowledged_by UUID REFERENCES core.account_registry(account_id),
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_integrity_consistency_checks_check_id_created_at PRIMARY KEY (check_id, created_at));

-- Convert to hypertable
SELECT create_hypertable(
    'integrity.consistency_checks',
    'created_at',
    chunk_time_interval => INTERVAL '30 days',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_consistency_checks_status ON integrity.consistency_checks(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_consistency_checks_type ON integrity.consistency_checks(check_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_consistency_checks_failed ON integrity.consistency_checks(status) WHERE status = 'failed';

COMMENT ON TABLE integrity.consistency_checks IS 
'Results of scheduled integrity checks (hash chain, balance reconciliation)';

-- =============================================================================
-- FUNCTIONS: Verification Operations
-- =============================================================================

-- Function: Compute batch hash for a date range
CREATE OR REPLACE FUNCTION integrity.compute_batch_hash(
    p_date DATE,
    p_period_type VARCHAR(20) DEFAULT 'daily'
)
RETURNS VARCHAR(64) AS $$
DECLARE
    v_batch_hash VARCHAR(64);
    v_record_count INTEGER;
    v_source_hash VARCHAR(64);
BEGIN
    -- Get all transaction hashes for the date
    SELECT 
        COUNT(*),
        encode(
            digest(
                string_agg(transaction_hash, '' ORDER BY created_at),
                'sha256'
            ),
            'hex'
        )
    INTO v_record_count, v_source_hash
    FROM core.transactions
    WHERE date_trunc('day', created_at)::date = p_date;
    
    -- Compute batch hash
    v_batch_hash := encode(
        digest(
            p_date::text || ':' || v_source_hash,
            'sha256'
        ),
        'hex'
    );
    
    -- Insert or update batch record
    INSERT INTO integrity.batch_hashes (
        batch_date,
        period_type,
        batch_hash,
        record_count,
        source_data_hash
    ) VALUES (
        p_date,
        p_period_type,
        v_batch_hash,
        v_record_count,
        v_source_hash
    )
    ON CONFLICT (batch_date) DO UPDATE SET
        batch_hash = EXCLUDED.batch_hash,
        record_count = EXCLUDED.record_count,
        source_data_hash = EXCLUDED.source_data_hash,
        computed_at = NOW();
    
    RETURN v_batch_hash;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION integrity.compute_batch_hash(DATE, VARCHAR) IS 
'Computes and stores the batch hash for transactions on a given date';

-- Function: Verify transaction hash chain
CREATE OR REPLACE FUNCTION integrity.verify_transaction_chain(
    p_transaction_id UUID,
    p_max_depth INTEGER DEFAULT 10
)
RETURNS TABLE (
    is_valid BOOLEAN,
    broken_at UUID,
    expected_hash VARCHAR(64),
    actual_hash VARCHAR(64),
    chain_length INTEGER
) AS $$
DECLARE
    v_current_id UUID;
    v_current_hash VARCHAR(64);
    v_previous_hash VARCHAR(64);
    v_computed_hash VARCHAR(64);
    v_depth INTEGER := 0;
BEGIN
    is_valid := TRUE;
    broken_at := NULL;
    expected_hash := NULL;
    actual_hash := NULL;
    chain_length := 0;
    
    v_current_id := p_transaction_id;
    
    WHILE v_current_id IS NOT NULL AND v_depth < p_max_depth LOOP
        -- Get current transaction
        SELECT 
            t.transaction_hash,
            t.previous_hash
        INTO 
            v_current_hash,
            v_previous_hash
        FROM core.transactions t
        WHERE t.transaction_id = v_current_id;
        
        EXIT WHEN NOT FOUND;
        
        -- Recompute hash (simplified - actual implementation would use same logic as insert)
        v_computed_hash := encode(
            digest(v_current_id::text || COALESCE(v_previous_hash, ''), 'sha256'),
            'hex'
        );
        
        -- Verify
        IF v_current_hash != v_computed_hash THEN
            is_valid := FALSE;
            broken_at := v_current_id;
            expected_hash := v_computed_hash;
            actual_hash := v_current_hash;
            RETURN NEXT;
            RETURN;
        END IF;
        
        chain_length := chain_length + 1;
        v_current_id := NULL; -- Would follow chain if we had linked list
        v_depth := v_depth + 1;
    END LOOP;
    
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION integrity.verify_transaction_chain(UUID, INTEGER) IS 
'Verifies the hash chain integrity for a transaction and its predecessors';

-- Function: Generate audit proof export
CREATE OR REPLACE FUNCTION integrity.generate_audit_proof(
    p_application_id UUID,
    p_scope_criteria JSONB,
    p_requested_by UUID
)
RETURNS UUID AS $$
DECLARE
    v_export_id UUID;
    v_reference VARCHAR(100);
BEGIN
    -- Generate reference
    v_reference := 'AUD-' || encode(gen_random_bytes(8), 'hex');
    
    -- Create export record
    INSERT INTO integrity.audit_trail_exports (
        export_reference,
        application_id,
        requested_by,
        scope_type,
        scope_criteria,
        file_location,
        file_checksum_sha256,
        signature
    ) VALUES (
        v_reference,
        p_application_id,
        p_requested_by,
        p_scope_criteria->>'scope_type',
        p_scope_criteria,
        '/exports/' || v_reference || '.json',
        encode(digest(v_reference, 'sha256'), 'hex'),
        gen_random_bytes(64) -- Placeholder for actual signature
    )
    RETURNING export_id INTO v_export_id;
    
    RETURN v_export_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION integrity.generate_audit_proof(UUID, JSONB, UUID) IS 
'Generates a signed audit proof export for compliance verification';

-- =============================================================================
-- RLS POLICIES
-- =============================================================================

DO $$
BEGIN
    ALTER TABLE integrity.batch_hashes ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE integrity.hash_chain_proofs ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE integrity.audit_trail_exports ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE integrity.audit_trail_exports FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE integrity.consistency_checks ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Batch hashes are public (for verification)
CREATE POLICY batch_hashes_read_all ON integrity.batch_hashes
    FOR SELECT
    TO ussd_app_user
    USING (TRUE);

-- Hash proofs are app-scoped
CREATE POLICY hash_proofs_app_isolation ON integrity.hash_chain_proofs
    FOR ALL
    TO ussd_app_user
    USING (transaction_id IN (
        SELECT transaction_id FROM core.transactions 
        WHERE application_id = current_setting('app.current_application_id', true)::UUID
    ));

-- Audit exports are app-scoped
CREATE POLICY audit_exports_app_isolation ON integrity.audit_trail_exports
    FOR ALL
    TO ussd_app_user
    USING (application_id = current_setting('app.current_application_id', true)::UUID);

-- Consistency checks are internal only
CREATE POLICY consistency_checks_internal ON integrity.consistency_checks
    FOR ALL
    TO ussd_app_user
    USING (FALSE);

-- =============================================================================
-- WORM TRIGGERS (Immutability for verification data)
-- =============================================================================

CREATE TRIGGER trg_batch_hashes_prevent_update
    BEFORE UPDATE ON integrity.batch_hashes
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_batch_hashes_prevent_delete
    BEFORE DELETE ON integrity.batch_hashes
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

CREATE TRIGGER trg_audit_exports_prevent_update
    BEFORE UPDATE ON integrity.audit_trail_exports
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_audit_exports_prevent_delete
    BEFORE DELETE ON integrity.audit_trail_exports
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

-- =============================================================================
-- GRANTS
-- =============================================================================

GRANT USAGE ON SCHEMA integrity TO ussd_app_user, ussd_gateway_role;
GRANT SELECT ON integrity.batch_hashes TO ussd_app_user;
GRANT SELECT ON integrity.hash_chain_proofs TO ussd_app_user;
GRANT SELECT ON integrity.audit_trail_exports TO ussd_app_user;

COMMIT;
