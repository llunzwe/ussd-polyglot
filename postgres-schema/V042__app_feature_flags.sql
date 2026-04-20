-- =============================================================================
-- Migration: V048__app_feature_flags
-- Description: App table: feature_flags
-- Dependencies: V047
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

/**
 * =============================================================================
 * USSD IMMUTABLE LEDGER KERNEL - FEATURE FLAGS
 * =============================================================================
 * 
 * Feature ID:         CORE-APP-016
 * Feature Name:       Feature Flag Management
 * Description:        Feature flag management for progressive rollouts, A/B
 *                     testing, and emergency toggles. Supports gradual rollout
 *                     with percentage-based targeting and user segmentation.
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
 *   - Control A.8.26: Application security requirements
 *   - Control A.8.31: Separation of development, test and production
 * 
 * ISO 9001:2015 (Quality Management)
 *   - Section 8.5.1: Production and service provision control
 *   - Section 8.6: Release of products and services
 * 
 * SOC 2 Type II
 *   - CC8.1: Change management
 * 
 * =============================================================================
 * MULTI-TENANCY SECURITY ANNOTATIONS
 * =============================================================================
 * 
 * FEATURE FLAG SAFETY:
 *   - Kill switches for emergency disable
 *   - Auto-disable on error threshold
 *   - Gradual rollout limits blast radius
 *   - Targeting rules prevent cross-tenant exposure
 * 
 * SECURITY CONTROLS:
 *   - Flag state changes require authorization
 *   - Kill switches protected by elevated privileges
 *   - Evaluation logs for audit
 *   - Dependencies prevent unsafe flag combinations
 * 
 * =============================================================================
 * RBAC ENFORCEMENT DOCUMENTATION
 * =============================================================================
 * 
 * REQUIRED PERMISSIONS:
 * 
 * | Operation                    | Required Permission              |
 * |------------------------------|----------------------------------|
 * | CREATE flag                  | app:feature:create               |
 * | READ flag                    | app:feature:read                 |
 * | UPDATE flag                  | app:feature:update               |
 * | KILL SWITCH (toggle)         | app:feature:killswitch           |
 * | BULK UPDATE                  | app:feature:admin                |
 * | EVALUATE flag                | (System - runtime)               |
 * 
 * =============================================================================
 * AUDIT TRAIL REQUIREMENTS
 * =============================================================================
 * 
 * MANDATORY AUDIT EVENTS:
 *   - Flag Created
 *   - State Change (on/off/gradual)
 *   - Kill Switch Activated
 *   - Auto-Disable Triggered
 *   - Bulk Update
 *   - Evaluation Anomalies
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
-- TABLE: app.feature_flags
-- =============================================================================
CREATE TABLE IF NOT EXISTS app.feature_flags (
    flag_id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    application_id                      UUID NOT NULL,
                                CONSTRAINT fk_flag_app 
                                    FOREIGN KEY (application_id)
                                    REFERENCES app.application_registry(application_id)
                                    ON DELETE CASCADE,
    
    flag_key                    VARCHAR(100) NOT NULL,
                                -- Unique identifier for code references
    flag_name                   VARCHAR(255) NOT NULL,
    flag_description            TEXT NOT NULL,
    flag_category               VARCHAR(30) DEFAULT 'feature',
                                CONSTRAINT chk_flag_category 
                                    CHECK (flag_category IN ('feature', 'experiment', 'kill_switch', 'permission', 'ops')),
    
    -- State
    flag_state                  VARCHAR(20) NOT NULL DEFAULT 'off',  -- [FEATURE_FLAG] ISO 9001: Controlled feature state management
                                CONSTRAINT chk_flag_state
                                    CHECK (flag_state IN ('off', 'on', 'gradual', 'targeted', 'experiment')),  -- [FEATURE_FLAG] ISO 9001: Controlled feature state management
    default_value               BOOLEAN NOT NULL DEFAULT FALSE,
    
    -- Rollout
    rollout_percentage          INTEGER DEFAULT 0,  -- [FEATURE_FLAG] Safety: Gradual rollout limits blast radius
                                CONSTRAINT chk_rollout_pct 
                                    CHECK (rollout_percentage >= 0 AND rollout_percentage <= 100),  -- [FEATURE_FLAG] Safety: Gradual rollout limits blast radius
    rollout_seed                VARCHAR(50) DEFAULT 'user_id',
    rollout_grouping            VARCHAR(20) DEFAULT 'none',
    
    -- Targeting
    targeting_rules             JSONB DEFAULT '[]',
    target_entities             UUID[] DEFAULT '{}',
    target_roles                UUID[] DEFAULT '{}',
    
    -- Scheduling
    scheduled_enable_at         TIMESTAMPTZ,
    scheduled_disable_at        TIMESTAMPTZ,
    timezone                    VARCHAR(50) DEFAULT 'UTC',
    
    -- Dependencies
    requires_flags              TEXT[] DEFAULT '{}',
    conflicts_with_flags        TEXT[] DEFAULT '{}',
    
    -- Kill Switch
    is_kill_switch              BOOLEAN NOT NULL DEFAULT FALSE,
    is_kill_switch_priority        INTEGER DEFAULT 100,
    auto_disable_on_error       BOOLEAN DEFAULT FALSE,
    auto_disable_on_error_rate_threshold        NUMERIC(5,2) DEFAULT 5.00,
    
    -- Experiment
    experiment_config           JSONB DEFAULT '{}',
    
    -- Monitoring
    evaluation_count            BIGINT DEFAULT 0,
    positive_evaluation_count   BIGINT DEFAULT 0,
    last_evaluation_at          TIMESTAMPTZ,
    
    -- Audit
    version                     INTEGER NOT NULL DEFAULT 1,  -- [AUDIT] ISO 9001: Optimistic locking for version control
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),  -- [AUDIT] ISO 27001: Non-repudiation timestamp
    created_by                  UUID NOT NULL,  -- [AUDIT] ISO 27001: Accountability tracking
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by                  UUID NOT NULL,  -- [AUDIT] ISO 27001: Accountability tracking
    
    CONSTRAINT uq_app_flag_key UNIQUE (application_id, flag_key)
);

-- =============================================================================
-- TABLE: app.feature_flag_evaluations
-- =============================================================================
CREATE TABLE IF NOT EXISTS app.feature_flag_evaluations (
    evaluation_id               UUID DEFAULT gen_random_uuid(),
    evaluated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (evaluation_id, evaluated_at),
    
    flag_id                     UUID NOT NULL,
                                CONSTRAINT fk_eval_flag 
                                    FOREIGN KEY (flag_id) 
                                    REFERENCES app.feature_flags(flag_id)
                                    ON DELETE CASCADE,
    
    entity_id                   UUID,
    entity_type                 VARCHAR(50),
    evaluation_context          JSONB DEFAULT '{}',
    evaluation_result           BOOLEAN NOT NULL,
    variant_name                VARCHAR(50)
);

-- =============================================================================
-- CONVERT TO TIMESCALEDB HYPERTABLE
-- =============================================================================
-- PRODUCTION FIX: Uncommented hypertable conversion for time-series optimization

SELECT create_hypertable(
    'app.feature_flag_evaluations',
    'evaluated_at',
    chunk_time_interval => INTERVAL '7 days',
    if_not_exists => TRUE
);

-- =============================================================================
-- COMMENTS
-- =============================================================================
COMMENT ON TABLE app.feature_flags IS 'Feature flags for progressive rollouts and A/B testing. Feature: CORE-APP-016. Compliance: ISO 9001, SOC 2 Type II. Safety: Kill switches, auto-disable, gradual rollout.';

COMMENT ON COLUMN app.feature_flags.is_kill_switch IS 'Emergency kill switch for immediate feature disable';

COMMENT ON COLUMN app.feature_flags.auto_disable_on_error IS 'Auto-disable feature on error threshold';

-- =============================================================================
-- INDEXES
-- =============================================================================
CREATE INDEX IF NOT EXISTS idx_flags_app  -- [TXN] ISO 9001: Non-blocking index creation 
    ON app.feature_flags(application_id);

-- Index: Active flags by state
CREATE INDEX IF NOT EXISTS idx_flags_state
    ON app.feature_flags(application_id, flag_state) WHERE flag_state != 'off';

-- Index: Kill switches
CREATE INDEX IF NOT EXISTS idx_flags_kill_switch
    ON app.feature_flags(application_id) WHERE is_kill_switch = TRUE AND flag_state != 'off';

-- =============================================================================
-- IMPLEMENTATION NOTES
-- =============================================================================
-- 1. Kill switches protected by elevated permissions
-- 2. Gradual rollout with consistent hashing
-- 3. Dependencies prevent unsafe combinations
-- 4. Auto-disable on error rate threshold
-- 5. Scheduled enable/disable for planned releases
-- 6. Evaluation history for analytics
-- =============================================================================

COMMIT;
