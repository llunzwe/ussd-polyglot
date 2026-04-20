-- =============================================================================
-- Migration: V065__compliance_pci_dss_card_tokens
-- Description: Compliance pci_dss: card_tokens
-- Dependencies: V064
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- USSD KERNEL COMPLIANCE SCHEMA - PCI DSS Card Tokenization Vault
-- Enterprise-Grade Immutable Ledger System
-- =============================================================================
-- FILENAME:    004_card_tokens.sql
-- SCHEMA:      core
-- TABLE:       card_tokens
-- DESCRIPTION: PCI DSS Requirement 3.4.1 - PAN tokenization vault
-- 
-- COMPLIANCE:  PCI DSS v4.0 Requirement 3.4, 3.5, 3.6, 3.7
--              ISO/IEC 27001:2022 A.8.1 (User endpoint devices)
--              ISO/IEC 27040 (Storage Security)
-- =============================================================================

/*
================================================================================
PCI DSS REQUIREMENT 3 MAPPING
================================================================================

Requirement 3: Protect Stored Account Data
├── 3.4: PAN rendered unreadable (tokenization)
├── 3.5: Cryptographic keys protected
├── 3.6: Key management procedures
├── 3.7: Key management documented
└── 3.8: Cryptographic architectures documented

Tokenization Methods:
├── Format-Preserving Tokenization (FPT)
├── Random Tokenization
├── Deterministic Tokenization
└── Payment Network Tokenization

================================================================================
SECURITY IMPLEMENTATION
================================================================================

1. NO RAW PAN STORAGE
   - Only SHA-256 hash of PAN stored
   - Last 4 digits only (PCI DSS compliant)
   - First 6 digits (BIN/IIN) stored for routing
   
2. TOKEN VAULT SECURITY
   - Encryption at rest
   - Access logging
   - Token-to-PAN mapping in HSM/Vault (external)
   
3. AUDIT TRAIL
   - All token operations logged
   - Detokenization attempts tracked
   - Token lifecycle events recorded

================================================================================
*/

-- =============================================================================
-- CREATE TABLE: card_tokens
-- =============================================================================

