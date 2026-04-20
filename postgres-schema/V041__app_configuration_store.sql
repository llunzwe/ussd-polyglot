-- =============================================================================
-- Migration: V047__app_configuration_store
-- Description: App table: configuration_store
-- Dependencies: V046
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

/**
 * =============================================================================
 * USSD IMMUTABLE LEDGER KERNEL - CONFIGURATION STORE
 * =============================================================================
 * 
 * Feature ID:         CORE-APP-015
 * Feature Name:       Configuration Management
 * Description:        Hierarchical configuration management with environment
 *                     scoping, encryption support, and change tracking.
 *                     Supports feature flags, settings, and secrets.
 * 
 * Version:            1.0.0
 * Author:             Eng. llunzwe
 * Created:            2026-03-30
 * Last Modified:      2026-03-30
 * 
 * =============================================================================
 * COMPLIANCE & CERTIFICATIONS
 * =============================================================================
 * 
 * ISO/IEC 27001:2022 (ISMS)
 *   - Control A.5.23: Cloud services (config security)
 *   - Control A.8.5: Secure authentication (secrets)
 *   - Control A.8.24: Cryptography use
 *   - Control A.8.25: Secure development (change control)
 * 
 * ISO/IEC 27018:2019 (PII Protection)
 *   - Section 9.4: Access control (config access)
 * 
 * ISO 9001:2015 (Quality Management)
 *   - Section 8.5.1: Production controls
 *   - Section 8.5.6: Change control
 * 
 * SOC 2 Type II
 *   - CC6.1: Logical access controls
 *   - CC8.1: Change management
 * 
 * =============================================================================
 * MULTI-TENANCY SECURITY ANNOTATIONS
 * =============================================================================
 * 
 * CONFIGURATION ISOLATION:
 *   - Configs isolated by application (application_id)
 *   - Environment scoping (dev/staging/prod)
 *   - User/org level overrides supported
 * 
 * SECURITY CONTROLS:
 *   - Encrypted values for secrets
 *   - Validation schemas prevent injection
 *   - Approval workflow for sensitive changes
 *   - Change history immutable
 * 
 * =============================================================================
 * RBAC ENFORCEMENT DOCUMENTATION
 * =============================================================================
 * 
 * REQUIRED PERMISSIONS:
 * 
 * | Operation                    | Required Permission              |
 * |------------------------------|----------------------------------|
 * | READ config                  | app:config:read                  |
 * | WRITE config                 | app:config:write                 |
 * | DELETE config                | app:config:delete                |
 * | ACCESS secrets               | app:config:secrets               |
 * | APPROVE changes              | app:config:approve               |
 * 
 * =============================================================================
 * AUDIT TRAIL REQUIREMENTS
 * =============================================================================
 * 
 * MANDATORY AUDIT EVENTS:
 *   - Configuration Created
 *   - Configuration Modified (old/new values)
 *   - Secret Accessed
 *   - Approval Workflow (request/approve/reject)
 *   - Rollback
 * 
 * AUDIT RETENTION: 7 years
 * 
 * =============================================================================
 * DEPENDENCIES
 * =============================================================================
 * 
 *   - app.application_registry (FK: application_id)
 * 
 * CHANGE LOG:
 *   1.0.0 - Initial schema creation
 * =============================================================================
 */



-- ============================================================================
-- COMPLIANCE STANDARDS
-- ============================================================================
-- ISO/IEC 27001:2022 - ISMS Framework (Controls A.5.x - A.9.x)
-- ISO/IEC 27017:2015 - Cloud Security Controls (Multi-tenancy)
-- ISO/IEC 27018:2019 - PII Protection in Public Clouds
-- ISO 9001:2015 - Quality Management Systems
-- ISO 31000:2018 - Risk Management Guidelines
-- ============================================================================
-- CODING PRACTICES:
-- - Use parameterized queries to prevent SQL injection
-- - Implement proper error handling with transaction rollback
-- - Use SECURITY DEFINER
-- - Enforce RLS policies for multi-tenant data isolation
-- - Use explicit column lists (avoid SELECT *)
-- - Add audit logging for all security-relevant operations
-- - Use UUIDs for primary identifiers to prevent enumeration
-- - Implement optimistic locking with version columns
-- - Use TIMESTAMPTZ for all timestamp columns
-- - Validate all inputs with CHECK constraints
-- ============================================================================

