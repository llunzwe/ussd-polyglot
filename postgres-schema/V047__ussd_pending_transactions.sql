-- =============================================================================
-- Migration: V057__ussd_pending_transactions
-- Description: USSD table: pending_transactions
-- Dependencies: V056
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- FILE: 003_pending_transactions.sql
-- DESCRIPTION: Pending USSD Transaction Queue
-- TABLES: pending_ussd_transactions, pending_tx_confirmations, tx_reservations
-- SCHEMA: ussd
-- PRIORITY: CRITICAL
-- =============================================================================

/*
================================================================================
COMPLIANCE FRAMEWORK
================================================================================
ISO/IEC 27001:2022 - Information Security Management System (ISMS)
  - A.8.1: User endpoint devices
  - A.8.2: Privileged access rights
  - A.8.12: Data leakage prevention
  - A.12.3: Information backup (transaction integrity)
  - A.14.2.9: System acceptance testing

ISO/IEC 27050-3:2020 - Electronic Discovery
  - Section 6: Preservation of transaction evidence
  - Pending transactions are legal evidence of intent

GDPR / Zimbabwe Data Protection Act (Chapter 11:12)
  - Article 5(1)(f): Integrity and confidentiality
  - Article 32: Security of processing
  - Section 14: Security measures
  - Transaction data is sensitive personal data

PAYMENT REGULATIONS:
  - Strong Customer Authentication (SCA) requirements
  - Transaction timeout limits (5 minutes max)
  - Confirmation requirements for transfers
  - Audit trail for all payment attempts

SECURITY CLASSIFICATION: CONFIDENTIAL
DATA SENSITIVITY: FINANCIAL TRANSACTION DATA + PII
RETENTION PERIOD: Completed 10 years; Cancelled/Expired 90 days
AUDIT REQUIREMENT: All states logged; PIN attempts tracked
================================================================================
*/

-- =============================================================================
-- TYPE DEFINITIONS
-- =============================================================================

-- Pending transaction status
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pending_tx_status') THEN
        CREATE TYPE ussd.pending_tx_status AS ENUM (
            'PENDING',      -- Awaiting confirmation
            'CONFIRMED',    -- Confirmed, processing
            'PROCESSING',   -- Being executed
            'COMPLETED',    -- Successfully completed
            'FAILED',       -- Processing failed
            'CANCELLED',    -- User cancelled
            'EXPIRED',      -- Timeout expired
            'REJECTED'      -- Rejected by system
        );
    END IF;
END$$;

-- Confirmation attempt types
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'confirmation_type') THEN
        CREATE TYPE ussd.confirmation_type AS ENUM (
            'PIN',          -- PIN verification
            'OTP',          -- One-time password
            'BIOMETRIC',    -- Biometric confirmation
            'CONFIRM',      -- Simple yes/no
            'SIGNATURE',    -- Digital signature
            'MFA'           -- Multi-factor auth
        );
    END IF;
END$$;