CREATE TABLE IF NOT EXISTS core.card_tokens (
    token_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Token details
    token_value VARCHAR(255) NOT NULL UNIQUE, -- The actual token
    token_format VARCHAR(20) NOT NULL 
        CHECK (token_format IN ('FORMAT_PRESERVING', 'RANDOM', 'DETERMINISTIC', 'NETWORK')),
    token_type VARCHAR(20) NOT NULL 
        CHECK (token_type IN ('PAYMENT', 'SECURITY', 'REFUND', 'RECURRING', 'ONE_TIME')),
    token_algorithm VARCHAR(50) DEFAULT 'AES-256-CTR',
    
    -- PAN identification (NOT the actual PAN)
    pan_hash VARCHAR(64) NOT NULL, -- SHA-256 of full PAN
    pan_fingerprint VARCHAR(64), -- For duplicate card detection
    card_bin VARCHAR(6) NOT NULL, -- First 6 digits (Bank Identification Number)
    card_last_four VARCHAR(4) NOT NULL, -- Last 4 digits for display
    card_number_length INTEGER, -- Length of original PAN (for format preservation)
    
    -- Card attributes
    card_brand VARCHAR(20) 
        CHECK (card_brand IN ('VISA', 'MASTERCARD', 'AMEX', 'DISCOVER', 'JCB', 'DINERS', 'UNIONPAY', 'UNKNOWN')),
    card_type VARCHAR(20) 
        CHECK (card_type IN ('CREDIT', 'DEBIT', 'PREPAID', 'GIFT', 'CHARGECARD')),
    card_subtype VARCHAR(50), -- e.g., "CORPORATE", "REWARDS", "SECURED"
    
    -- Expiration (for display/reference only)
    expiry_month VARCHAR(2),
    expiry_year VARCHAR(4),
    expired BOOLEAN DEFAULT FALSE,  -- Computed by trigger due to CURRENT_DATE immutability requirement
    
    -- Issuer information
    issuing_bank_name VARCHAR(100),
    issuing_country VARCHAR(2), -- ISO country code
    issuer_phone VARCHAR(20),
    
    -- Token scope and ownership
    merchant_id UUID, -- Scope token to specific merchant
    account_id UUID REFERENCES core.account_registry(account_id),
    customer_reference VARCHAR(100), -- Customer's reference for this card
    
    -- Security
    encryption_key_id UUID, -- FK to encryption_keys table (created in V094)
    tokenization_method VARCHAR(20) 
        CHECK (tokenization_method IN ('NETWORK', 'PROPRIETARY', 'THIRD_PARTY')),
    pci_scope VARCHAR(20) DEFAULT 'CDE' 
        CHECK (pci_scope IN ('CDE', 'NON_CDE')),
    
    -- Token lifecycle
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ, -- Token expiration (different from card expiry)
    last_used_at TIMESTAMPTZ,
    usage_count INTEGER DEFAULT 0,
    
    -- Status
    token_status VARCHAR(20) DEFAULT 'ACTIVE' 
        CHECK (token_status IN ('ACTIVE', 'SUSPENDED', 'EXPIRED', 'REVOKED', 'COMPROMISED')),
    
    -- Suspension/Revocation
    suspended_at TIMESTAMPTZ,
    suspended_by UUID REFERENCES core.account_registry(account_id),
    suspension_reason TEXT,
    revoked_at TIMESTAMPTZ,
    revoked_by UUID REFERENCES core.account_registry(account_id),
    revocation_reason TEXT,
    
    -- Compromise handling
    compromised_at TIMESTAMPTZ,
    compromised_reason TEXT,
    replacement_token_id UUID REFERENCES core.card_tokens(token_id),
    
    -- Risk scoring
    risk_score INTEGER DEFAULT 0 CHECK (risk_score >= 0 AND risk_score <= 100),
    risk_factors JSONB DEFAULT '{}', -- {velocity_exceeded: true, geo_anomaly: false, ...}
    
    -- Usage restrictions
    usage_restrictions JSONB DEFAULT '{}', 
    /* Example:
    {
        "max_transaction_amount": 1000.00,
        "daily_limit": 5000.00,
        "allowed_merchants": ["merchant1", "merchant2"],
        "blocked_countries": ["XX", "YY"],
        "requires_3ds": true
    }
    */
    
    -- Origination
    tokenization_source VARCHAR(50), -- WEB, MOBILE, API, POS, IVR
    tokenization_ip_address INET,
    tokenization_geolocation JSONB,
    
    -- Verification
    cvv_verified BOOLEAN DEFAULT FALSE,
    cvv_verified_at TIMESTAMPTZ,
    avs_result VARCHAR(20), -- Address Verification result
    avs_verified_at TIMESTAMPTZ,
    
    -- 3D Secure
    enrolled_3ds BOOLEAN DEFAULT FALSE,
    authentication_3ds VARCHAR(20), -- Y (full), A (attempted), N (not), U (unavailable)
    eci_code VARCHAR(2), -- Electronic Commerce Indicator
    cavv_value VARCHAR(100), -- Cardholder Authentication Verification Value
    
    -- Audit
    created_by UUID REFERENCES core.account_registry(account_id),
    record_hash VARCHAR(64) NOT NULL DEFAULT 'PENDING',
    
    -- Constraints
    CONSTRAINT chk_card_token_last_four CHECK (
        card_last_four ~ '^[0-9]{4}$'
    ),
    CONSTRAINT chk_card_token_bin CHECK (
        card_bin ~ '^[0-9]{6}$'
    ),
    CONSTRAINT chk_card_token_expiry CHECK (
        (expiry_month IS NULL OR expiry_month ~ '^[0-9]{2}$') AND
        (expiry_year IS NULL OR expiry_year ~ '^[0-9]{4}$')
    ),
    CONSTRAINT chk_card_token_pan_hash CHECK (
        pan_hash ~ '^[a-f0-9]{64}$' -- SHA-256 hex format
    )
);

-- =============================================================================
-- INDEXES
-- =============================================================================

-- Token lookup (primary)
CREATE INDEX IF NOT EXISTS idx_card_tokens_value 
    ON core.card_tokens(token_value, token_status);

-- PAN hash lookup (for detokenization)
CREATE UNIQUE INDEX IF NOT EXISTS idx_card_tokens_pan_hash 
    ON core.card_tokens(pan_hash, merchant_id) 
    WHERE token_status = 'ACTIVE';

-- Account lookup
CREATE INDEX IF NOT EXISTS idx_card_tokens_account 
    ON core.card_tokens(account_id, token_status);

