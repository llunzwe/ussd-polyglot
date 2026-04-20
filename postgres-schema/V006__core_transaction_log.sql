-- Migration: V005__core_transaction_log
-- Description: Core table: transaction_log
-- Dependencies: V004
-- Generated: 2026-04-02 16:56:45 UTC

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- USSD KERNEL CORE SCHEMA - TRANSACTION LOG
-- Enterprise-Grade Immutable Ledger System
-- FILENAME:    002_transaction_log.sql
-- SCHEMA:      ussd_core
-- TABLE:       transaction_log
-- DESCRIPTION: The central immutable table where every state change is recorded
--              as an append-only row.
--              CRITICAL: This is the single source of truth for all ledger activity.

-- 1. Added schema creation at top of file
-- 2. Added TimescaleDB extension check
-- 3. Added role creation before RLS policies
-- 4. Fixed primary key to include partition column (required for hypertable)
-- 5. Added missing indexes on FK columns
-- 6. Added IF NOT EXISTS to all CREATE statements

-- Ensure schema exists
CREATE SCHEMA IF NOT EXISTS core;

-- Ensure TimescaleDB extension is available
DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS timescaledb;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TimescaleDB extension handling: %', SQLERRM;
END;
$$;


-- CREATE TABLE: transaction_log (partitioned)

CREATE TABLE IF NOT EXISTS core.transaction_log (
    -- Primary identifier (composite key required for hypertable)
    transaction_id BIGSERIAL,
    
    -- External reference (UUID for global uniqueness)
    transaction_uuid UUID NOT NULL DEFAULT gen_random_uuid(),
    
    -- Idempotency key (client-provided, globally unique)
    idempotency_key VARCHAR(255) NOT NULL,
    
    -- Transaction classification
    transaction_type_id UUID NOT NULL REFERENCES core.transaction_types(type_id) ON DELETE RESTRICT,
    application_id UUID,  -- NULL for system/global transactions
    
    -- Actor information
    initiator_account_id UUID NOT NULL REFERENCES core.account_registry(account_id) ON DELETE RESTRICT,
    on_behalf_of_account_id UUID REFERENCES core.account_registry(account_id) ON DELETE RESTRICT,
    beneficiary_account_id UUID REFERENCES core.account_registry(account_id) ON DELETE RESTRICT,
    
    -- Payload (the actual transaction data)
    payload JSONB NOT NULL,
    payload_encrypted BOOLEAN DEFAULT FALSE,  -- If payload contains encrypted fields
    
    -- Amount information (extracted from payload for indexing)
    amount NUMERIC(20, 8),
    currency VARCHAR(3) CHECK (currency IS NULL OR currency ~ '^[A-Z]{3}$'),
    
    -- Status tracking
    status VARCHAR(20) DEFAULT 'pending' 
        CHECK (status IN ('pending', 'validated', 'posted', 'completed', 'failed', 'reversed')),
    
    -- Related transactions
    parent_transaction_id BIGINT,  -- For child transactions (e.g., fees)
    related_transactions BIGINT[] DEFAULT '{}',  -- Array of related tx IDs
    
    -- Timing
    client_timestamp TIMESTAMPTZ,  -- Timestamp from client device
    committed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    entry_date DATE NOT NULL DEFAULT CURRENT_DATE,  -- Accounting date
    value_date DATE NOT NULL DEFAULT CURRENT_DATE,  -- Funds availability date
    
    -- Audit and trace
    session_id TEXT,
    client_ip INET,
    user_agent TEXT,
    
    -- Processing metadata
    processing_duration_ms INTEGER,  -- Time taken to process
    processor_version VARCHAR(20),  -- Version of processing code
    processor_instance TEXT,  -- Which instance processed the transaction
    
    -- Rejection/failure info (if status != committed)
    rejection_reason TEXT,
    rejection_code VARCHAR(50),
    
    -- Mobile Money Payment Integration (Business receives payments via EcoCash/OneMoney/TeleCash)
    -- Simplified for USSD Business Applications - only payment receiving, not full MM operations
    is_mobile_money BOOLEAN DEFAULT FALSE,
    mobile_money_provider VARCHAR(20) CHECK (mobile_money_provider IN ('ecocash', 'onemoney', 'telecash')),
    mobile_money_operation VARCHAR(30) CHECK (mobile_money_operation IN (
        'payment_received',  -- Customer paid business (merchant payment)
        'payout_sent',       -- Business paid customer (disbursement/refund)
        'refund',            -- Refund to customer
        'reversal'           -- Reversed transaction
    )),
    mobile_money_merchant_code VARCHAR(20),     -- Business's 6-digit merchant code
    mobile_money_wallet_reference VARCHAR(100), -- Provider's transaction reference
    mobile_money_customer_msisdn VARCHAR(20),   -- Customer phone (2637XXXXXXXX)
    mobile_money_details JSONB, -- Provider-specific payment data
    /*
    mobile_money_details JSONB structure (Simplified - Business Payments Only):
    
    Operations: payment_received, payout_sent, refund, reversal
    SETTLEMENT & RECONCILIATION:
    {
        "settlement": {
            "batch_id": "SET-20240115-001",
            "batch_date": "2024-01-15",
            "status": "pending|settled|failed",
            "settlement_amount": 97.50,
            "settlement_date": "2024-01-16"
        },
        "reconciliation": {
            "status": "pending|matched|discrepancy",
            "reference": "RECON-001",
            "variance_amount": 0.00
        }
    }
    */
    
    -- Event Sourcing
    correlation_id VARCHAR(255),
    causation_id UUID,
    event_sequence BIGINT,
    
    -- Audit and Compliance
    compliance_flags JSONB DEFAULT '{}',
    gdpr_classifications TEXT[],
    
    -- Hash Chain (Immutable audit trail integrity)
    previous_hash VARCHAR(64),
    record_hash VARCHAR(64),
    chain_sequence BIGINT DEFAULT nextval('core.global_event_sequence'),
    
    -- Soft Delete (for GDPR right-to-erasure while preserving audit trail)
    is_deleted BOOLEAN DEFAULT FALSE,
    deleted_at TIMESTAMPTZ,
    deleted_by VARCHAR(255),
    deletion_reason TEXT,
    
    -- Partition key (derived)
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE,
    
    -- Constraints
    CONSTRAINT pk_transaction_log PRIMARY KEY (transaction_id, committed_at),
    CONSTRAINT chk_value_date CHECK (value_date >= entry_date - INTERVAL '30 days'),
    CONSTRAINT chk_amount_positive CHECK (amount IS NULL OR amount >= 0)
);