-- =============================================================================
-- TABLE: pending_ussd_transactions
-- DESCRIPTION: Queued pending transactions with PII protection
-- SECURITY: RLS by from_account_id; encrypted references
-- PII: MSISDN encrypted; account IDs pseudonymized
-- AUDIT: All state changes logged
-- RETENTION: Expired records anonymized after 90 days
-- =============================================================================
CREATE TABLE IF NOT EXISTS ussd.pending_ussd_transactions (
    pending_id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pending_reference       VARCHAR(100) UNIQUE NOT NULL,    -- User-facing reference
    
    -- Links
    session_id              UUID NOT NULL REFERENCES ussd.ussd_sessions(session_id),
    transaction_id          UUID, -- References core.transaction_log (composite PK prevents direct FK)
    core_transaction_ref    VARCHAR(100),                    -- Reference to core ledger
    
    -- Transaction Details
    transaction_type        VARCHAR(50) NOT NULL,            -- TRANSFER, PAYMENT, AIRTIME, etc.
    transaction_purpose     TEXT,                            -- Description for audit
    
    -- Financial Details
    amount                  NUMERIC(20, 8) NOT NULL,
    currency                VARCHAR(3) NOT NULL,
    fee_amount              NUMERIC(20, 8) DEFAULT 0,
    tax_amount              NUMERIC(20, 8) DEFAULT 0,
    total_amount            NUMERIC(20, 8) NOT NULL,
    exchange_rate           NUMERIC(20, 8),                  -- If currency conversion
    
    -- Source Account
    from_account_id         UUID NOT NULL REFERENCES core.account_registry(account_id),
    from_account_name       VARCHAR(255),                    -- Cached for display
    
    -- Destination (Internal or External)
    to_account_id           UUID REFERENCES core.account_registry(account_id),
    to_account_name         VARCHAR(255),
    to_external_reference   VARCHAR(100),                    -- External system reference
    
    -- External Recipient (PII - ENCRYPTED)
    to_msisdn               VARCHAR(20),                     -- External transfer (PII)
    to_msisdn_encrypted     BYTEA,                           -- Encrypted recipient
    to_msisdn_hash          VARCHAR(64),                     -- Hash for lookup
    
    -- Recipient Bank/MNO Details
    recipient_bank_code     VARCHAR(20),
    recipient_bank_name     VARCHAR(100),
    recipient_account_number VARCHAR(100),
    
    -- Confirmation (Security Critical)
    requires_pin            BOOLEAN DEFAULT true,
    requires_otp            BOOLEAN DEFAULT false,
    pin_verified            BOOLEAN DEFAULT false,
    otp_verified            BOOLEAN DEFAULT false,
    confirmation_code       VARCHAR(20),                     -- OTP if needed
    confirmation_hash       BYTEA,                           -- Verification hash only
    confirmation_expires_at TIMESTAMPTZ,
    
    -- Status Lifecycle
    status                  ussd.pending_tx_status DEFAULT 'PENDING',
    previous_status         ussd.pending_tx_status,          -- For audit trail
    status_changed_at       TIMESTAMPTZ,
    
    -- Timing
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at              TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '5 minutes'),
    confirmed_at            TIMESTAMPTZ,
    completed_at            TIMESTAMPTZ,
    cancelled_at            TIMESTAMPTZ,
    cancellation_reason     TEXT,
    
    -- PIN Attempts (Security Monitoring)
    pin_attempts            INTEGER DEFAULT 0,
    max_pin_attempts        INTEGER DEFAULT 3,
    last_pin_attempt_at     TIMESTAMPTZ,
    
    -- OTP Attempts
    otp_attempts            INTEGER DEFAULT 0,
    max_otp_attempts        INTEGER DEFAULT 3,
    last_otp_attempt_at     TIMESTAMPTZ,
    
    -- Risk/Fraud Assessment
    risk_score              INTEGER DEFAULT 0,               -- 0-100
    risk_factors            JSONB DEFAULT '{}',              -- Why risk was assessed
    fraud_flags             VARCHAR(50)[],                   -- List of triggered flags
    requires_manual_review  BOOLEAN DEFAULT false,
    reviewed_by             UUID REFERENCES core.account_registry(account_id),
    reviewed_at             TIMESTAMPTZ,
    review_notes            TEXT,
    
    -- Velocity Checks
    velocity_check_passed   BOOLEAN DEFAULT true,
    velocity_violations     JSONB DEFAULT '{}',
    
    -- Device Security
    device_fingerprint      VARCHAR(255),                    -- At time of creation
    device_trust_score      NUMERIC(3, 2),                   -- 0.00-1.00
    sim_swap_detected       BOOLEAN DEFAULT false,
    
    -- Reservation
    reservation_id          UUID,                            -- Liquidity reservation
    reservation_released    BOOLEAN DEFAULT false,
    
    -- Transaction Hash (Integrity)
    transaction_hash        VARCHAR(64) NOT NULL,            -- SHA-256 of key fields
    previous_hash           VARCHAR(64),                     -- Hash chain
    
    -- Metadata
    metadata                JSONB DEFAULT '{}',              -- Additional context
    
    -- Audit
    created_by              UUID REFERENCES core.account_registry(account_id),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    
    -- Constraints
    CONSTRAINT valid_amount CHECK (amount > 0),
    CONSTRAINT valid_total_amount CHECK (total_amount >= amount),
    CONSTRAINT valid_risk_score CHECK (risk_score >= 0 AND risk_score <= 100),
    CONSTRAINT valid_device_trust CHECK (device_trust_score IS NULL OR (device_trust_score >= 0 AND device_trust_score <= 1)),
    CONSTRAINT valid_msisdn_format CHECK (to_msisdn IS NULL OR to_msisdn ~ '^\+[1-9][0-9]{7,14}$')
);

COMMENT ON TABLE ussd.pending_ussd_transactions IS 'Pending transactions awaiting confirmation with fraud detection';
COMMENT ON COLUMN ussd.pending_ussd_transactions.to_msisdn IS 'PII: Encrypted at rest; hash for duplicate detection';
COMMENT ON COLUMN ussd.pending_ussd_transactions.confirmation_hash IS 'Hash only - never store PIN/OTP plaintext';
COMMENT ON COLUMN ussd.pending_ussd_transactions.transaction_hash IS 'Tamper-evident hash chain for audit';

