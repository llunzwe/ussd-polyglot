-- =============================================================================
-- Migration: V004__jwt_session_tokens
-- Description: JWT Token Management for Stateless Sessions
-- Dependencies: V001-V003
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- CORE ACCOUNT REGISTRY (REQUIRED FOR V006-V008 FOREIGN KEYS)
-- =============================================================================
-- This table is referenced by core.transaction_log, core.movement_legs,
-- and core.movement_postings. Must exist before those migrations.
-- =============================================================================

CREATE TABLE IF NOT EXISTS core.account_registry (
    account_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Account identification
    account_number VARCHAR(50) NOT NULL UNIQUE,
    primary_identifier VARCHAR(100), -- External reference (e.g., MSISDN, email)
    
    -- Account classification
    account_type VARCHAR(20) NOT NULL 
        CHECK (account_type IN ('individual', 'business', 'system', 'suspense')),
    account_subtype VARCHAR(30),
    
    -- Application context (multi-tenancy)
    primary_application_id UUID,
    
    -- Account status
    status VARCHAR(20) DEFAULT 'active' 
        CHECK (status IN ('active', 'inactive', 'suspended', 'closed')),
    
    -- KYC/Compliance
    kyc_level INTEGER DEFAULT 0,
    kyc_verified_at TIMESTAMPTZ,
    
    -- Metadata
    metadata JSONB DEFAULT '{}',
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    closed_at TIMESTAMPTZ,
    closed_reason VARCHAR(100)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_account_registry_app 
    ON core.account_registry(primary_application_id) 
    WHERE primary_application_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_account_registry_type 
    ON core.account_registry(account_type, status);

CREATE INDEX IF NOT EXISTS idx_account_registry_identifier 
    ON core.account_registry(primary_identifier) 
    WHERE primary_identifier IS NOT NULL;

COMMENT ON TABLE core.account_registry IS 
'Core account registry - master record for all accounts in the ledger system.
REFERENCED BY: core.transaction_log, core.movement_legs, core.movement_postings';

-- =============================================================================
-- CORE TRANSACTION TYPES (REQUIRED FOR V006 FOREIGN KEYS)
-- =============================================================================
-- This table is referenced by core.transaction_log transaction_type_id.
-- Must exist before V006 migration.
-- =============================================================================

CREATE TABLE IF NOT EXISTS core.transaction_types (
    type_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Type identification
    type_code VARCHAR(50) NOT NULL UNIQUE,
    type_name VARCHAR(100) NOT NULL,
    type_category VARCHAR(30) NOT NULL 
        CHECK (type_category IN ('payment', 'transfer', 'deposit', 'withdrawal', 
                                 'fee', 'interest', 'adjustment', 'reversal', 'system')),
    
    -- Accounting rules
    default_debit_account_id UUID REFERENCES core.account_registry(account_id) ON DELETE SET NULL,
    default_credit_account_id UUID REFERENCES core.account_registry(account_id) ON DELETE SET NULL,
    
    -- Configuration
    requires_approval BOOLEAN DEFAULT FALSE,
    approval_threshold NUMERIC(20, 8),
    
    -- Validation
    amount_min NUMERIC(20, 8),
    amount_max NUMERIC(20, 8),
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_transaction_types_category 
    ON core.transaction_types(type_category, is_active);

CREATE INDEX IF NOT EXISTS idx_transaction_types_active 
    ON core.transaction_types(is_active, type_code);

COMMENT ON TABLE core.transaction_types IS 
'Transaction type definitions and accounting rules.
REFERENCED BY: core.transaction_log.transaction_type_id';

-- Insert default system transaction types
INSERT INTO core.transaction_types (type_code, type_name, type_category, is_active, created_at)
VALUES 
    ('PAYMENT', 'Payment', 'payment', TRUE, NOW()),
    ('TRANSFER', 'Transfer', 'transfer', TRUE, NOW()),
    ('DEPOSIT', 'Deposit', 'deposit', TRUE, NOW()),
    ('WITHDRAWAL', 'Withdrawal', 'withdrawal', TRUE, NOW()),
    ('FEE', 'Fee', 'fee', TRUE, NOW()),
    ('INTEREST', 'Interest', 'interest', TRUE, NOW()),
    ('ADJUSTMENT', 'Adjustment', 'adjustment', TRUE, NOW()),
    ('REVERSAL', 'Reversal', 'reversal', TRUE, NOW()),
    ('SYSTEM', 'System Transaction', 'system', TRUE, NOW())
ON CONFLICT (type_code) DO NOTHING;

-- Create a default system account for initial setup
INSERT INTO core.account_registry (account_id, account_number, account_type, status, created_at)
VALUES 
    ('00000000-0000-0000-0000-000000000001', 'SYSTEM', 'system', 'active', NOW()),
    ('00000000-0000-0000-0000-000000000002', 'SUSPENSE', 'suspense', 'active', NOW())
ON CONFLICT (account_number) DO NOTHING;

-- =============================================================================
-- JWT TOKEN STORE
-- =============================================================================
-- PRODUCTION FIX (DEP-001): application_id is NOT NULL but references 
-- app.application_registry which is created in V030. 
-- Changed to allow NULL initially; enforce NOT NULL at application layer until V030.
-- =============================================================================

CREATE TABLE IF NOT EXISTS ussd.jwt_tokens (
    token_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Token identification
    jti VARCHAR(255) NOT NULL UNIQUE, -- JWT ID (unique identifier)
    subject VARCHAR(255) NOT NULL,    -- Subject (user_id or session_id)
    
    -- Application context
    -- NOTE: FK to app.application_registry added in V030 after table creation
    application_id UUID,  -- DEP-001 FIX: Was NOT NULL, changed to allow NULL until V030
    
    -- Token metadata
    token_type VARCHAR(20) DEFAULT 'access' 
        CHECK (token_type IN ('access', 'refresh', 'session')),
    
    -- Scopes/permissions
    scopes TEXT[] DEFAULT ARRAY['ussd:session'],
    
    -- Session linkage
    session_id UUID,
    
    -- Token lifecycle
    issued_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    not_before TIMESTAMPTZ DEFAULT NOW(),
    
    -- Revocation
    is_revoked BOOLEAN DEFAULT FALSE,
    revoked_at TIMESTAMPTZ,
    revoked_reason VARCHAR(100),
    
    -- Usage tracking
    last_used_at TIMESTAMPTZ,
    use_count INTEGER DEFAULT 0,
    
    -- Client info
    ip_address INET,
    user_agent TEXT,
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_jwt_tokens_subject 
    ON ussd.jwt_tokens(subject, is_revoked, expires_at);

CREATE INDEX IF NOT EXISTS idx_jwt_tokens_session 
    ON ussd.jwt_tokens(session_id) 
    WHERE session_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_jwt_tokens_expiry 
    ON ussd.jwt_tokens(expires_at) 
    WHERE is_revoked = FALSE;

CREATE INDEX IF NOT EXISTS idx_jwt_tokens_app 
    ON ussd.jwt_tokens(application_id, created_at DESC);

COMMENT ON TABLE ussd.jwt_tokens IS 'JWT token tracking for session management';

-- =============================================================================
-- TOKEN BLACKLIST (REVOCATION)
-- =============================================================================

CREATE TABLE IF NOT EXISTS ussd.token_blacklist (
    blacklist_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    jti VARCHAR(255) NOT NULL UNIQUE,
    subject VARCHAR(255) NOT NULL,
    
    -- Revocation details
    revoked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revoked_by UUID,
    reason VARCHAR(100),
    
    -- Original expiry (for cleanup)
    original_expires_at TIMESTAMPTZ NOT NULL,
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for cleanup job
CREATE INDEX IF NOT EXISTS idx_token_blacklist_expiry 
    ON ussd.token_blacklist(original_expires_at);

COMMENT ON TABLE ussd.token_blacklist IS 'Revoked JWT tokens for immediate rejection';

-- =============================================================================
-- API KEY MANAGEMENT (Enhanced)
-- =============================================================================

CREATE TABLE IF NOT EXISTS app.api_keys (
    key_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Key identification
    application_id UUID NOT NULL,
    key_name VARCHAR(100) NOT NULL,
    
    -- Key hash (never store plaintext)
    key_hash VARCHAR(255) NOT NULL,
    key_prefix VARCHAR(10) NOT NULL, -- First 8 chars for identification
    
    -- Key type and permissions
    key_type VARCHAR(20) DEFAULT 'standard' 
        CHECK (key_type IN ('standard', 'admin', 'webhook', 'readonly')),
    permissions TEXT[] DEFAULT ARRAY['ussd:read', 'ussd:write'],
    
    -- Rate limiting
    rate_limit_rpm INTEGER DEFAULT 60, -- Requests per minute
    rate_limit_burst INTEGER DEFAULT 10,
    
    -- IP restrictions
    allowed_ips INET[],
    blocked_ips INET[],
    
    -- Key lifecycle
    is_active BOOLEAN DEFAULT TRUE,
    expires_at TIMESTAMPTZ,
    last_used_at TIMESTAMPTZ,
    
    -- Rotation tracking
    rotated_from UUID,
    rotated_at TIMESTAMPTZ,
    auto_rotate_days INTEGER,
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    revoked_at TIMESTAMPTZ,
    revoked_by UUID,
    revoked_reason VARCHAR(100),
    
    -- Constraints
    CONSTRAINT chk_valid_expiry CHECK (expires_at IS NULL OR expires_at > created_at)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_api_keys_app 
    ON app.api_keys(application_id, is_active);

CREATE INDEX IF NOT EXISTS idx_api_keys_hash 
    ON app.api_keys(key_hash) 
    WHERE is_active = TRUE;

CREATE INDEX IF NOT EXISTS idx_api_keys_expiry 
    ON app.api_keys(expires_at) 
    WHERE is_active = TRUE AND expires_at IS NOT NULL;

COMMENT ON TABLE app.api_keys IS 'API keys for application authentication';

-- =============================================================================
-- SESSION CHECKPOINTS
-- =============================================================================

CREATE TABLE IF NOT EXISTS ussd.session_checkpoints (
    checkpoint_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Session reference
    session_id UUID NOT NULL,
    
    -- Checkpoint data
    checkpoint_sequence INTEGER NOT NULL,
    menu_state JSONB NOT NULL,
    context_data JSONB,
    input_history TEXT[],
    
    -- Metadata
    checkpoint_name VARCHAR(100), -- e.g., 'pre_payment', 'confirmation'
    checkpoint_reason VARCHAR(100),
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    UNIQUE (session_id, checkpoint_sequence)
);

-- Index for quick restore
CREATE INDEX IF NOT EXISTS idx_session_checkpoints 
    ON ussd.session_checkpoints(session_id, checkpoint_sequence DESC);

COMMENT ON TABLE ussd.session_checkpoints IS 'Session state checkpoints for restore capability';

-- =============================================================================
-- WORM TRIGGERS
-- =============================================================================

CREATE TRIGGER trg_jwt_tokens_prevent_update
    BEFORE UPDATE ON ussd.jwt_tokens
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_jwt_tokens_prevent_delete
    BEFORE DELETE ON ussd.jwt_tokens
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

CREATE TRIGGER trg_token_blacklist_prevent_update
    BEFORE UPDATE ON ussd.token_blacklist
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_token_blacklist_prevent_delete
    BEFORE DELETE ON ussd.token_blacklist
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

CREATE TRIGGER trg_api_keys_prevent_update
    BEFORE UPDATE ON app.api_keys
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_api_keys_prevent_delete
    BEFORE DELETE ON app.api_keys
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

CREATE TRIGGER trg_session_checkpoints_prevent_update
    BEFORE UPDATE ON ussd.session_checkpoints
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_session_checkpoints_prevent_delete
    BEFORE DELETE ON ussd.session_checkpoints
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

COMMIT;