-- CONVERT TO TIMESCALEDB HYPERTABLE (optional - skipped if extension unavailable)
DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS timescaledb;
    PERFORM create_hypertable(
        'core.transaction_log',
        'committed_at',
        chunk_time_interval => INTERVAL '1 day',
        if_not_exists => TRUE
    );
    ALTER TABLE core.transaction_log SET (
        timescaledb.compress,
        timescaledb.compress_segmentby = 'application_id, transaction_type_id'
    );
    PERFORM add_compression_policy('core.transaction_log', INTERVAL '90 days');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TimescaleDB hypertable setup skipped: %', SQLERRM;
END;
$$;

-- INDEXES

-- Time-series queries
CREATE INDEX IF NOT EXISTS idx_transaction_log_committed_at 
    ON core.transaction_log(committed_at DESC);

-- Application queries
CREATE INDEX IF NOT EXISTS idx_transaction_log_app_type_time 
    ON core.transaction_log(application_id, transaction_type_id, committed_at DESC);

-- Status monitoring
CREATE INDEX IF NOT EXISTS idx_transaction_log_status ON core.transaction_log(status) 
    WHERE status IN ('pending', 'failed');

-- JSONB payload search
CREATE INDEX IF NOT EXISTS idx_transaction_log_payload_gin ON core.transaction_log USING gin(payload);

-- UUID lookup (includes partition key for hypertable compatibility)
CREATE UNIQUE INDEX IF NOT EXISTS idx_transaction_log_uuid 
    ON core.transaction_log(transaction_uuid, committed_at);

-- Idempotency key (globally unique, includes partition key)
CREATE UNIQUE INDEX IF NOT EXISTS idx_transaction_log_idempotency 
    ON core.transaction_log(idempotency_key, committed_at);

-- Entry date for accounting queries
CREATE INDEX IF NOT EXISTS idx_transaction_log_entry_date 
    ON core.transaction_log(entry_date DESC);

-- BRIN index for efficient time range scans
CREATE INDEX IF NOT EXISTS idx_transaction_log_brin ON core.transaction_log 
    USING BRIN(committed_at);

-- Mobile money indexes
CREATE INDEX IF NOT EXISTS idx_transaction_log_mobile_money 
    ON core.transaction_log(is_mobile_money, mobile_money_provider, committed_at DESC) 
    WHERE is_mobile_money = TRUE;

CREATE INDEX IF NOT EXISTS idx_transaction_log_correlation 
    ON core.transaction_log(correlation_id) 
    WHERE correlation_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_transaction_log_chain 
    ON core.transaction_log(chain_sequence);

CREATE INDEX IF NOT EXISTS idx_transaction_log_deleted 
    ON core.transaction_log(is_deleted, deleted_at) 
    WHERE is_deleted = TRUE;

-- IMMUTABILITY TRIGGERS