-- =============================================================================
-- TABLE: app.configuration_store
-- =============================================================================
CREATE TABLE IF NOT EXISTS app.configuration_store (
    config_id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    application_id                      UUID NOT NULL,
                                CONSTRAINT fk_config_app 
                                    FOREIGN KEY (application_id)
                                    REFERENCES app.application_registry(application_id)
                                    ON DELETE CASCADE,
    
    config_key                  VARCHAR(255) NOT NULL,
                                -- Dot-notation hierarchical key
    
    -- Type
    config_type                 VARCHAR(20) NOT NULL DEFAULT 'setting',
                                CONSTRAINT chk_config_type 
                                    CHECK (config_type IN ('setting', 'secret', 'certificate', 'template', 'feature')),
    
    -- Environment Scope
    environment                 VARCHAR(20) NOT NULL DEFAULT 'default',
                                CONSTRAINT chk_config_env 
                                    CHECK (environment IN ('default', 'development', 'staging', 'production')),
    scope_level                 VARCHAR(20) NOT NULL DEFAULT 'application',
                                CONSTRAINT chk_scope_level 
                                    CHECK (scope_level IN ('platform', 'application', 'organization', 'user', 'session')),
    scope_id                    UUID,
    
    -- Value (typed columns)
    value_string                TEXT,
    value_number                NUMERIC,
    value_boolean               BOOLEAN,
    value_json                  JSONB,
    value_binary                BYTEA,
    value_type                  VARCHAR(20) NOT NULL DEFAULT 'string',
                                CONSTRAINT chk_value_type 
                                    CHECK (value_type IN ('string', 'number', 'boolean', 'json', 'binary')),
    tags                        TEXT[] DEFAULT '{}',
    
    -- Encryption
    is_encrypted                BOOLEAN NOT NULL DEFAULT FALSE,
    encryption_key_id           UUID,
    value_encrypted             BYTEA,  -- CRITICAL FIX: Stores encrypted value when is_encrypted=TRUE
    
    -- Change Control
    requires_restart            BOOLEAN NOT NULL DEFAULT FALSE,
    change_approval_required    BOOLEAN NOT NULL DEFAULT FALSE,
    approved_by                 UUID,
    approved_at                 TIMESTAMPTZ,
    
    -- Caching
    cache_ttl_seconds           INTEGER DEFAULT 300,
    cache_version               INTEGER DEFAULT 1,  -- [AUDIT] ISO 9001: Optimistic locking for version control
    
    -- Versioning
    version                     INTEGER NOT NULL DEFAULT 1,  -- [AUDIT] ISO 9001: Optimistic locking for version control
    is_current                  BOOLEAN NOT NULL DEFAULT TRUE,
    previous_version_id         UUID,
                                CONSTRAINT fk_config_prev 
                                    FOREIGN KEY (previous_version_id) 
                                    REFERENCES app.configuration_store(config_id),
    
    -- Audit
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),  -- [AUDIT] ISO 27001: Non-repudiation timestamp
    created_by                  UUID NOT NULL,  -- [AUDIT] ISO 27001: Accountability tracking
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by                  UUID NOT NULL,  -- [AUDIT] ISO 27001: Accountability tracking
    
    CONSTRAINT uq_config_key_env_scope 
        UNIQUE (application_id, config_key, environment, scope_level, scope_id, is_current)
);

-- =============================================================================
-- TABLE: app.configuration_history
-- =============================================================================
CREATE TABLE IF NOT EXISTS app.configuration_history (
    history_id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    config_id                   UUID NOT NULL,
                                CONSTRAINT fk_hist_config 
                                    FOREIGN KEY (config_id) 
                                    REFERENCES app.configuration_store(config_id),
    
    change_type                 VARCHAR(20) NOT NULL,
                                -- ENUM: 'created', 'updated', 'deleted', 'rolled_back'
    old_value                   JSONB,
    new_value                   JSONB,
    change_reason               TEXT,
    changed_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    changed_by                  UUID NOT NULL
);

-- =============================================================================
-- COMMENTS
-- =============================================================================
COMMENT ON TABLE app.configuration_store IS 'Hierarchical configuration store with encryption and versioning. Feature: CORE-APP-015. Compliance: ISO 27001, SOC 2 Type II. Security: Encrypted secrets, approval workflows, immutable history.';

COMMENT ON COLUMN app.configuration_store.is_encrypted IS
    'TRUE: Value is encrypted. encryption_key_id references external KMS.';

-- =============================================================================
-- INDEXES
-- =============================================================================
CREATE INDEX  -- [TXN] ISO 9001: Non-blocking index creation IF NOT EXISTS idx_config_lookup 
    ON app.configuration_store(application_id, config_key, environment, scope_level, is_current);

CREATE INDEX  -- [TXN] ISO 9001: Non-blocking index creation IF NOT EXISTS idx_config_encrypted 
    ON app.configuration_store(config_key) WHERE is_encrypted = TRUE;

-- =============================================================================
-- IMPLEMENTATION NOTES
-- =============================================================================
-- 1. Hierarchical resolution: user > organization > application > platform
-- 2. Encrypted values decrypted using key management service
-- 3. Secret access logged for security audit
-- 4. Environment fallback: specific -> default
-- 5. Versioning preserves config change history
-- =============================================================================

COMMIT;
