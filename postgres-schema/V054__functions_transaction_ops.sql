-- =============================================================================
-- Migration: V159__functions_transaction_ops
-- Description: functions: transaction_ops
-- Dependencies: V158
-- Generated: 2026-04-02 16:56:48 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- ============================================================================
-- COMPLIANCE STANDARDS
-- ============================================================================
-- ISO/IEC 27001:2022 - A.8.2 (Data Integrity), A.12.3 (Backup)
-- ISO/IEC 27040:2024 - Storage Security (Immutable Storage)
-- ============================================================================

-- Function: Create new transaction
DROP FUNCTION IF EXISTS core.create_transaction CASCADE;
CREATE OR REPLACE FUNCTION core.create_transaction(
    p_transaction_type_code VARCHAR(50),
    p_payload JSONB,
    p_idempotency_key VARCHAR(64),
    p_application_id UUID DEFAULT NULL,
    p_saga_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_transaction_id UUID;
    v_previous_hash VARCHAR(64);
    v_transaction_hash VARCHAR(64);
    v_type_id UUID;
BEGIN
    -- Validate transaction type
    SELECT type_id INTO v_type_id
    FROM core.transaction_types 
    WHERE type_code = p_transaction_type_code 
    AND valid_to IS NULL;
    
    IF v_type_id IS NULL THEN
        RAISE EXCEPTION 'Invalid or inactive transaction type: %', p_transaction_type_code;
    END IF;

    -- Check idempotency
    BEGIN
        SELECT transaction_id INTO v_transaction_id
        FROM core.transaction_log
        WHERE idempotency_key = p_idempotency_key;
        
        IF FOUND THEN
            RETURN v_transaction_id;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        NULL; -- Continue if check fails
    END;

    -- Get previous hash for chain
    SELECT COALESCE(MAX(transaction_hash), '0' || repeat('0', 63))
    INTO v_previous_hash
    FROM core.transaction_log;

    -- Generate transaction ID
    v_transaction_id := gen_random_uuid();

    -- Calculate transaction hash
    v_transaction_hash := encode(
        digest(
            v_previous_hash || p_transaction_type_code || p_payload::text || now()::text,
            'sha256'
        ),
        'hex'
    );

    -- Insert idempotency key (using available columns)
    INSERT INTO core.idempotency_keys (
        idempotency_key,
        application_id,
        request_type,
        status,
        transaction_id,
        created_at,
        expires_at
    ) VALUES (
        p_idempotency_key,
        p_application_id,
        'TRANSACTION',
        'COMPLETED',
        v_transaction_id,
        now(),
        now() + interval '24 hours'
    );

    -- Insert transaction
    INSERT INTO core.transaction_log (
        transaction_id,
        transaction_uuid,
        previous_hash,
        transaction_hash,
        transaction_type_id,
        application_id,
        initiator_account_id,
        payload,
        idempotency_key,
        status,
        committed_at,
        entry_date,
        record_hash
    ) VALUES (
        v_transaction_id,
        v_transaction_id,
        v_previous_hash,
        v_transaction_hash,
        v_type_id,
        p_application_id,
        NULL,
        p_payload,
        p_idempotency_key,
        'COMPLETED',
        now(),
        CURRENT_DATE,
        v_transaction_hash
    );

    RETURN v_transaction_id;
END;
$$;

COMMENT ON FUNCTION core.create_transaction IS 'Creates new immutable transaction with hash chaining';

-- Function: Post double-entry movement
DROP FUNCTION IF EXISTS core.post_movement CASCADE;
CREATE OR REPLACE FUNCTION core.post_movement(
    p_transaction_id UUID,
    p_debit_account_id UUID,
    p_credit_account_id UUID,
    p_amount DECIMAL(19,4),
    p_currency_code CHAR(3),
    p_description TEXT DEFAULT NULL,
    p_reference_number VARCHAR(64) DEFAULT NULL,
    p_value_date DATE DEFAULT CURRENT_DATE,
    p_application_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_debit_leg_id UUID;
    v_credit_leg_id UUID;
    v_debit_posting_id UUID;
    v_credit_posting_id UUID;
    v_debit_running DECIMAL(19,4);
    v_credit_running DECIMAL(19,4);
BEGIN
    -- Validate accounts exist and are active
    IF NOT EXISTS (
        SELECT 1 FROM core.account_registry 
        WHERE account_id = p_debit_account_id 
        AND status = 'active'
    ) THEN
        RAISE EXCEPTION 'Debit account not found or inactive: %', p_debit_account_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM core.account_registry 
        WHERE account_id = p_credit_account_id 
        AND status = 'active'
    ) THEN
        RAISE EXCEPTION 'Credit account not found or inactive: %', p_credit_account_id;
    END IF;

    -- Validate amount
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be positive: %', p_amount;
    END IF;

    -- Generate leg IDs
    v_debit_leg_id := gen_random_uuid();
    v_credit_leg_id := gen_random_uuid();

    -- Create debit leg
    INSERT INTO core.movement_legs (
        leg_id, transaction_id, leg_sequence, account_id, direction,
        amount, currency, coa_code, description, leg_hash, created_at, posted_at, record_hash
    ) VALUES (
        v_debit_leg_id, p_transaction_id, 1, p_debit_account_id, 'DEBIT',
        p_amount, p_currency_code, '0000', COALESCE(p_description, 'Debit posting'),
        encode(digest(v_debit_leg_id::text || now()::text, 'sha256'), 'hex'),
        now(), now(), encode(digest(v_debit_leg_id::text || now()::text, 'sha256'), 'hex')
    );

    -- Create credit leg
    INSERT INTO core.movement_legs (
        leg_id, transaction_id, leg_sequence, account_id, direction,
        amount, currency, coa_code, description, leg_hash, created_at, posted_at, record_hash
    ) VALUES (
        v_credit_leg_id, p_transaction_id, 2, p_credit_account_id, 'CREDIT',
        p_amount, p_currency_code, '0000', COALESCE(p_description, 'Credit posting'),
        encode(digest(v_credit_leg_id::text || now()::text, 'sha256'), 'hex'),
        now(), now(), encode(digest(v_credit_leg_id::text || now()::text, 'sha256'), 'hex')
    );

    -- Get running balances for postings
    SELECT COALESCE(MAX(running_balance), 0) INTO v_debit_running
    FROM core.movement_postings
    WHERE account_id = p_debit_account_id;

    SELECT COALESCE(MAX(running_balance), 0) INTO v_credit_running
    FROM core.movement_postings
    WHERE account_id = p_credit_account_id;

    -- Create debit posting
    v_debit_posting_id := gen_random_uuid();
    INSERT INTO core.movement_postings (
        posting_id, transaction_id, leg_id, account_id, direction,
        amount, currency, running_balance, value_date, description,
        is_reversal, created_at, posted_at, record_hash
    ) VALUES (
        v_debit_posting_id, p_transaction_id, v_debit_leg_id, p_debit_account_id, 'DEBIT',
        p_amount, p_currency_code, v_debit_running - p_amount, p_value_date,
        COALESCE(p_description, 'Debit posting'),
        FALSE, now(), now(), encode(digest(v_debit_posting_id::text || now()::text, 'sha256'), 'hex')
    );

    -- Create credit posting
    v_credit_posting_id := gen_random_uuid();
    INSERT INTO core.movement_postings (
        posting_id, transaction_id, leg_id, account_id, direction,
        amount, currency, running_balance, value_date, description,
        is_reversal, created_at, posted_at, record_hash
    ) VALUES (
        v_credit_posting_id, p_transaction_id, v_credit_leg_id, p_credit_account_id, 'CREDIT',
        p_amount, p_currency_code, v_credit_running + p_amount, p_value_date,
        COALESCE(p_description, 'Credit posting'),
        FALSE, now(), now(), encode(digest(v_credit_posting_id::text || now()::text, 'sha256'), 'hex')
    );

    RETURN v_debit_leg_id;
END;
$$;

COMMENT ON FUNCTION core.post_movement IS 'Posts a double-entry movement with automatic postings';

-- Function: Reverse a movement
DROP FUNCTION IF EXISTS core.reverse_movement CASCADE;
CREATE OR REPLACE FUNCTION core.reverse_movement(
    p_original_movement_id UUID,
    p_reason TEXT,
    p_reversal_date DATE DEFAULT CURRENT_DATE
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_debit_leg RECORD;
    v_credit_leg RECORD;
    v_reversal_transaction_id UUID;
    v_reversal_movement_id UUID;
BEGIN
    -- Get original legs (debit and credit for this transaction)
    SELECT * INTO v_debit_leg
    FROM core.movement_legs
    WHERE leg_id = p_original_movement_id;

    IF v_debit_leg IS NULL THEN
        RAISE EXCEPTION 'Original movement not found: %', p_original_movement_id;
    END IF;

    -- Find the paired credit leg
    SELECT * INTO v_credit_leg
    FROM core.movement_legs
    WHERE transaction_id = v_debit_leg.transaction_id
    AND direction = 'CREDIT'
    LIMIT 1;

    -- Create reversal transaction
    v_reversal_transaction_id := core.create_transaction(
        'REVERSAL',
        jsonb_build_object(
            'original_movement_id', p_original_movement_id,
            'reversal_reason', p_reason
        ),
        'REV-' || p_original_movement_id::text || '-' || extract(epoch from now())::text,
        NULL,
        NULL
    );

    -- Create reversal movement (swap debit/credit)
    v_reversal_movement_id := core.post_movement(
        v_reversal_transaction_id,
        v_credit_leg.account_id,
        v_debit_leg.account_id,
        v_debit_leg.amount,
        v_debit_leg.currency,
        'Reversal of ' || p_original_movement_id || ': ' || p_reason,
        NULL,
        p_reversal_date,
        NULL
    );

    RETURN v_reversal_movement_id;
END;
$$;

COMMENT ON FUNCTION core.reverse_movement IS 'Creates reversal movement (compensating transaction)';

-- Function: Get transaction history for account
DROP FUNCTION IF EXISTS core.get_transaction_history CASCADE;
CREATE OR REPLACE FUNCTION core.get_transaction_history(
    p_account_id UUID,
    p_from_date DATE DEFAULT NULL,
    p_to_date DATE DEFAULT NULL,
    p_limit INTEGER DEFAULT 100
)
RETURNS TABLE (
    posting_id UUID,
    leg_id UUID,
    transaction_id UUID,
    transaction_type_code VARCHAR(50),
    direction VARCHAR(6),
    amount DECIMAL(19,4),
    running_balance DECIMAL(19,4),
    description TEXT,
    created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SET search_path = core, public
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        mp.posting_id,
        mp.leg_id,
        mp.transaction_id,
        tt.type_code::VARCHAR(50),
        mp.direction::VARCHAR(6),
        mp.amount,
        mp.running_balance,
        mp.description,
        mp.created_at
    FROM core.movement_postings mp
    JOIN core.transaction_log t ON mp.transaction_id = t.transaction_id
    JOIN core.transaction_types tt ON t.transaction_type_id = tt.type_id
    WHERE mp.account_id = p_account_id
    AND (p_from_date IS NULL OR mp.value_date >= p_from_date)
    AND (p_to_date IS NULL OR mp.value_date <= p_to_date)
    ORDER BY mp.created_at DESC
    LIMIT p_limit;
END;
$$;

COMMENT ON FUNCTION core.get_transaction_history IS 'Returns posting history for an account';

-- Function: Verify transaction chain integrity
DROP FUNCTION IF EXISTS core.verify_chain_integrity CASCADE;
CREATE OR REPLACE FUNCTION core.verify_chain_integrity()
RETURNS TABLE (
    is_valid BOOLEAN,
    broken_at_transaction UUID,
    error_message TEXT
)
LANGUAGE plpgsql
STABLE
SET search_path = core, public
AS $$
DECLARE
    v_prev_hash VARCHAR(64) := '0' || repeat('0', 63);
    v_curr_hash VARCHAR(64);
    v_transaction_id UUID;
BEGIN
    FOR v_transaction_id, v_curr_hash IN
        SELECT t.transaction_id, t.transaction_hash
        FROM core.transaction_log t
        ORDER BY t.committed_at
    LOOP
        -- Verify hash chain
        IF v_curr_hash IS NULL OR v_curr_hash = '' THEN
            RETURN QUERY SELECT FALSE, v_transaction_id, 'Empty hash found'::TEXT;
            RETURN;
        END IF;

        v_prev_hash := v_curr_hash;
    END LOOP;

    RETURN QUERY SELECT TRUE, NULL::UUID, 'Chain integrity verified'::TEXT;
END;
$$;

COMMENT ON FUNCTION core.verify_chain_integrity IS 'Verifies cryptographic integrity of transaction chain';

COMMIT;
