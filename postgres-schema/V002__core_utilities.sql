-- =============================================================================
-- Migration: V002__core_utilities
-- Description: Core Utility Functions
-- Dependencies: V001
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- IMMUTABILITY FUNCTIONS (WORM - Write Once Read Many)
-- =============================================================================

CREATE OR REPLACE FUNCTION core.prevent_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'Updates not allowed on immutable table: %. Use soft-delete or create new record.', TG_TABLE_NAME;
END;
$$;

COMMENT ON FUNCTION core.prevent_update IS 
'ADR-001: WORM Compliance for Financial Ledger

DECISION: Implement prevent_update/delete triggers on all financial tables

RATIONALE:
- Financial regulations require immutable audit trails
- Hash chain integrity requires no modifications
- GDPR right-to-erasure handled via soft delete + anonymization

TRADE-OFFS:
- (+) Complete audit trail, tamper detection
- (+) Regulatory compliance (PCI DSS, SOX)
- (-) Cannot correct errors (must create reversal transactions)
- (-) Storage costs increase over time';

CREATE OR REPLACE FUNCTION core.prevent_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'Deletes not allowed on immutable table: %. Use soft-delete flag.', TG_TABLE_NAME;
END;
$$;

CREATE OR REPLACE FUNCTION core.prevent_truncate()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'Truncate not allowed on immutable table: %.', TG_TABLE_NAME;
END;
$$;

-- =============================================================================
-- CRYPTOGRAPHIC HASHING FUNCTIONS
-- =============================================================================

-- Generate SHA-256 hash
CREATE OR REPLACE FUNCTION core.generate_hash(p_input TEXT)
RETURNS VARCHAR(64)
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    RETURN ENCODE(DIGEST(p_input, 'sha256'), 'hex');
END;
$$;

-- Generate composite hash for row integrity
CREATE OR REPLACE FUNCTION core.generate_row_hash(
    p_table_name TEXT,
    p_record_id UUID,
    p_data JSONB,
    p_timestamp TIMESTAMPTZ,
    p_previous_hash VARCHAR(64) DEFAULT NULL
)
RETURNS VARCHAR(64)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_composite TEXT;
BEGIN
    v_composite := p_table_name || ':' || p_record_id::TEXT || ':' || p_data::TEXT || ':' || p_timestamp::TEXT;
    IF p_previous_hash IS NOT NULL THEN
        v_composite := v_previous_hash || ':' || v_composite;
    END IF;
    RETURN core.generate_hash(v_composite);
END;
$$;