-- Prevent updates on immutable table
DROP TRIGGER IF EXISTS trg_transaction_log_prevent_update ON core.transaction_log;
CREATE TRIGGER trg_transaction_log_prevent_update
    BEFORE UPDATE ON core.transaction_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

-- Prevent deletes on immutable table
DROP TRIGGER IF EXISTS trg_transaction_log_prevent_delete ON core.transaction_log;
CREATE TRIGGER trg_transaction_log_prevent_delete
    BEFORE DELETE ON core.transaction_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

-- TRUNCATE PROTECTION

DROP TRIGGER IF EXISTS trg_transaction_log_prevent_truncate ON core.transaction_log;
CREATE TRIGGER trg_transaction_log_prevent_truncate
    BEFORE TRUNCATE ON core.transaction_log
    FOR EACH STATEMENT
    EXECUTE FUNCTION core.prevent_truncate();

-- IDEMPOTENCY CHECK TRIGGER

CREATE OR REPLACE FUNCTION core.check_idempotency()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_existing_id BIGINT;
    v_existing_uuid UUID;
    v_existing_status VARCHAR(20);
BEGIN
    -- Validate idempotency key format
    IF NEW.idempotency_key IS NULL OR length(trim(NEW.idempotency_key)) < 8 THEN
        RAISE EXCEPTION 'INVALID_IDEMPOTENCY_KEY: Idempotency key must be at least 8 characters',
            USING ERRCODE = 'check_violation',
                  HINT = 'Provide a unique, opaque idempotency key (UUID recommended)';
    END IF;
    
    -- Check if idempotency key already exists
    SELECT transaction_id, transaction_uuid, status 
    INTO v_existing_id, v_existing_uuid, v_existing_status
    FROM core.transaction_log
    WHERE idempotency_key = NEW.idempotency_key
    LIMIT 1;
    
    IF FOUND THEN
        -- Use custom error code for application-level handling (not 'unique_violation' which conflicts with DB constraints)
        RAISE EXCEPTION 'IDEMPOTENCY_VIOLATION: Transaction with key % already exists (ID: %, UUID: %, Status: %)',
            NEW.idempotency_key, v_existing_id, v_existing_uuid, v_existing_status
            USING ERRCODE = 'P0002',  -- Custom application error code
                  HINT = 'This idempotency key has already been used. Use a new unique key for new transactions.',
                  DETAIL = format('Existing transaction: %s, Status: %s', v_existing_uuid, v_existing_status);
    END IF;
    
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_transaction_log_check_idempotency ON core.transaction_log;
CREATE TRIGGER trg_transaction_log_check_idempotency
    BEFORE INSERT ON core.transaction_log
    FOR EACH ROW
    EXECUTE FUNCTION core.check_idempotency();

-- HASH CHAIN COMPUTATION TRIGGER

CREATE OR REPLACE FUNCTION core.compute_transaction_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_previous_hash VARCHAR(64);
    v_lock_obtained BOOLEAN;
BEGIN
    -- CRITICAL FIX: Use advisory lock to prevent race condition in hash chain (see audit FINDING-002)
    SELECT pg_try_advisory_lock(998) INTO v_lock_obtained;  -- Lock ID 998 for transaction_log chain
    
    IF NOT v_lock_obtained THEN
        PERFORM pg_advisory_lock(998);
    END IF;
    
    BEGIN
        -- Get previous hash in chain (now protected by advisory lock)
        SELECT record_hash INTO v_previous_hash
        FROM core.transaction_log
        ORDER BY chain_sequence DESC NULLS LAST
        LIMIT 1;
        
        -- Set previous hash
        NEW.previous_hash := v_previous_hash;
        
        -- Compute record hash
        NEW.record_hash := core.generate_row_hash(
            'core.transaction_log',
            NEW.transaction_uuid,
            jsonb_build_object(
                'transaction_type_id', NEW.transaction_type_id,
                'initiator_account_id', NEW.initiator_account_id,
                'amount', NEW.amount,
                'status', NEW.status,
                'idempotency_key', NEW.idempotency_key
            ),
            NEW.committed_at,
            v_previous_hash
        );
        
        -- Release advisory lock
        PERFORM pg_advisory_unlock(998);
    EXCEPTION WHEN OTHERS THEN
        -- Ensure lock is released even on error
        PERFORM pg_advisory_unlock(998);
        RAISE;
    END;
    
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_transaction_log_compute_hash ON core.transaction_log;
CREATE TRIGGER trg_transaction_log_compute_hash
    BEFORE INSERT ON core.transaction_log
    FOR EACH ROW
    EXECUTE FUNCTION core.compute_transaction_hash();

-- AUDIT CAPTURE TRIGGER

