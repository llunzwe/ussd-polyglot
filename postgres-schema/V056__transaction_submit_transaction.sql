-- =============================================================================
-- Migration: V176__transaction_submit_transaction
-- Description: transaction: submit_transaction
-- Dependencies: V175
-- Note: Depends on validate_transaction_payload function
-- Generated: 2026-04-02 16:56:48 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- USSD KERNEL CORE SCHEMA - TRANSACTION FUNCTIONS
-- Enterprise-Grade Immutable Ledger System
-- =============================================================================
-- FILENAME:    000_submit_transaction.sql
-- SCHEMA:      core
-- CATEGORY:    Transaction Functions
-- DESCRIPTION: Main transaction submission entry point with idempotency,
--              validation, hash chain computation, and atomic commit.
-- =============================================================================

/*
================================================================================
COMPLIANCE FRAMEWORK
================================================================================

ISO/IEC 27001:2022 (Information Security Management Systems)
├── A.8.1 User endpoint devices - Transaction origin verification
├── A.8.5 Secure authentication - Transaction authorization
├── A.12.4 Logging and monitoring - Transaction monitoring
└── A.16.1 Management of information security incidents - Fraud detection

ISO/IEC 27040:2024 (Storage Security)
├── Atomic commit: All-or-nothing transaction semantics
├── Hash chain: Immediate chain computation on submit
├── Immutable record: Write-once transaction log
└── Audit trail: Complete submission audit

PCI DSS 4.0
├── Requirement 3: Cardholder data protection
├── Requirement 4: Encryption in transit
├── Requirement 10: Access logging
└── Requirement 11: Security testing

================================================================================
ENTERPRISE POSTGRESQL CODING PRACTICES
================================================================================

1. TRANSACTION ISOLATION
   - SERIALIZABLE for complex transactions
   - READ COMMITTED for simple reads
   - Advisory locks for sequence generation

2. ERROR HANDLING
   - Specific exception handling
   - Rollback on failure
   - Detailed error logging
   - Client-friendly error messages

3. IDEMPOTENCY
   - Key validation before processing
   - Duplicate detection
   - Cached responses for duplicates

================================================================================
SECURITY IMPLEMENTATION NOTES
================================================================================

SUBMISSION SECURITY:
- Input validation
- Rate limiting
- Fraud scoring
- Geo-location checks

AUTHORIZATION:
- Account permission verification
- Transaction type authorization
- Limit checking
- Dual authorization for high-value

================================================================================
PERFORMANCE OPTIMIZATION ANNOTATIONS
================================================================================

THROUGHPUT:
- Connection pooling
- Prepared statements
- Batch submission support
- Async processing for non-critical path

================================================================================
AUDIT AND LOGGING REQUIREMENTS
================================================================================

AUDIT EVENTS:
- TRANSACTION_SUBMITTED
- TRANSACTION_VALIDATED
- TRANSACTION_ACCEPTED
- TRANSACTION_REJECTED
- DUPLICATE_DETECTED

RETENTION: 7 years
================================================================================
*/

-- Create transaction submission results type
DROP TYPE IF EXISTS core.transaction_result CASCADE;
CREATE TYPE core.transaction_result AS (
    success BOOLEAN,
    transaction_id UUID,
    transaction_reference VARCHAR(50),
    status VARCHAR(20),
    message TEXT,
    chain_sequence BIGINT,
    account_sequence BIGINT,
    current_hash VARCHAR(64)
);

-- =============================================================================
-- STUB FUNCTIONS: These are referenced by submit_transaction and must exist
-- PRODUCTION NOTE: These are minimal implementations. Replace with full logic.
-- =============================================================================