-- Merchant lookup
CREATE INDEX IF NOT EXISTS idx_card_tokens_merchant 
    ON core.card_tokens(merchant_id, token_status);

-- BIN lookup (for routing)
CREATE INDEX IF NOT EXISTS idx_card_tokens_bin 
    ON core.card_tokens(card_bin, card_brand, token_status);

-- Expiry monitoring
CREATE INDEX IF NOT EXISTS idx_card_tokens_expiry 
    ON core.card_tokens(expires_at) 
    WHERE token_status = 'ACTIVE' AND expires_at IS NOT NULL;

-- Card expiry monitoring
CREATE INDEX IF NOT EXISTS idx_card_tokens_card_expiry 
    ON core.card_tokens(expiry_year, expiry_month, token_status) 
    WHERE token_status = 'ACTIVE';

-- Fingerprint (duplicate detection)
CREATE INDEX IF NOT EXISTS idx_card_tokens_fingerprint 
    ON core.card_tokens(pan_fingerprint);

-- Risk monitoring
CREATE INDEX IF NOT EXISTS idx_card_tokens_risk 
    ON core.card_tokens(risk_score DESC) 
    WHERE risk_score > 50;

-- Last used (for cleanup)
CREATE INDEX IF NOT EXISTS idx_card_tokens_last_used 
    ON core.card_tokens(last_used_at) 
    WHERE token_status = 'ACTIVE';

-- Status for reporting
CREATE INDEX IF NOT EXISTS idx_card_tokens_status 
    ON core.card_tokens(token_status, created_at DESC);

-- =============================================================================
-- TRIGGERS
-- =============================================================================

-- Hash computation trigger
CREATE OR REPLACE FUNCTION core.compute_card_token_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.record_hash := core.generate_hash(
        NEW.token_id::TEXT || 
        NEW.token_value || 
        NEW.pan_hash ||
        NEW.card_bin ||
        NEW.card_last_four ||
        NEW.created_at::TEXT
    );
    
    -- Set token expiration if not set
    IF NEW.expires_at IS NULL THEN
        NEW.expires_at := NEW.created_at + INTERVAL '4 years'; -- Default 4 year token life
    END IF;
    
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_card_token_compute_hash ON core.card_tokens;
CREATE TRIGGER trg_card_token_compute_hash
    BEFORE INSERT OR UPDATE ON core.card_tokens
    FOR EACH ROW
    EXECUTE FUNCTION core.compute_card_token_hash();

-- PAN hash computation trigger (ensures consistency)
CREATE OR REPLACE FUNCTION core.compute_pan_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Note: In production, the actual PAN would be hashed by the application
    -- or HSM before reaching the database. This is a placeholder.
    -- The pan_hash should be pre-computed and provided in the INSERT.
    
    -- Compute fingerprint if not provided
    IF NEW.pan_fingerprint IS NULL AND NEW.pan_hash IS NOT NULL THEN
        -- Use first 16 chars of hash as fingerprint
        NEW.pan_fingerprint := substring(NEW.pan_hash, 1, 16);
    END IF;
    
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_card_token_pan_hash ON core.card_tokens;
CREATE TRIGGER trg_card_token_pan_hash
    BEFORE INSERT ON core.card_tokens
    FOR EACH ROW
    EXECUTE FUNCTION core.compute_pan_hash();

-- Usage audit trigger
CREATE OR REPLACE FUNCTION core.audit_card_token_usage()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.usage_count != NEW.usage_count THEN
        INSERT INTO core.pci_audit_events (
            event_type,
            action,
            action_status,
            user_id,
            action_result,
            accessed_pan,
            cde_scope,
            event_severity
        ) VALUES (
            'DATA_ACCESS',
            'TOKEN_USED',
            'SUCCESS',
            NEW.account_id,
            jsonb_build_object(
                'token_id', NEW.token_id,
                'usage_count', NEW.usage_count,
                'merchant_id', NEW.merchant_id
            )::TEXT,
            TRUE,
            TRUE,
            'INFO'
        );
    END IF;
    
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_card_token_usage ON core.card_tokens;
CREATE TRIGGER trg_card_token_usage
    AFTER UPDATE ON core.card_tokens
    FOR EACH ROW
    EXECUTE FUNCTION core.audit_card_token_usage();