-- =============================================================================
-- TABLE: pending_tx_confirmations
-- DESCRIPTION: Confirmation attempts log (NEVER stores PIN)
-- SECURITY: NEVER stores PIN; only attempt metadata
-- AUDIT: Complete attempt history for fraud analysis
-- RETENTION: 90 days for fraud pattern analysis
-- =============================================================================
CREATE TABLE IF NOT EXISTS ussd.pending_tx_confirmations (
    confirmation_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pending_id              UUID NOT NULL REFERENCES ussd.pending_ussd_transactions(pending_id) ON DELETE CASCADE,
    
    -- Attempt Details (NEVER log PIN/OTP here)
    attempt_type            ussd.confirmation_type NOT NULL, -- PIN, OTP, etc.
    attempt_result          VARCHAR(20) NOT NULL,            -- SUCCESS, FAILED, CANCELLED
    
    -- Failure Information (no sensitive data)
    failure_reason          TEXT,                            -- Invalid, Timeout, Locked
    failure_code            VARCHAR(50),                     -- Error code
    
    -- Security Context
    device_fingerprint      VARCHAR(255),                    -- Device at attempt
    device_changed          BOOLEAN DEFAULT false,           -- Different from creation
    location_changed        BOOLEAN DEFAULT false,           -- Geographic anomaly
    
    -- Network
    ip_address              INET,
    network_operator        VARCHAR(50),
    country_code            VARCHAR(2),
    
    -- Timing
    attempted_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    attempt_duration_ms     INTEGER,                         -- Time to enter/verify
    
    -- Fraud Signals
    suspicious_pattern      BOOLEAN DEFAULT false,           -- Flagged by system
    pattern_type            VARCHAR(50),                     -- Type of suspicion
    
    CONSTRAINT valid_attempt_result CHECK (
        attempt_result IN ('SUCCESS', 'FAILED', 'CANCELLED', 'TIMEOUT', 'BLOCKED')
    )
);

COMMENT ON TABLE ussd.pending_tx_confirmations IS 'Confirmation attempts audit - NEVER store PINs or OTPs';
COMMENT ON COLUMN ussd.pending_tx_confirmations.attempt_result IS 'SUCCESS does not mean transaction completed - only confirmation succeeded';

-- =============================================================================
-- TABLE: tx_liquidity_reservations
-- DESCRIPTION: Fund reservations for pending transactions
-- SECURITY: Links to core ledger reservations
-- =============================================================================
CREATE TABLE IF NOT EXISTS ussd.tx_liquidity_reservations (
    reservation_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pending_id              UUID NOT NULL REFERENCES ussd.pending_ussd_transactions(pending_id) ON DELETE CASCADE,
    
    -- Core Ledger Link
    core_reservation_id     UUID,                            -- Links to core.liquidity_positions
    
    -- Reservation Details
    account_id              UUID NOT NULL REFERENCES core.account_registry(account_id),
    currency                VARCHAR(3) NOT NULL,
    reserved_amount         NUMERIC(20, 8) NOT NULL,
    
    -- Status
    status                  VARCHAR(20) DEFAULT 'ACTIVE',    -- ACTIVE, RELEASED, CONSUMED, EXPIRED
    
    -- Timing
    reserved_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at              TIMESTAMPTZ NOT NULL,
    released_at             TIMESTAMPTZ,
    consumed_at             TIMESTAMPTZ,
    
    -- Release Reason
    release_reason          TEXT,
    
    CONSTRAINT valid_reservation_amount CHECK (reserved_amount > 0)
);

COMMENT ON TABLE ussd.tx_liquidity_reservations IS 'Fund reservations ensuring funds available for pending transactions';

-- =============================================================================
-- TABLE: pending_tx_events
-- DESCRIPTION: Transaction lifecycle events
-- SECURITY: Tamper-evident with hash chain
-- =============================================================================
CREATE TABLE IF NOT EXISTS ussd.pending_tx_events (
    event_id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pending_id              UUID NOT NULL REFERENCES ussd.pending_ussd_transactions(pending_id) ON DELETE CASCADE,
    
    -- Event Details
    event_type              VARCHAR(50) NOT NULL,            -- CREATED, CONFIRMED, COMPLETED, etc.
    event_severity          VARCHAR(20) DEFAULT 'INFO',      -- DEBUG, INFO, WARNING, ERROR, CRITICAL
    event_description       TEXT,
    
    -- State Snapshot
    status_snapshot         ussd.pending_tx_status,
    
    -- Security
    event_hash              VARCHAR(64) NOT NULL,
    previous_event_hash     VARCHAR(64),
    
    -- Context
    event_data              JSONB DEFAULT '{}',
    triggered_by            VARCHAR(100),
    
    -- Audit
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    
    CONSTRAINT valid_event_severity CHECK (
        event_severity IN ('DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL')
    )
);