DROP TRIGGER IF EXISTS trg_transaction_log_audit ON core.transaction_log;
CREATE TRIGGER trg_transaction_log_audit
    AFTER INSERT OR UPDATE OR DELETE ON core.transaction_log
    FOR EACH ROW
    EXECUTE FUNCTION audit.auto_capture_changes();

-- RLS POLICIES

-- Create required roles if they don't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ussd_app_user') THEN
        CREATE ROLE ussd_app_user WITH NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ussd_kernel_role') THEN
        CREATE ROLE ussd_kernel_role WITH NOLOGIN;
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Role creation handling: %', SQLERRM;
END;
$$;

-- Enable RLS
DO $$
BEGIN
    ALTER TABLE core.transaction_log ENABLE ROW LEVEL SECURITY;
    ALTER TABLE core.transaction_log FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'RLS not enabled on hypertable: %', SQLERRM;
END $$;

-- Policy: Accounts can view their own transactions
-- AUDIT FIX (FINDING-003): Uses safer helper function to prevent NULL casting issues
CREATE POLICY transaction_log_self_access ON core.transaction_log
    FOR SELECT
    TO ussd_app_user
    USING (
        initiator_account_id = core.get_current_setting_as_uuid('app.current_account_id')
        OR on_behalf_of_account_id = core.get_current_setting_as_uuid('app.current_account_id')
        OR beneficiary_account_id = core.get_current_setting_as_uuid('app.current_account_id')
    );

-- Policy: Application-scoped access
-- AUDIT FIX (FINDING-003): Uses safer helper function for UUID casting
CREATE POLICY transaction_log_app_access ON core.transaction_log
    FOR SELECT
    TO ussd_app_user
    USING (
        application_id = core.get_current_setting_as_uuid('app.current_application_id')
        OR application_id IS NULL
    );

-- Policy: Kernel role has full access
CREATE POLICY transaction_log_kernel_access ON core.transaction_log
    FOR ALL
    TO ussd_kernel_role
    USING (true);

-- ADDITIONAL INDEXES ON FOREIGN KEYS

-- Missing FK indexes for performance
CREATE INDEX IF NOT EXISTS idx_transaction_log_initiator_account 
    ON core.transaction_log(initiator_account_id);
CREATE INDEX IF NOT EXISTS idx_transaction_log_beneficiary_account 
    ON core.transaction_log(beneficiary_account_id);
CREATE INDEX IF NOT EXISTS idx_transaction_log_application 
    ON core.transaction_log(application_id) 
    WHERE application_id IS NOT NULL;

-- TABLE AND COLUMN COMMENTS

COMMENT ON TABLE core.transaction_log IS 
'IMMUTABLE TRANSACTION LEDGER - WORM Compliant
ISO 27001: A.12.4 (Logging and Monitoring), A.8.11 (Data Integrity)
PCI DSS: Req 10 (Audit Trails), Req 11.5 (File Integrity)
GDPR: Art 32 (Security of Processing)

IMPLEMENTATION NOTES:
- Append-only: prevent_update/delete triggers enforce immutability
- Hash chain: record_hash links to previous_hash for tamper detection
- Idempotency: idempotency_key prevents duplicate processing
- Partitioning: TimescaleDB hypertable with daily partitions
- Retention: 7 years for financial compliance

MOBILE MONEY INTEGRATION:
- Supports: payment_received, payout_sent, refund, reversal
- Providers: EcoCash, OneMoney, TeleCash
- NOT an agent system: cash_in/cash_out not supported';

COMMENT ON COLUMN core.transaction_log.transaction_id IS 
    'Auto-incrementing transaction identifier (BIGSERIAL)';
COMMENT ON COLUMN core.transaction_log.transaction_uuid IS 
    'UUID for external references and idempotency';
COMMENT ON COLUMN core.transaction_log.idempotency_key IS 
    'Client-provided unique key to prevent duplicate processing';
COMMENT ON COLUMN core.transaction_log.status IS 
    'Transaction state: pending, validated, posted, completed, failed, reversed';
COMMENT ON COLUMN core.transaction_log.partition_date IS 
    'Partition key for time-based partitioning';

-- PARTITION MANAGEMENT FUNCTION

CREATE OR REPLACE FUNCTION core.create_transaction_partition(
    p_year INTEGER,
    p_month INTEGER
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_partition_name TEXT;
    v_start_date DATE;
    v_end_date DATE;
BEGIN
    v_partition_name := 'transaction_log_' || p_year || '_' || LPAD(p_month::TEXT, 2, '0');
    v_start_date := make_date(p_year, p_month, 1);
    v_end_date := v_start_date + INTERVAL '1 month';
    
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS core.%I PARTITION OF core.transaction_log FOR VALUES FROM (%L) TO (%L)',
        v_partition_name,
        v_start_date,
        v_end_date
    );
    
    RETURN v_partition_name;
END;
$$;

-- END OF FILE

COMMIT;