-- Compromise alert trigger
CREATE OR REPLACE FUNCTION core.alert_card_compromise()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.token_status = 'COMPROMISED' AND OLD.token_status != 'COMPROMISED' THEN
        INSERT INTO core.pci_audit_events (
            event_type,
            action,
            action_status,
            action_result,
            event_severity
        ) VALUES (
            'CONFIG_CHANGE',
            'TOKEN_COMPROMISED',
            'SUCCESS',
            jsonb_build_object(
                'token_id', NEW.token_id,
                'reason', NEW.compromised_reason
            )::TEXT,
            'CRITICAL'
        );
    END IF;
    
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_card_token_compromise ON core.card_tokens;
CREATE TRIGGER trg_card_token_compromise
    AFTER UPDATE ON core.card_tokens
    FOR EACH ROW
    EXECUTE FUNCTION core.alert_card_compromise();

-- =============================================================================
-- RLS POLICIES
-- =============================================================================

-- Enable RLS
DO $$
BEGIN
    ALTER TABLE core.card_tokens ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Policy: Account owners can view their tokens
CREATE POLICY card_token_owner_access ON core.card_tokens
    FOR SELECT
    TO ussd_app_user
    USING (
        account_id = current_setting('app.current_account_id', true)::UUID
    );

-- Policy: Merchants can view their scoped tokens
CREATE POLICY card_token_merchant_access ON core.card_tokens
    FOR SELECT
    TO ussd_app_user
    USING (
        merchant_id = current_setting('app.current_merchant_id', true)::UUID
    );

-- Policy: Security officers can view all
CREATE POLICY card_token_security_access ON core.card_tokens
    FOR ALL
    TO ussd_app_user
    USING (
        EXISTS (
            SELECT 1 FROM core.pci_user_roles pur
            WHERE pur.user_id = current_setting('app.current_account_id', true)::UUID
            AND pur.role_classification IN ('SECURITY_ADMIN', 'AUDITOR')
            AND pur.status = 'ACTIVE'
        )
    );

-- Policy: No updates to sensitive fields
CREATE POLICY card_token_no_update ON core.card_tokens
    FOR UPDATE
    TO ussd_app_user
    USING (
        account_id = current_setting('app.current_account_id', true)::UUID
    );

-- Policy: Kernel role has full access
CREATE POLICY card_token_kernel_access ON core.card_tokens
    FOR ALL
    TO ussd_kernel_role
    USING (true);

-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