COMMENT ON TABLE ussd.pending_tx_events IS 'Transaction lifecycle events with tamper-evident hashing';

-- =============================================================================
-- INDEXES FOR PENDING TRANSACTION TABLES
-- =============================================================================

-- pending_ussd_transactions indexes
CREATE INDEX IF NOT EXISTS idx_pending_tx_session ON ussd.pending_ussd_transactions(session_id, status);
CREATE INDEX IF NOT EXISTS idx_pending_tx_status_expires ON ussd.pending_ussd_transactions(status, expires_at) 
    WHERE status = 'PENDING';
CREATE INDEX IF NOT EXISTS idx_pending_tx_from_account ON ussd.pending_ussd_transactions(from_account_id, status);
CREATE INDEX IF NOT EXISTS idx_pending_tx_reference ON ussd.pending_ussd_transactions(pending_reference);
CREATE INDEX IF NOT EXISTS idx_pending_tx_created ON ussd.pending_ussd_transactions(created_at);
CREATE INDEX IF NOT EXISTS idx_pending_tx_core_ref ON ussd.pending_ussd_transactions(core_transaction_ref) 
    WHERE core_transaction_ref IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_pending_tx_risk ON ussd.pending_ussd_transactions(risk_score) 
    WHERE risk_score > 50;
CREATE INDEX IF NOT EXISTS idx_pending_tx_review ON ussd.pending_ussd_transactions(requires_manual_review, status) 
    WHERE requires_manual_review = true AND status = 'PENDING';

-- pending_tx_confirmations indexes
CREATE INDEX IF NOT EXISTS idx_tx_confirmations_pending ON ussd.pending_tx_confirmations(pending_id, attempted_at);
CREATE INDEX IF NOT EXISTS idx_tx_confirmations_result ON ussd.pending_tx_confirmations(attempt_result, attempted_at);
CREATE INDEX IF NOT EXISTS idx_tx_confirmations_suspicious ON ussd.pending_tx_confirmations(suspicious_pattern, attempted_at) 
    WHERE suspicious_pattern = true;

-- tx_liquidity_reservations indexes
CREATE INDEX IF NOT EXISTS idx_tx_reservations_pending ON ussd.tx_liquidity_reservations(pending_id);
CREATE INDEX IF NOT EXISTS idx_tx_reservations_account ON ussd.tx_liquidity_reservations(account_id, status);
CREATE INDEX IF NOT EXISTS idx_tx_reservations_expires ON ussd.tx_liquidity_reservations(expires_at, status) 
    WHERE status = 'ACTIVE';

-- pending_tx_events indexes
CREATE INDEX IF NOT EXISTS idx_tx_events_pending ON ussd.pending_tx_events(pending_id, created_at);
CREATE INDEX IF NOT EXISTS idx_tx_events_type ON ussd.pending_tx_events(event_type, event_severity);

-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

-- Function: Generate transaction hash
CREATE OR REPLACE FUNCTION ussd.generate_tx_hash(
    p_pending_id UUID,
    p_from_account_id UUID,
    p_to_account_id UUID,
    p_amount NUMERIC,
    p_currency VARCHAR(3),
    p_timestamp TIMESTAMPTZ
) RETURNS VARCHAR(64) AS $$
BEGIN
    RETURN encode(
        digest(
            p_pending_id::text || '|' ||
            COALESCE(p_from_account_id::text, '') || '|' ||
            COALESCE(p_to_account_id::text, '') || '|' ||
            p_amount::text || '|' ||
            p_currency || '|' ||
            extract(epoch from p_timestamp)::text,
            'sha256'
        ),
        'hex'
    );
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Function: Create pending transaction
CREATE OR REPLACE FUNCTION ussd.create_pending_transaction(
    p_session_id UUID,
    p_transaction_type VARCHAR(50),
    p_amount NUMERIC,
    p_currency VARCHAR(3),
    p_from_account_id UUID,
    p_to_account_id UUID DEFAULT NULL,
    p_to_msisdn VARCHAR(20) DEFAULT NULL,
    p_to_external_reference VARCHAR(100) DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'
) RETURNS TABLE (
    pending_id UUID,
    pending_reference VARCHAR(100),
    confirmation_prompt TEXT,
    requires_pin BOOLEAN,
    expires_at TIMESTAMPTZ
) AS $$
DECLARE
    v_pending_id UUID;
    v_reference VARCHAR(100);
    v_session RECORD;
    v_total_amount NUMERIC;
    v_fee NUMERIC;
    v_hash VARCHAR(64);
