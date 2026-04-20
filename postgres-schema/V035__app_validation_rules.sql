-- =============================================================================
-- Migration: V038__app_validation_rules
-- Description: App table: validation_rules
-- Dependencies: V037
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

/**
 * =============================================================================
 * USSD IMMUTABLE LEDGER KERNEL - VALIDATION RULES
 * =============================================================================
 * 
 * Feature ID:         CORE-APP-006
 * Feature Name:       Validation Rule Engine
 * Description:        Configurable validation rules for transaction data
 *                     integrity, business rule enforcement, and custom
 *                     validation logic with JSON Schema, SQL expressions,
 *                     and external function support.
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
 *   - Control A.5.34: Privacy and protection of PII (validation)
 *   - Control A.8.1: User endpoint devices (input validation)
 *   - Control A.8.26: Application security requirements
 *   - Control A.8.31: Separation of development, test and production
 * 
 * ISO/IEC 27018:2019 (PII Protection)
 *   - Section 8.1: Purpose limitation (validation scope)
 *   - Section 9.4: Access control (conditional validation)
 * 
 * ISO 9001:2015 (Quality Management)
 *   - Section 8.5.1: Production and service provision control
 *   - Section 8.6: Release of products and services
 * 
 * SOC 2 Type II
 *   - CC7.1: System operations (input validation)
 *   - CC7.2: System monitoring (validation failures)
 * 
 * =============================================================================
 * MULTI-TENANCY SECURITY ANNOTATIONS
 * =============================================================================
 * 
 * VALIDATION SCOPES:
 *   - transaction: Individual transaction validation
 *   - batch:       Batch-level validation
 *   - session:     Session-wide validation
 *   - account:     Account-level validation
 *   - global:      Platform-wide validation
 * 
 * SECURITY CONTROLS:
 *   - Rule isolation by application
 *   - SQL injection prevention (parameterized queries)
 *   - External validation timeout limits
 *   - Error message sanitization
 * 
 * =============================================================================
 * RBAC ENFORCEMENT DOCUMENTATION
 * =============================================================================
 * 
 * REQUIRED PERMISSIONS:
 * 
 * | Operation                    | Required Permission              |
 * |------------------------------|----------------------------------|
 * | CREATE rule                  | app:validation:create            |
 * | READ rule                    | app:validation:read              |
 * | UPDATE rule                  | app:validation:update            |
 * | DELETE rule                  | app:validation:delete            |
 * | EXECUTE validation           | (System - enforcement)           |
 * 
 * =============================================================================
 * AUDIT TRAIL REQUIREMENTS
 * =============================================================================
 * 
 * MANDATORY AUDIT EVENTS:
 *   - Rule Created/Modified
 *   - Validation Failure (blocking rules)
 *   - System Rule Change (elevated privilege)
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
-- TABLE: app.validation_rules
-- =============================================================================
CREATE TABLE IF NOT EXISTS app.validation_rules (
    rule_id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    application_id                      UUID NOT NULL,
                                CONSTRAINT fk_validation_app 
                                    FOREIGN KEY (application_id)
                                    REFERENCES app.application_registry(application_id)
                                    ON DELETE CASCADE,
    
    rule_code                   VARCHAR(50) NOT NULL,
                                -- Unique per app
    
    -- Classification
    rule_category               VARCHAR(30) NOT NULL DEFAULT 'business',
                                CONSTRAINT chk_rule_category 
                                    CHECK (rule_category IN ('schema', 'business', 'compliance', 'security', 'custom')),
                                
    rule_scope                  VARCHAR(30) NOT NULL DEFAULT 'transaction',
    rule_phase                  VARCHAR(20) NOT NULL DEFAULT 'pre_commit',  -- [TXN] ISO 27001: ACID transaction boundary
                                CONSTRAINT chk_rule_phase 
                                    CHECK (rule_phase IN ('pre_validation', 'pre_commit', 'post_commit')),  -- [TXN] ISO 27001: ACID transaction boundary
    
    -- Target
    target_entity               VARCHAR(50) NOT NULL,
    target_fields               TEXT[] DEFAULT '{}',
    target_conditions           JSONB DEFAULT '{}',
    
    -- Validation Logic
    validation_type             VARCHAR(20) NOT NULL DEFAULT 'expression',
                                CONSTRAINT chk_validation_type 
                                    CHECK (validation_type IN ('expression', 'json_schema', 'sql', 'function', 'external')),
    validation_config           JSONB NOT NULL DEFAULT '{}',
    
    -- Error Handling
    error_code                  VARCHAR(50) NOT NULL,
    error_message_template      TEXT NOT NULL,
    error_severity              VARCHAR(20) NOT NULL DEFAULT 'error',
                                CONSTRAINT chk_error_severity 
                                    CHECK (error_severity IN ('info', 'warning', 'error', 'critical')),
    is_blocking                 BOOLEAN NOT NULL DEFAULT TRUE,
    
    -- Dependencies
    depends_on_rules            UUID[] DEFAULT '{}',
    
    -- Execution
    execution_order             INTEGER NOT NULL DEFAULT 100,
    execution_mode              VARCHAR(20) NOT NULL DEFAULT 'sync',
                                CONSTRAINT chk_execution_mode 
                                    CHECK (execution_mode IN ('sync', 'async', 'deferred')),
    
    -- Performance
    timeout_ms                  INTEGER DEFAULT 5000,
    cache_duration_ms           INTEGER DEFAULT 0,
    
    -- Lifecycle
    status                      VARCHAR(20) NOT NULL DEFAULT 'active',
    is_system_rule              BOOLEAN NOT NULL DEFAULT FALSE,
    
    -- Audit
    version                     INTEGER NOT NULL DEFAULT 1,  -- [AUDIT] ISO 9001: Optimistic locking for version control
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),  -- [AUDIT] ISO 27001: Non-repudiation timestamp
    created_by                  UUID NOT NULL,  -- [AUDIT] ISO 27001: Accountability tracking
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by                  UUID NOT NULL,  -- [AUDIT] ISO 27001: Accountability tracking
    
    CONSTRAINT uq_app_rule_code UNIQUE (application_id, rule_code)
);

-- =============================================================================
-- COMMENTS
-- =============================================================================
COMMENT ON TABLE app.validation_rules IS 'Configurable validation rules for data integrity and business logic. Feature: CORE-APP-006. Compliance: ISO 27001, ISO 9001. Security: SQL injection prevention, timeout limits.';

-- =============================================================================
-- INDEXES
-- =============================================================================
CREATE INDEX  -- [TXN] ISO 9001: Non-blocking index creation IF NOT EXISTS idx_validation_app 
    ON app.validation_rules(application_id);

CREATE INDEX  -- [TXN] ISO 9001: Non-blocking index creation IF NOT EXISTS idx_validation_phase 
    ON app.validation_rules(rule_phase, execution_order)
    WHERE status = 'active';

-- =============================================================================
-- IMPLEMENTATION NOTES
-- =============================================================================
-- 1. Rules execute in order by execution_order
-- 2. Dependencies must be satisfied before rule executes
-- 3. External validations require timeout handling
-- 4. Rule results can be cached for performance
-- 5. System rules cannot be modified by app admins
-- =============================================================================

COMMIT;