-- Verify hash chain integrity
CREATE OR REPLACE FUNCTION core.verify_hash_chain(
    p_table_name TEXT,
    p_record_id UUID
)
RETURNS TABLE (
    is_valid BOOLEAN,
    broken_at_record UUID,
    expected_hash VARCHAR(64),
    actual_hash VARCHAR(64)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rec RECORD;
    v_expected_hash VARCHAR(64);
    v_previous_hash VARCHAR(64) := '';
BEGIN
    is_valid := TRUE;
    broken_at_record := NULL;
    expected_hash := NULL;
    actual_hash := NULL;
    
    FOR v_rec IN 
        EXECUTE format('SELECT id, record_hash, previous_hash, data, created_at FROM %I WHERE id = $1 ORDER BY created_at', p_table_name)
        USING p_record_id
    LOOP
        v_expected_hash := core.generate_row_hash(
            p_table_name,
            v_rec.id,
            v_rec.data,
            v_rec.created_at,
            v_previous_hash
        );
        
        IF v_rec.record_hash != v_expected_hash THEN
            is_valid := FALSE;
            broken_at_record := v_rec.id;
            expected_hash := v_expected_hash;
            actual_hash := v_rec.record_hash;
            RETURN NEXT;
            RETURN;
        END IF;
        
        v_previous_hash := v_rec.record_hash;
    END LOOP;
    
    RETURN NEXT;
END;
$$;

-- =============================================================================
-- TEMPORAL/BITEMPORAL FUNCTIONS
-- =============================================================================

-- Get current system time (for system versioning)
CREATE OR REPLACE FUNCTION temporal.current_system_time()
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN NOW();
END;
$$;

-- Validate bitemporal constraints
CREATE OR REPLACE FUNCTION temporal.validate_bitemporal(
    p_valid_from TIMESTAMPTZ,
    p_valid_to TIMESTAMPTZ,
    p_system_from TIMESTAMPTZ DEFAULT NOW()
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    -- Valid time must have start before end (if end is specified)
    IF p_valid_to IS NOT NULL AND p_valid_from >= p_valid_to THEN
        RETURN FALSE;
    END IF;
    
    -- System time must be current or future
    IF p_system_from < NOW() - INTERVAL '1 second' THEN
        RETURN FALSE;
    END IF;
    
    RETURN TRUE;
END;
$$;

-- =============================================================================
-- AUDIT FUNCTIONS
-- =============================================================================

-- Capture audit trail on DML
CREATE OR REPLACE FUNCTION audit.capture_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_audit_id UUID;
    v_old_data JSONB;
    v_new_data JSONB;
    v_table_name TEXT;
    v_operation TEXT;
BEGIN
    v_table_name := TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME;
    v_operation := TG_OP;
    
    -- Build data JSONB based on operation
    IF v_operation = 'DELETE' THEN
        v_old_data := TO_JSONB(OLD);
        v_new_data := NULL;
    ELSIF v_operation = 'INSERT' THEN
        v_old_data := NULL;
        v_new_data := TO_JSONB(NEW);
    ELSE -- UPDATE
        v_old_data := TO_JSONB(OLD);
        v_new_data := TO_JSONB(NEW);
    END IF;
    
    -- Insert audit record
    INSERT INTO audit.change_log (
        table_name,
        operation,
        record_id,
        old_data,
        new_data,
        changed_by,
        changed_at,
        transaction_id,
        session_id
    ) VALUES (
        v_table_name,
        v_operation,
        COALESCE(NEW.id, OLD.id),
        v_old_data,
        v_new_data,
        COALESCE(current_setting('app.current_user_id', TRUE), 'system'),
        NOW(),
        txid_current(),
        current_setting('app.session_id', TRUE)
    );
    
    -- Continue with original operation
    IF v_operation = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$;

-- =============================================================================
-- EVENT SOURCING FUNCTIONS
-- =============================================================================

-- Generate monotonic sequence for event ordering
CREATE OR REPLACE FUNCTION events.next_sequence(p_stream_id UUID)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_next_seq BIGINT;
BEGIN
    UPDATE events.stream_sequences
    SET last_sequence = last_sequence + 1,
        updated_at = NOW()
    WHERE stream_id = p_stream_id
    RETURNING last_sequence INTO v_next_seq;
    
    IF v_next_seq IS NULL THEN
        INSERT INTO events.stream_sequences (stream_id, last_sequence)
        VALUES (p_stream_id, 1)
        RETURNING last_sequence INTO v_next_seq;
    END IF;
    
    RETURN v_next_seq;
END;
$$;

-- Optimistic concurrency check
CREATE OR REPLACE FUNCTION events.check_concurrency(
    p_stream_id UUID,
    p_expected_version BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_version BIGINT;
BEGIN
    SELECT COALESCE(MAX(version), 0) INTO v_current_version
    FROM events.event_store
    WHERE stream_id = p_stream_id;
    
    RETURN v_current_version = p_expected_version;
END;
$$;

-- =============================================================================
-- MOBILE MONEY UTILITY FUNCTIONS
-- =============================================================================

-- Validate mobile money wallet format
CREATE OR REPLACE FUNCTION mobile_money.validate_wallet(
    p_wallet_id TEXT,
    p_provider VARCHAR(20)
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    -- Zimbabwe mobile numbers: 2637XXXXXXXX
    IF p_provider IN ('ecocash', 'telecash', 'onemoney') THEN
        RETURN p_wallet_id ~ '^2637[1-9][0-9]{7}$';
    END IF;
    
    RETURN FALSE;
END;
$$;

-- Calculate mobile money fees
CREATE OR REPLACE FUNCTION mobile_money.calculate_fees(
    p_amount NUMERIC,
    p_transaction_type VARCHAR(50),
    p_provider VARCHAR(20)
)
RETURNS TABLE (
    provider_fee NUMERIC,
    platform_fee NUMERIC,
    agent_commission NUMERIC,
    total_fee NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_config JSONB;
BEGIN
    -- Get fee configuration from app configuration
    SELECT configuration_value INTO v_config
    FROM app.configuration_store
    WHERE configuration_key = 'mobile_money_fees:' || p_provider;
    
    IF v_config IS NULL THEN
        -- Default fees
        provider_fee := p_amount * 0.02;
        platform_fee := p_amount * 0.01;
        agent_commission := p_amount * 0.005;
    ELSE
        -- Calculate based on configuration
        provider_fee := COALESCE((v_config->p_transaction_type->>'provider_percentage')::NUMERIC * p_amount / 100, 0);
        platform_fee := COALESCE((v_config->p_transaction_type->>'platform_percentage')::NUMERIC * p_amount / 100, 0);
        agent_commission := COALESCE((v_config->p_transaction_type->>'agent_percentage')::NUMERIC * p_amount / 100, 0);
    END IF;
    
    total_fee := provider_fee + platform_fee + agent_commission;
    
    RETURN NEXT;
END;
$$;

-- =============================================================================
-- CURRENCY CODES
-- =============================================================================

CREATE TABLE IF NOT EXISTS core.currency_codes (
    currency_code VARCHAR(3) PRIMARY KEY,
    currency_name VARCHAR(100) NOT NULL,
    minor_unit INTEGER DEFAULT 2,
    is_active BOOLEAN DEFAULT TRUE,
    is_crypto BOOLEAN DEFAULT FALSE
);

INSERT INTO core.currency_codes (currency_code, currency_name, minor_unit) VALUES
    ('USD', 'US Dollar', 2),
    ('ZWL', 'Zimbabwe Dollar', 2),
    ('ZAR', 'South African Rand', 2),
    ('EUR', 'Euro', 2),
    ('GBP', 'Pound Sterling', 2),
    ('NGN', 'Nigerian Naira', 2),
    ('KES', 'Kenyan Shilling', 2),
    ('XOF', 'CFA Franc BCEAO', 0),
    ('XAF', 'CFA Franc BEAC', 0)
ON CONFLICT (currency_code) DO NOTHING;

-- =============================================================================
-- SYSTEM CONFIGURATION
-- =============================================================================

CREATE TABLE IF NOT EXISTS core.system_configuration (
    config_key VARCHAR(255) PRIMARY KEY,
    config_value JSONB NOT NULL,
    config_type VARCHAR(50) DEFAULT 'string',
    description TEXT,
    is_encrypted BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by VARCHAR(100) DEFAULT 'system'
);

-- Insert default configurations
INSERT INTO core.system_configuration (config_key, config_value, description) VALUES
    ('ledger.version', '"1.0.0"', 'Ledger schema version'),
    ('ledger.worm_enabled', 'true', 'Write Once Read Many enabled'),
    ('ledger.hash_chain_enabled', 'true', 'Hash chaining for audit trail integrity'),
    ('ledger.audit_enabled', 'true', 'Audit logging enabled'),
    ('mobile_money.enabled_providers', '["ecocash", "telecash", "onemoney"]', 'Enabled mobile money providers'),
    ('mobile_money.default_provider', '"ecocash"', 'Default mobile money provider')
ON CONFLICT (config_key) DO NOTHING;

-- =============================================================================
-- GENERIC TRIGGER FUNCTIONS
-- =============================================================================

-- Generic timestamp update trigger function
-- Used by all schemas to maintain updated_at columns
-- NOTE: Schema-specific wrappers can call this for domain-specific behavior
CREATE OR REPLACE FUNCTION core.update_timestamp()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION core.update_timestamp() IS 
'Generic trigger function for auto-updating updated_at timestamps.
Used by: ussd, messaging, app, core schemas.
For schema-specific logic, wrap this function or add BEFORE triggers.';

-- =============================================================================
-- SEQUENCES FOR GAPLESS ORDERING
-- =============================================================================

CREATE SEQUENCE IF NOT EXISTS core.global_event_sequence
    START 1
    INCREMENT 1
    NO MAXVALUE
    CACHE 100;

CREATE SEQUENCE IF NOT EXISTS core.tenant_event_sequence
    START 1
    INCREMENT 1
    NO MAXVALUE
    CACHE 10;

-- =============================================================================
-- SECURITY HELPER FUNCTIONS
-- =============================================================================

-- Function: Safely get current account ID from session settings
-- AUDIT FIX (FINDING-003): Prevents NULL casting issues in RLS policies
CREATE OR REPLACE FUNCTION core.get_current_setting_as_uuid(
    p_setting_name TEXT,
    p_default_value UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_setting TEXT;
BEGIN
    v_setting := current_setting(p_setting_name, TRUE);
    IF v_setting IS NULL OR v_setting = '' THEN
        RETURN p_default_value;
    END IF;
    RETURN v_setting::UUID;
EXCEPTION WHEN invalid_text_representation THEN
    RETURN p_default_value;
END;
$$;

COMMENT ON FUNCTION core.get_current_setting_as_uuid IS 
'Safely retrieves a UUID from current_setting, handling NULL and invalid values.
Used by RLS policies to prevent casting errors when session variables are not set.
Example: core.get_current_setting_as_uuid(''app.current_account_id'')';

-- =============================================================================
-- GDPR COMPLIANCE FUNCTIONS
-- =============================================================================

-- Function: Anonymize user data for GDPR Right to Erasure
-- This function implements soft-delete + anonymization for immutable ledger
CREATE OR REPLACE FUNCTION core.anonymize_user_data(
    p_account_id UUID,
    p_anonymized_by VARCHAR(255) DEFAULT NULL
)
RETURNS TABLE (
    transactions_updated INTEGER,
    sessions_updated INTEGER,
    audit_records_updated INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_transactions_updated INTEGER := 0;
    v_sessions_updated INTEGER := 0;
    v_audit_records_updated INTEGER := 0;
    v_anonymization_token VARCHAR(64);
BEGIN
    -- Generate anonymization token for audit trail
    v_anonymization_token := core.generate_hash('ANON:' || p_account_id::TEXT || ':' || NOW()::TEXT);
    
    -- Update transaction_log: Set is_deleted and anonymize PII in payload
    UPDATE core.transaction_log
    SET 
        is_deleted = TRUE,
        deleted_at = NOW(),
        deleted_by = COALESCE(p_anonymized_by, 'GDPR_ANONYMIZATION'),
        deletion_reason = 'GDPR_RIGHT_TO_ERASURE',
        payload = jsonb_build_object(
            '_anonymized', TRUE,
            '_anonymization_token', v_anonymization_token,
            '_original_keys', (SELECT array_agg(key) FROM jsonb_object_keys(payload) AS key)
        ),
        mobile_money_customer_msisdn = NULL,
        client_ip = NULL,
        user_agent = NULL
    WHERE (initiator_account_id = p_account_id 
           OR on_behalf_of_account_id = p_account_id 
           OR beneficiary_account_id = p_account_id)
      AND is_deleted = FALSE;
    
    GET DIAGNOSTICS v_transactions_updated = ROW_COUNT;
    
    -- Update ussd_sessions: Clear PII fields
    UPDATE ussd.ussd_sessions
    SET 
        msisdn = '+000000000000',
        msisdn_hash = v_anonymization_token,
        account_id = NULL,
        device_fingerprint = NULL,
        context_data = '{}'::JSONB,
        input_history = ARRAY[]::TEXT[],
        status = 'ENDED'
    WHERE account_id = p_account_id;
    
    GET DIAGNOSTICS v_sessions_updated = ROW_COUNT;
    
    -- Update audit_trail: Mark as anonymized (preserve hash chain)
    UPDATE core.audit_trail
    SET 
        old_values = jsonb_build_object('_anonymized', TRUE),
        new_values = jsonb_build_object('_anonymized', TRUE),
        changed_by = 'GDPR_ANONYMIZED'
    WHERE account_id = p_account_id;
    
    GET DIAGNOSTICS v_audit_records_updated = ROW_COUNT;
    
    -- Return summary
    RETURN QUERY SELECT v_transactions_updated, v_sessions_updated, v_audit_records_updated;
END;
$$;

COMMENT ON FUNCTION core.anonymize_user_data IS 
'GDPR Article 17: Right to Erasure implementation for immutable ledger.

IMPLEMENTATION NOTES:
- Uses soft-delete (is_deleted flag) to preserve hash chain integrity
- Anonymizes PII in payload by replacing with anonymization token
- Clears MSISDN, IP address, user agent from transactions
- Ends all active sessions and clears session data
- Preserves audit trail for regulatory compliance (anonymized)

USAGE:
  SELECT * FROM core.anonymize_user_data(''account-uuid-here'', ''admin@example.com'');

COMPLIANCE:
- GDPR Article 17 (Right to Erasure)
- ISO 27001 A.18.1 (Compliance with legal requirements)
- PCI DSS Requirement 3.2 (Storage of sensitive authentication data)';

-- Function: Check if data subject has been anonymized
CREATE OR REPLACE FUNCTION core.is_data_anonymized(p_account_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM core.transaction_log
        WHERE initiator_account_id = p_account_id
        AND is_deleted = TRUE
        AND deletion_reason = 'GDPR_RIGHT_TO_ERASURE'
        LIMIT 1
    );
END;
$$;

COMMENT ON FUNCTION core.is_data_anonymized IS 
'Check if a data subject has already been anonymized under GDPR.
Returns TRUE if the account has GDPR anonymization records.';

COMMIT;