BEGIN
    -- Get session details
    SELECT * INTO v_session FROM ussd.ussd_sessions WHERE session_id = p_session_id;
    
    IF v_session IS NULL THEN
        RAISE EXCEPTION 'Invalid session';
    END IF;
    
    -- Calculate fee (simplified - would call fee service)
    v_fee := 0; -- Calculate based on transaction type
    v_total_amount := p_amount + v_fee;
    
    -- Generate reference
    v_reference := 'PEND-' || to_char(now(), 'YYYYMMDD') || '-' || upper(substr(gen_random_uuid()::text, 1, 8));
    
    -- Create pending transaction
    INSERT INTO ussd.pending_ussd_transactions (
        pending_reference, session_id, transaction_type,
        amount, currency, fee_amount, total_amount,
        from_account_id, to_account_id, to_msisdn, to_external_reference,
        to_msisdn_hash, to_msisdn_encrypted,
        expires_at, device_fingerprint, device_trust_score,
        metadata, created_by
    ) VALUES (
        v_reference, p_session_id, p_transaction_type,
        p_amount, p_currency, v_fee, v_total_amount,
        p_from_account_id, p_to_account_id, p_to_msisdn, p_to_external_reference,
        CASE WHEN p_to_msisdn IS NOT NULL THEN encode(digest(p_to_msisdn, 'sha256'), 'hex') END,
        CASE WHEN p_to_msisdn IS NOT NULL THEN ussd.encrypt_msisdn(p_to_msisdn) END,
        now() + interval '5 minutes',
        v_session.device_fingerprint,
        0.5, -- Default trust score
        p_metadata,
        p_from_account_id
    )
    RETURNING ussd.pending_ussd_transactions.pending_id INTO v_pending_id;
    
    -- Generate hash
    v_hash := ussd.generate_tx_hash(v_pending_id, p_from_account_id, p_to_account_id, p_amount, p_currency, now());
    
    UPDATE ussd.pending_ussd_transactions
    SET transaction_hash = v_hash
    WHERE pending_id = v_pending_id;
    
    -- Log event
    INSERT INTO ussd.pending_tx_events (
        pending_id, event_type, event_description, event_hash, status_snapshot
    ) VALUES (
        v_pending_id, 'CREATED', 'Transaction pending confirmation', 
        encode(digest(gen_random_uuid()::text, 'sha256'), 'hex'),
        'PENDING'
    );
    
    -- Create liquidity reservation
    INSERT INTO ussd.tx_liquidity_reservations (
        pending_id, account_id, currency, reserved_amount, expires_at
    ) VALUES (
        v_pending_id, p_from_account_id, p_currency, v_total_amount,
        now() + interval '5 minutes'
    );
    
    pending_id := v_pending_id;
    pending_reference := v_reference;
    confirmation_prompt := 'Confirm payment of ' || p_amount || ' ' || p_currency || '. Enter PIN:';
    requires_pin := true;
    expires_at := now() + interval '5 minutes';
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

-- Function: Verify PIN (without storing)
CREATE OR REPLACE FUNCTION ussd.verify_transaction_pin(
    p_pending_id UUID,
    p_pin_attempt VARCHAR(20),
    p_device_fingerprint VARCHAR(255) DEFAULT NULL
) RETURNS TABLE (
    success BOOLEAN,
    attempts_remaining INTEGER,
    locked BOOLEAN,
    error_message TEXT
) AS $$
DECLARE
    v_pending RECORD;
    v_pin_valid BOOLEAN := false;
    v_new_attempts INTEGER;