-- Stub: Validate transaction payload
-- PRODUCTION FIX: Added stub function referenced in line 210
CREATE OR REPLACE FUNCTION core.validate_transaction_payload(
    p_transaction_type_id UUID,
    p_initiator_account_id UUID,
    p_beneficiary_account_id UUID,
    p_amount NUMERIC,
    p_currency VARCHAR(3),
    p_payload JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Minimal validation - replace with full business logic
    IF p_amount < 0 THEN
        RETURN jsonb_build_object('valid', false, 'error', 'Amount cannot be negative');
    END IF;
    
    IF p_currency !~ '^[A-Z]{3}$' THEN
        RETURN jsonb_build_object('valid', false, 'error', 'Invalid currency code');
    END IF;
    
    RETURN jsonb_build_object('valid', true);
END;
$$;

-- Stub: Get previous hash for account chain
-- PRODUCTION FIX: Added stub function referenced in line 259
CREATE OR REPLACE FUNCTION core.get_previous_hash(
    p_account_id UUID,
    p_application_id UUID
)
RETURNS TABLE (previous_hash VARCHAR(64), chain_sequence BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Get the last transaction hash for this account
    RETURN QUERY
    SELECT 
        COALESCE(tl.record_hash, '')::VARCHAR(64) as previous_hash,
        COALESCE(tl.chain_sequence, 0) as chain_sequence
    FROM core.transaction_log tl
    WHERE tl.initiator_account_id = p_account_id
       OR tl.beneficiary_account_id = p_account_id
    ORDER BY tl.chain_sequence DESC NULLS LAST
    LIMIT 1;
    
    -- If no previous transaction, return empty
    IF NOT FOUND THEN
        RETURN QUERY SELECT ''::VARCHAR(64), 0::BIGINT;
    END IF;
END;
$$;

-- Stub: Get global previous hash
-- PRODUCTION FIX: Added stub function referenced in line 263
CREATE OR REPLACE FUNCTION core.get_global_previous_hash()
RETURNS TABLE (previous_hash VARCHAR(64), chain_sequence BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Get the global last transaction hash
    RETURN QUERY
    SELECT 
        COALESCE(tl.record_hash, '')::VARCHAR(64) as previous_hash,
        COALESCE(tl.chain_sequence, 0) as chain_sequence
    FROM core.transaction_log tl
    ORDER BY tl.chain_sequence DESC NULLS LAST
    LIMIT 1;
    
    -- If no previous transaction, return empty
    IF NOT FOUND THEN
        RETURN QUERY SELECT ''::VARCHAR(64), 0::BIGINT;
    END IF;
END;
$$;

-- =============================================================================
-- Create submit_transaction function
-- DESCRIPTION: Main entry point for transaction submission
-- PRIORITY: CRITICAL
-- SECURITY: SECURITY DEFINER - needs broad table access
-- =============================================================================
DROP FUNCTION IF EXISTS core.submit_transaction CASCADE;
CREATE OR REPLACE FUNCTION core.submit_transaction(
    p_transaction_type_id UUID,
    p_application_id UUID,
    p_initiator_account_id UUID,
    p_beneficiary_account_id UUID DEFAULT NULL,
    p_amount NUMERIC DEFAULT 0,
    p_currency VARCHAR(3) DEFAULT 'USD',
    p_payload JSONB DEFAULT '{}',
    p_entry_date DATE DEFAULT CURRENT_DATE,
    p_idempotency_key VARCHAR(100) DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'
)
RETURNS core.transaction_result
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_result core.transaction_result;
    v_transaction_id UUID;
    v_transaction_reference VARCHAR(50);
    v_validation_result JSONB;
    v_prev_hash_result RECORD;
    v_global_prev RECORD;
    v_computed_hash BYTEA;
    v_account_seq BIGINT;
    v_chain_seq BIGINT;
BEGIN
    -- CRITICAL FIX: Check idempotency key with advisory lock to prevent race conditions
    IF p_idempotency_key IS NOT NULL THEN
        -- Acquire advisory lock based on idempotency key hash
        -- This prevents concurrent transactions with the same idempotency key
        PERFORM pg_advisory_xact_lock(hashtext(p_idempotency_key || ':' || p_application_id::TEXT));
        
        SELECT transaction_id, transaction_reference, status, transaction_hash, chain_sequence, account_sequence
        INTO v_transaction_id, v_transaction_reference, v_result.status, v_result.current_hash, v_result.chain_sequence, v_result.account_sequence
        FROM core.transaction_log
        WHERE idempotency_key = p_idempotency_key
          AND application_id = p_application_id
        LIMIT 1;
        
        IF FOUND THEN
            -- Duplicate detected
            v_result.success := true;
            v_result.transaction_id := v_transaction_id;
            v_result.transaction_reference := v_transaction_reference;
            v_result.message := 'Duplicate transaction detected - returning existing record';
            
            INSERT INTO core.audit_trail (
                audit_reference,
                audit_event,
                audit_category,
                audit_level,
                action,
                action_status,
                table_name,
                record_id,
                new_data,
                actor_name
            ) VALUES (
                'AUTO-' || substr(md5(random()::text), 1, 16),
                'DUPLICATE_DETECTED',
                'DATA_ACCESS',
                'INFO',
                'READ',
                'SUCCESS',
                'transaction_log',
                v_transaction_id::text,
                jsonb_build_object(
                    'idempotency_key', p_idempotency_key,
                    'application_id', p_application_id
                ),
                current_user
            );
            
            RETURN v_result;
        END IF;
    END IF;
    
    -- Validate payload
    v_validation_result := core.validate_transaction_payload(
        p_transaction_type_id,
        p_application_id,
        p_initiator_account_id,
        p_beneficiary_account_id,
        p_amount,
        p_currency,
        p_payload
    );
    
    IF NOT (v_validation_result->>'valid')::BOOLEAN THEN
        v_result.success := false;
        v_result.status := 'REJECTED';
        v_result.message := v_validation_result->>'error_message';
        
        INSERT INTO core.audit_trail (
            audit_reference,
            audit_event,
            audit_category,
            audit_level,
            action,
            action_status,
            table_name,
            new_data,
            actor_name
        ) VALUES (
            'AUTO-' || substr(md5(random()::text), 1, 16),
            'TRANSACTION_REJECTED',
            'DATA_CHANGE',
            'WARNING',
            'VALIDATE',
            'FAILURE',
            'transaction_log',
            jsonb_build_object(
                'reason', v_validation_result->>'error_message',
                'validation_errors', v_validation_result->'errors'
            ),
            current_user
        );
        
        RETURN v_result;
    END IF;
    
    -- Generate transaction reference
    v_transaction_reference := 'TXN-' || to_char(CURRENT_TIMESTAMP, 'YYYYMMDD') || '-' || 
                               substring(md5(random()::text), 1, 8);
    
    -- Get previous hash for account chain
    SELECT * INTO v_prev_hash_result
    FROM core.get_previous_hash(p_initiator_account_id, p_application_id);
    
    -- Get previous hash for global chain
    SELECT * INTO v_global_prev
    FROM core.get_global_previous_hash();
    
    v_account_seq := v_prev_hash_result.account_sequence + 1;
    v_chain_seq := v_global_prev.chain_sequence + 1;
    
    -- Compute transaction hash
    v_computed_hash := core.compute_transaction_hash(
        p_transaction_type_id,
        p_application_id,
        p_payload,
        p_initiator_account_id,
        p_beneficiary_account_id,
        p_amount,
        p_currency,
        p_entry_date,
        v_prev_hash_result.previous_hash
    );
    
    -- Insert transaction
    INSERT INTO core.transaction_log (
        transaction_type_id,
        application_id,
        transaction_reference,
        idempotency_key,
        initiator_account_id,
        beneficiary_account_id,
        amount,
        currency,
        payload,
        entry_date,
        previous_hash,
        transaction_hash,
        account_sequence,
        chain_sequence,
        previous_global_hash,
        status,
        metadata
    ) VALUES (
        p_transaction_type_id,
        p_application_id,
        v_transaction_reference,
        p_idempotency_key,
        p_initiator_account_id,
        p_beneficiary_account_id,
        p_amount,
        p_currency,
        p_payload,
        p_entry_date,
        v_prev_hash_result.previous_hash,
        v_computed_hash,
        v_account_seq,
        v_chain_seq,
        v_global_prev.previous_hash,
        'COMPLETED',
        p_metadata
    )
    RETURNING transaction_id INTO v_transaction_id;
    
    -- Build result
    v_result.success := true;
    v_result.transaction_id := v_transaction_id;
    v_result.transaction_reference := v_transaction_reference;
    v_result.status := 'COMPLETED';
    v_result.message := 'Transaction submitted successfully';
    v_result.chain_sequence := v_chain_seq;
    v_result.account_sequence := v_account_seq;
    v_result.current_hash := encode(v_computed_hash, 'hex');
    
    -- Log success
    INSERT INTO core.audit_trail (
        audit_reference,
        audit_event,
        audit_category,
        audit_level,
        action,
        action_status,
        table_name,
        record_id,
        new_data,
        actor_name
    ) VALUES (
        'AUTO-' || substr(md5(random()::text), 1, 16),
        'TRANSACTION_ACCEPTED',
        'DATA_CHANGE',
        'INFO',
        'CREATE',
        'SUCCESS',
        'transaction_log',
        v_transaction_id::text,
        jsonb_build_object(
            'transaction_reference', v_transaction_reference,
            'chain_sequence', v_chain_seq,
            'account_sequence', v_account_seq,
            'hash', encode(v_computed_hash, 'hex')
        ),
        current_user
    );
    
    RETURN v_result;
EXCEPTION
    WHEN OTHERS THEN
        v_result.success := false;
        v_result.status := 'FAILED';
        v_result.message := SQLERRM;
        
        INSERT INTO core.audit_trail (
            audit_reference,
            audit_event,
            audit_category,
            audit_level,
            action,
            action_status,
            table_name,
            new_data,
            actor_name
        ) VALUES (
            'AUTO-' || substr(md5(random()::text), 1, 16),
            'TRANSACTION_FAILED',
            'SYSTEM',
            'ERROR',
            'CREATE',
            'FAILURE',
            'transaction_log',
            jsonb_build_object(
                'error', SQLERRM,
                'sqlstate', SQLSTATE
            ),
            current_user
        );
        
        RETURN v_result;
END;
$$;

COMMENT ON FUNCTION core.submit_transaction IS 'Main entry point for transaction submission with idempotency and hash chain';

/*
================================================================================
MIGRATION CHECKLIST:
□ Create submit_transaction function
□ Create generate_transaction_reference function
□ Create process_transaction function
□ Create bulk_submit_transactions function
□ Test idempotency key handling
□ Test hash chain computation on submit
□ Test validation failure handling
□ Benchmark single transaction submission
□ Benchmark bulk submission
□ Document transaction submission API
================================================================================
*/

-- =============================================================================
-- END OF FILE
-- =============================================================================

COMMIT;