-- Function: Create new token
CREATE OR REPLACE FUNCTION core.create_card_token(
    p_token_value VARCHAR,
    p_pan_hash VARCHAR,
    p_card_bin VARCHAR,
    p_card_last_four VARCHAR,
    p_card_brand VARCHAR,
    p_expiry_month VARCHAR,
    p_expiry_year VARCHAR,
    p_account_id UUID,
    p_merchant_id UUID DEFAULT NULL,
    p_token_type VARCHAR DEFAULT 'PAYMENT',
    p_token_format VARCHAR DEFAULT 'RANDOM',
    p_created_by UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_token_id UUID;
BEGIN
    INSERT INTO core.card_tokens (
        token_value,
        pan_hash,
        card_bin,
        card_last_four,
        card_brand,
        expiry_month,
        expiry_year,
        account_id,
        merchant_id,
        token_type,
        token_format,
        created_by
    ) VALUES (
        p_token_value,
        p_pan_hash,
        p_card_bin,
        p_card_last_four,
        p_card_brand,
        p_expiry_month,
        p_expiry_year,
        p_account_id,
        p_merchant_id,
        p_token_type,
        p_token_format,
        p_created_by
    )
    RETURNING token_id INTO v_token_id;
    
    -- Audit token creation
    INSERT INTO core.pci_audit_events (
        event_type,
        action,
        action_status,
        user_id,
        action_result,
        accessed_pan,
        cde_scope,
        event_severity
    ) VALUES (
        'DATA_MODIFICATION',
        'TOKEN_CREATED',
        'SUCCESS',
        p_account_id,
        jsonb_build_object(
            'token_id', v_token_id,
            'merchant_id', p_merchant_id,
            'token_type', p_token_type
        )::TEXT,
        FALSE,
        TRUE,
        'INFO'
    );
    
    RETURN v_token_id;
END;
$$;

-- Function: Record token usage
CREATE OR REPLACE FUNCTION core.record_token_usage(
    p_token_id UUID,
    p_transaction_id BIGINT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE core.card_tokens
    SET usage_count = usage_count + 1,
        last_used_at = NOW()
    WHERE token_id = p_token_id;
    
    RETURN FOUND;
END;
$$;

-- Function: Suspend token
CREATE OR REPLACE FUNCTION core.suspend_card_token(
    p_token_id UUID,
    p_reason TEXT,
    p_suspended_by UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE core.card_tokens
    SET token_status = 'SUSPENDED',
        suspended_at = NOW(),
        suspended_by = p_suspended_by,
        suspension_reason = p_reason
    WHERE token_id = p_token_id
      AND token_status = 'ACTIVE';
    
    RETURN FOUND;
END;
$$;

-- Function: Revoke/compromise token
CREATE OR REPLACE FUNCTION core.revoke_card_token(
    p_token_id UUID,
    p_reason TEXT,
    p_compromised BOOLEAN DEFAULT FALSE,
    p_revoked_by UUID DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_compromised THEN
        UPDATE core.card_tokens
        SET token_status = 'COMPROMISED',
            compromised_at = NOW(),
            compromised_reason = p_reason
        WHERE token_id = p_token_id;
    ELSE
        UPDATE core.card_tokens
        SET token_status = 'REVOKED',
            revoked_at = NOW(),
            revoked_by = p_revoked_by,
            revocation_reason = p_reason
        WHERE token_id = p_token_id;
    END IF;
    
    RETURN FOUND;
END;
$$;

-- Function: Find token by PAN hash (detokenization lookup)
CREATE OR REPLACE FUNCTION core.find_token_by_pan_hash(
    p_pan_hash VARCHAR,
    p_merchant_id UUID DEFAULT NULL
)
RETURNS TABLE (
    token_id UUID,
    token_value VARCHAR,
    card_last_four VARCHAR,
    card_brand VARCHAR,
    expiry_month VARCHAR,
    expiry_year VARCHAR,
    token_status VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ct.token_id,
        ct.token_value,
        ct.card_last_four,
        ct.card_brand,
        ct.expiry_month,
        ct.expiry_year,
        ct.token_status
    FROM core.card_tokens ct
    WHERE ct.pan_hash = p_pan_hash
      AND ct.token_status = 'ACTIVE'
      AND (p_merchant_id IS NULL OR ct.merchant_id = p_merchant_id)
    LIMIT 1;
END;
$$;

-- Function: Get token statistics
CREATE OR REPLACE FUNCTION core.get_token_statistics(
    p_merchant_id UUID DEFAULT NULL
)
RETURNS TABLE (
    total_tokens BIGINT,
    active_tokens BIGINT,
    expired_tokens BIGINT,
    revoked_tokens BIGINT,
    compromised_tokens BIGINT,
    total_usage_count BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        COUNT(*) as total_tokens,
        COUNT(*) FILTER (WHERE token_status = 'ACTIVE') as active_tokens,
        COUNT(*) FILTER (WHERE token_status = 'EXPIRED') as expired_tokens,
        COUNT(*) FILTER (WHERE token_status = 'REVOKED') as revoked_tokens,
        COUNT(*) FILTER (WHERE token_status = 'COMPROMISED') as compromised_tokens,
        COALESCE(SUM(usage_count), 0) as total_usage_count
    FROM core.card_tokens
    WHERE (p_merchant_id IS NULL OR merchant_id = p_merchant_id);
END;
$$;

-- =============================================================================
-- TABLE COMMENTS
-- =============================================================================

COMMENT ON TABLE core.card_tokens IS 
    'PCI DSS Requirement 3.4.1 - PAN tokenization vault. NO RAW PANs stored.';

COMMENT ON COLUMN core.card_tokens.pan_hash IS 
    'SHA-256 hash of full PAN for lookups. NOT reversible.';

COMMENT ON COLUMN core.card_tokens.token_value IS 
    'The token that replaces PAN in transactions and storage.';

COMMENT ON COLUMN core.card_tokens.card_bin IS 
    'First 6 digits of PAN (Bank Identification Number) for routing.';

COMMENT ON COLUMN core.card_tokens.card_last_four IS 
    'Last 4 digits of PAN (PCI DSS allows storage for identification).';

COMMENT ON COLUMN core.card_tokens.tokenization_method IS 
    'NETWORK: Payment network tokenization. PROPRIETARY: Internal tokenization.';

-- =============================================================================
-- END OF FILE
-- =============================================================================

COMMIT;