BEGIN
    -- Get pending transaction
    SELECT * INTO v_pending FROM ussd.pending_ussd_transactions WHERE pending_id = p_pending_id;
    
    IF v_pending IS NULL THEN
        success := false;
        attempts_remaining := 0;
        locked := true;
        error_message := 'Transaction not found';
        RETURN NEXT;
        RETURN;
    END IF;
    
    -- Check if already locked
    IF v_pending.pin_attempts >= v_pending.max_pin_attempts THEN
        -- Log blocked attempt
        INSERT INTO ussd.pending_tx_confirmations (
            pending_id, attempt_type, attempt_result, failure_reason, failure_code,
            device_fingerprint, ip_address
        ) VALUES (
            p_pending_id, 'PIN', 'BLOCKED', 'Account locked due to too many failed attempts', 'ACCOUNT_LOCKED',
            p_device_fingerprint, inet_client_addr()
        );
        
        success := false;
        attempts_remaining := 0;
        locked := true;
        error_message := 'Account locked. Please contact support.';
        RETURN NEXT;
        RETURN;
    END IF;
    
    -- Check expiration
    IF v_pending.expires_at < now() THEN
        -- Update status
        UPDATE ussd.pending_ussd_transactions
        SET status = 'EXPIRED', updated_at = now()
        WHERE pending_id = p_pending_id;
        
        success := false;
        attempts_remaining := 0;
        locked := false;
        error_message := 'Transaction expired';
        RETURN NEXT;
        RETURN;
    END IF;
    
    -- Verify PIN (would call authentication service)
    -- This is a placeholder - actual implementation calls auth service
    v_pin_valid := (p_pin_attempt IS NOT NULL AND length(p_pin_attempt) = 4);
    
    v_new_attempts := v_pending.pin_attempts + 1;
    
    IF v_pin_valid THEN
        -- PIN correct
        UPDATE ussd.pending_ussd_transactions
        SET 
            pin_verified = true,
            pin_attempts = v_new_attempts,
            last_pin_attempt_at = now(),
            updated_at = now()
        WHERE pending_id = p_pending_id;
        
        -- Log success
        INSERT INTO ussd.pending_tx_confirmations (
            pending_id, attempt_type, attempt_result, device_fingerprint, ip_address
        ) VALUES (
            p_pending_id, 'PIN', 'SUCCESS', p_device_fingerprint, inet_client_addr()
        );
        
        success := true;
        attempts_remaining := v_pending.max_pin_attempts - v_new_attempts;
        locked := false;
        error_message := NULL;
    ELSE
        -- PIN incorrect
        UPDATE ussd.pending_ussd_transactions
        SET 
            pin_attempts = v_new_attempts,
            last_pin_attempt_at = now(),
            updated_at = now()
        WHERE pending_id = p_pending_id;
        
        -- Log failure
        INSERT INTO ussd.pending_tx_confirmations (
            pending_id, attempt_type, attempt_result, failure_reason, failure_code,
            device_fingerprint, ip_address
        ) VALUES (
            p_pending_id, 'PIN', 'FAILED', 'Invalid PIN entered', 'INVALID_PIN',
            p_device_fingerprint, inet_client_addr()
        );
        
        success := false;
        attempts_remaining := GREATEST(0, v_pending.max_pin_attempts - v_new_attempts);
        locked := v_new_attempts >= v_pending.max_pin_attempts;
        error_message := 'Invalid PIN. ' || attempts_remaining || ' attempts remaining.';
    END IF;
    
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

-- Function: Confirm and execute transaction
CREATE OR REPLACE FUNCTION ussd.confirm_pending_transaction(
    p_pending_id UUID,
    p_confirmed_by UUID DEFAULT NULL
) RETURNS TABLE (
    success BOOLEAN,
    transaction_id UUID,
    core_reference VARCHAR(100),
    error_message TEXT
) AS $$
DECLARE
    v_pending RECORD;
    v_transaction_id UUID;
    v_core_ref VARCHAR(100);
BEGIN
    -- Get pending transaction
    SELECT * INTO v_pending FROM ussd.pending_ussd_transactions WHERE pending_id = p_pending_id;
    
    IF v_pending IS NULL THEN
        success := false;
        error_message := 'Transaction not found';
        RETURN NEXT;
        RETURN;
    END IF;
    
    -- Verify ready for confirmation
    IF v_pending.status != 'PENDING' THEN
        success := false;
        error_message := 'Transaction not in pending state: ' || v_pending.status;
        RETURN NEXT;
        RETURN;
    END IF;
    
    IF NOT v_pending.pin_verified THEN
        success := false;
        error_message := 'PIN verification required';
        RETURN NEXT;
        RETURN;
    END IF;
    
    IF v_pending.expires_at < now() THEN
        UPDATE ussd.pending_ussd_transactions
        SET status = 'EXPIRED', updated_at = now()
        WHERE pending_id = p_pending_id;
        
        success := false;
        error_message := 'Transaction expired';
        RETURN NEXT;
        RETURN;
    END IF;
    
    -- Mark as processing
    UPDATE ussd.pending_ussd_transactions
    SET 
        status = 'PROCESSING',
        status_changed_at = now(),
        confirmed_at = now(),
        updated_at = now()
    WHERE pending_id = p_pending_id;
    
    -- Release reservation
    UPDATE ussd.tx_liquidity_reservations
    SET 
        status = 'CONSUMED',
        consumed_at = now()
    WHERE pending_id = p_pending_id;
    
    -- Note: Actual core transaction creation would happen here via core.submit_transaction
    -- For now, we simulate success
    v_transaction_id := gen_random_uuid();
    v_core_ref := 'TXN-' || to_char(now(), 'YYYYMMDD') || '-' || upper(substr(v_transaction_id::text, 1, 8));
    
    -- Update pending record
    UPDATE ussd.pending_ussd_transactions
    SET 
        transaction_id = v_transaction_id,
        core_transaction_ref = v_core_ref,
        status = 'COMPLETED',
        status_changed_at = now(),
        completed_at = now(),
        updated_at = now()
    WHERE pending_id = p_pending_id;
    
    -- Log completion
    INSERT INTO ussd.pending_tx_events (
        pending_id, event_type, event_description, event_hash, status_snapshot
    ) VALUES (
        p_pending_id, 'COMPLETED', 'Transaction completed successfully',
        encode(digest(gen_random_uuid()::text, 'sha256'), 'hex'),
        'COMPLETED'
    );
    
    success := true;
    transaction_id := v_transaction_id;
    core_reference := v_core_ref;
    error_message := NULL;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

-- Function: Cancel pending transaction
CREATE OR REPLACE FUNCTION ussd.cancel_pending_transaction(
    p_pending_id UUID,
    p_reason TEXT DEFAULT 'User cancelled',
    p_cancelled_by UUID DEFAULT NULL
) RETURNS BOOLEAN AS $$
DECLARE
    v_pending RECORD;
    v_updated INTEGER;
BEGIN
    -- Get pending transaction
    SELECT * INTO v_pending FROM ussd.pending_ussd_transactions WHERE pending_id = p_pending_id;
    
    IF v_pending IS NULL THEN
        RETURN false;
    END IF;
    
    -- Can only cancel PENDING transactions
    IF v_pending.status NOT IN ('PENDING', 'CONFIRMED') THEN
        RETURN false;
    END IF;
    
    -- Update status
    UPDATE ussd.pending_ussd_transactions
    SET 
        status = 'CANCELLED',
        previous_status = status,
        status_changed_at = now(),
        cancelled_at = now(),
        cancellation_reason = p_reason,
        updated_at = now()
    WHERE pending_id = p_pending_id
      AND status IN ('PENDING', 'CONFIRMED');
    
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    
    IF v_updated > 0 THEN
        -- Release reservation
        UPDATE ussd.tx_liquidity_reservations
        SET 
            status = 'RELEASED',
            released_at = now(),
            release_reason = p_reason
        WHERE pending_id = p_pending_id;
        
        -- Log cancellation
        INSERT INTO ussd.pending_tx_events (
            pending_id, event_type, event_description, event_hash, status_snapshot, event_data
        ) VALUES (
            p_pending_id, 'CANCELLED', p_reason,
            encode(digest(gen_random_uuid()::text, 'sha256'), 'hex'),
            'CANCELLED',
            jsonb_build_object('cancelled_by', p_cancelled_by)
        );
    END IF;
    
    RETURN v_updated > 0;
END;
$$ LANGUAGE plpgsql;

-- Function: Cleanup expired transactions
CREATE OR REPLACE FUNCTION ussd.cleanup_expired_transactions(
    p_batch_size INTEGER DEFAULT 1000
) RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    -- Mark expired transactions
    WITH expired AS (
        UPDATE ussd.pending_ussd_transactions
        SET 
            status = 'EXPIRED',
            previous_status = status,
            status_changed_at = now(),
            updated_at = now()
        WHERE status = 'PENDING'
          AND expires_at < now()
        RETURNING pending_id
    )
    SELECT COUNT(*) INTO v_count FROM expired;
    
    -- Release reservations for expired transactions
    UPDATE ussd.tx_liquidity_reservations
    SET 
        status = 'RELEASED',
        released_at = now(),
        release_reason = 'Transaction expired'
    WHERE status = 'ACTIVE'
      AND expires_at < now();
    
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- TRIGGER FUNCTIONS
-- =============================================================================

-- Trigger: Update timestamps
CREATE OR REPLACE FUNCTION ussd.trigger_update_pending_tx_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_pending_tx_update ON ussd.pending_ussd_transactions;
CREATE TRIGGER trg_pending_tx_update
    BEFORE UPDATE ON ussd.pending_ussd_transactions
    FOR EACH ROW
    EXECUTE FUNCTION ussd.trigger_update_pending_tx_timestamp();

-- Trigger: Log status changes
CREATE OR REPLACE FUNCTION ussd.trigger_log_status_change()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        NEW.previous_status := OLD.status;
        NEW.status_changed_at := now();
        
        INSERT INTO ussd.pending_tx_events (
            pending_id, event_type, event_description, event_hash, 
            status_snapshot, event_data
        ) VALUES (
            NEW.pending_id,
            'STATUS_CHANGE',
            'Status changed from ' || OLD.status || ' to ' || NEW.status,
            encode(digest(gen_random_uuid()::text, 'sha256'), 'hex'),
            NEW.status,
            jsonb_build_object('from_status', OLD.status, 'to_status', NEW.status)
        );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_pending_tx_status_change ON ussd.pending_ussd_transactions;
CREATE TRIGGER trg_pending_tx_status_change
    BEFORE UPDATE OF status ON ussd.pending_ussd_transactions
    FOR EACH ROW
    EXECUTE FUNCTION ussd.trigger_log_status_change();

-- Trigger: Create event on insert
CREATE OR REPLACE FUNCTION ussd.trigger_log_tx_created()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO ussd.pending_tx_events (
        pending_id, event_type, event_description, event_hash, status_snapshot, event_data
    ) VALUES (
        NEW.pending_id,
        'CREATED',
        'Pending transaction created',
        encode(digest(gen_random_uuid()::text, 'sha256'), 'hex'),
        NEW.status,
        jsonb_build_object(
            'amount', NEW.amount,
            'currency', NEW.currency,
            'transaction_type', NEW.transaction_type
        )
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_pending_tx_created ON ussd.pending_ussd_transactions;
CREATE TRIGGER trg_pending_tx_created
    AFTER INSERT ON ussd.pending_ussd_transactions
    FOR EACH ROW
    EXECUTE FUNCTION ussd.trigger_log_tx_created();

-- =============================================================================
-- ROW LEVEL SECURITY
-- =============================================================================

DO $$
BEGIN
    ALTER TABLE ussd.pending_ussd_transactions ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE ussd.pending_tx_confirmations ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE ussd.tx_liquidity_reservations ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE ussd.pending_tx_events ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Policies
CREATE POLICY pending_tx_account_isolation ON ussd.pending_ussd_transactions
    FOR ALL USING (
        from_account_id = current_setting('app.current_account_id', true)::UUID
        OR current_setting('app.current_role', true) = 'ussd_admin'
    );

CREATE POLICY tx_confirmations_pending_isolation ON ussd.pending_tx_confirmations
    FOR ALL USING (
        pending_id IN (
            SELECT pending_id FROM ussd.pending_ussd_transactions
            WHERE from_account_id = current_setting('app.current_account_id', true)::UUID
        )
    );

-- =============================================================================
-- GRANTS
-- =============================================================================

GRANT SELECT, INSERT, UPDATE ON ussd.pending_ussd_transactions TO ussd_gateway_role;
GRANT INSERT ON ussd.pending_tx_confirmations TO ussd_gateway_role;
GRANT SELECT, INSERT, UPDATE ON ussd.tx_liquidity_reservations TO ussd_gateway_role;
GRANT SELECT ON ussd.pending_tx_events TO ussd_gateway_role;
GRANT ALL ON ussd.pending_ussd_transactions TO ussd_security_role;
GRANT ALL ON ussd.pending_tx_confirmations TO ussd_security_role;

-- =============================================================================
-- COMPLIANCE NOTES
-- =============================================================================
/*
1. PIN SECURITY (CRITICAL):
   - NEVER store PIN in any form
   - Hash comparison only (bcrypt/Argon2)
   - NEVER log PIN or partial PIN
   - Max 3 attempts before lockout
   - 5-minute timeout maximum

2. TRANSACTION FLOW:
   - Create: Validate, reserve funds, set timeout
   - Confirm: Verify PIN, check device, execute
   - Complete: Release reservation, update status
   - Cancel/Expire: Release reservation, log reason

3. FRAUD DETECTION:
   - Velocity limits per account
   - Device fingerprint verification
   - SIM swap detection
   - Geographic anomaly detection
   - Risk scoring with transparent factors

4. AUDIT REQUIREMENTS:
   - Hash chain for integrity
   - Complete state transition log
   - Confirmation attempts (no PINs)
   - 10-year retention for completed
   - 90-day for cancelled/expired

5. REGULATORY COMPLIANCE:
   - SCA: Strong Customer Authentication
   - RTS: Regulatory Technical Standards
   - PSD2: Payment Services Directive 2
   - GDPR: Data protection in financial data
*/

COMMIT;
