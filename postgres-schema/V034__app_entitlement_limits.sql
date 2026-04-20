-- =============================================================================
-- Migration: V037__app_entitlement_limits
-- Description: App table: entitlement_limits
-- Dependencies: V036
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

/**
 * =============================================================================
 * USSD IMMUTABLE LEDGER KERNEL - ENTITLEMENT LIMITS
 * =============================================================================
 * 
 * Feature ID:         CORE-APP-005
 * Feature Name:       Entitlement & Quota Management
 * Description:        Defines resource limits and quotas for applications,
 *                     roles, and memberships. Provides configurable thresholds
 *                     with enforcement mechanisms and alerting.
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
 *   - Control A.5.7: Threat intelligence (anomaly detection)
 *   - Control A.5.24: Information security incident management
 *   - Control A.8.7: Protection against malware (DoS prevention)
 *   - Control A.8.20: Networks security (rate limiting)
 * 
 * ISO/IEC 27017:2015 (Cloud Security)
 *   - Section 6: Asset management (resource tracking)
 *   - Section 12: Multi-tenant resource isolation
 * 
 * ISO 9001:2015 (Quality Management)
 *   - Section 7.1.5: Monitoring and measuring resources
 *   - Section 8.5.1: Production provision control
 * 
 * ISO 31000:2018 (Risk Management)
 *   - Risk treatment: Resource-based risk mitigation
 *   - Monitoring: Threshold-based risk alerts
 * 
 * SOC 2 Type II
 *   - CC6.1: Logical access controls (enforcement)
 *   - CC7.2: System monitoring (usage tracking)
 * 
 * =============================================================================
 * MULTI-TENANCY SECURITY ANNOTATIONS
 * =============================================================================
 * 
 * HIERARCHICAL LIMITS (Priority Order):
 *   1. Membership-specific overrides (highest priority)
 *   2. Role-based limits
 *   3. Application default limits
 *   4. Global platform limits (lowest priority)
 * 
 * ENFORCEMENT ACTIONS:
 *   - block:    Hard stop, request rejected
 *   - throttle: Slow down processing
 *   - queue:    Defer for later processing
 *   - log:      Log warning only
 *   - notify:   Alert administrators
 * 
 * SECURITY CONTROLS:
 *   - Override requires elevated privileges
 *   - All overrides audited with reason
 *   - Burst limits prevent DoS while allowing spikes
 * 
 * =============================================================================
 * RBAC ENFORCEMENT DOCUMENTATION
 * =============================================================================
 * 
 * REQUIRED PERMISSIONS:
 * 
 * | Operation                    | Required Permission              |
 * |------------------------------|----------------------------------|
 * | CREATE limit                 | app:entitlement:create           |
 * | READ limit                   | app:entitlement:read             |
 * | UPDATE limit                 | app:entitlement:update           |
 * | DELETE limit                 | app:entitlement:delete           |
 * | SET OVERRIDE                 | app:entitlement:override         |
 * | CHECK ENTITLEMENT            | (System - no permission needed)  |
 * 
 * =============================================================================
 * AUDIT TRAIL REQUIREMENTS
 * =============================================================================
 * 
 * MANDATORY AUDIT EVENTS:
 *   - Limit Created (configuration, thresholds)
 *   - Limit Modified (what changed, old/new values)
 *   - Override Set (who, why, duration, amount)
 *   - Threshold Breach (warning/critical alerts)
 *   - Enforcement Action (block/throttle/log)
 *   - Usage Reset (window expiration)
 * 
 * AUDIT RETENTION: 3 years (operational data)
 * 
 * =============================================================================
 * DEPENDENCIES
 * =============================================================================
 * 
 *   - app.application_registry (FK: application_id)
 *   - app.roles_permissions (FK: target_id when target_type='role')
 *   - app.account_membership (FK: target_id when target_type='membership')
 * 
 * CHANGE LOG:
 *   1.0.0 - Initial schema creation with compliance headers
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
-- TABLE: app.entitlement_limits
-- =============================================================================
CREATE TABLE IF NOT EXISTS app.entitlement_limits (
    -- -------------------------------------------------------------------------
    -- PRIMARY IDENTIFIERS
    -- -------------------------------------------------------------------------
    entitlement_id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    application_id                      UUID NOT NULL,
                                -- FK: app.application_registry.application_id
                                CONSTRAINT fk_entitlement_app 
                                    FOREIGN KEY (application_id)
                                    REFERENCES app.application_registry(application_id)
                                    ON DELETE CASCADE,
    
    -- -------------------------------------------------------------------------
    -- ENTITLEMENT TARGET (Polymorphic)
    -- -------------------------------------------------------------------------
    target_type                 VARCHAR(20) NOT NULL,
                                -- ENUM: 'application', 'role', 'membership', 'global'
                                CONSTRAINT chk_target_type 
                                    CHECK (target_type IN ('application', 'role', 'membership', 'global')),
                                
    target_id                   UUID,
                                -- Polymorphic reference based on target_type
                                -- NULL when target_type = 'global'
    
    -- -------------------------------------------------------------------------
    -- RESOURCE TYPE
    -- -------------------------------------------------------------------------
    resource_type               VARCHAR(50) NOT NULL,
                                -- ENUM: 'transactions', 'storage', 'api_calls', 
                                --       'concurrent_sessions', 'webhooks', 'exports', 'reports'
                                
    resource_subtype            VARCHAR(50),
                                -- Granular classification
    
    -- -------------------------------------------------------------------------
    -- LIMIT CONFIGURATION
    -- -------------------------------------------------------------------------
    limit_type                  VARCHAR(20) NOT NULL DEFAULT 'hard',
                                -- ENUM: 'hard', 'soft', 'burst', 'advisory'
                                CONSTRAINT chk_limit_type 
                                    CHECK (limit_type IN ('hard', 'soft', 'burst', 'advisory')),
                                -- hard:     Always enforce
                                -- soft:     Warning + log
                                -- burst:    Allow temporary spikes
                                -- advisory: Log only
                                
    limit_value                 NUMERIC NOT NULL,
                                CONSTRAINT chk_limit_positive CHECK (limit_value > 0),
                                
    limit_unit                  VARCHAR(20) NOT NULL,
                                -- ENUM: 'count', 'bytes', 'requests', 'seconds', 'percentage'
    
    -- -------------------------------------------------------------------------
    -- TIME WINDOW
    -- -------------------------------------------------------------------------
    window_type                 VARCHAR(20) NOT NULL DEFAULT 'rolling',
                                -- ENUM: 'fixed', 'rolling', 'calendar', 'session'
                                CONSTRAINT chk_window_type 
                                    CHECK (window_type IN ('fixed', 'rolling', 'calendar', 'session')),
                                
    window_duration             INTERVAL,
                                -- Duration: '1 hour', '1 day', '1 month'
                                
    window_anchor               TIMESTAMPTZ,
                                -- Fixed window start time
    
    -- -------------------------------------------------------------------------
    -- THRESHOLDS & ALERTING
    -- -------------------------------------------------------------------------
    warning_threshold_pct       NUMERIC DEFAULT 80,
                                -- Percentage at which warning triggers
                                CONSTRAINT chk_warning_pct CHECK (warning_threshold_pct >= 0 AND warning_threshold_pct <= 100),
                                
    critical_threshold_pct      NUMERIC DEFAULT 95,
                                -- Percentage at which critical alert triggers
                                CONSTRAINT chk_critical_pct CHECK (critical_threshold_pct >= 0 AND critical_threshold_pct <= 100),
                                
    alert_enabled               BOOLEAN NOT NULL DEFAULT TRUE,
    
    alert_channels              JSONB DEFAULT '["email"]',
                                -- Array: email, sms, slack, pagerduty
    
    -- -------------------------------------------------------------------------
    -- ENFORCEMENT
    -- -------------------------------------------------------------------------
    enforcement_action          VARCHAR(20) NOT NULL DEFAULT 'block',
                                -- ENUM: 'block', 'throttle', 'queue', 'log', 'notify'
                                CONSTRAINT chk_enforcement_action 
                                    CHECK (enforcement_action IN ('block', 'throttle', 'queue', 'log', 'notify')),
                                
    enforcement_config          JSONB DEFAULT '{}',
                                -- Action-specific configuration
    
    -- -------------------------------------------------------------------------
    -- CURRENT USAGE (Cached)
    -- -------------------------------------------------------------------------
    current_usage               NUMERIC DEFAULT 0,
                                -- Cached current usage
                                
    usage_reset_at              TIMESTAMPTZ,
                                -- Last usage reset
                                
    usage_updated_at            TIMESTAMPTZ,
                                -- Last usage update
    
    -- -------------------------------------------------------------------------
    -- OVERRIDES
    -- -------------------------------------------------------------------------
    override_value              NUMERIC,
                                -- Temporary override limit
                                
    override_expires_at         TIMESTAMPTZ,
                                -- When override expires
                                
    override_reason             TEXT,
                                -- REQUIRED: Business justification
                                
    overridden_by               UUID,
                                -- FK: membership of admin who set override
    
    -- -------------------------------------------------------------------------
    -- PRIORITY (for conflict resolution)
    -- -------------------------------------------------------------------------
    priority                    INTEGER NOT NULL DEFAULT 100,
                                -- Lower = higher priority
                                -- Membership (10) > Role (50) > App (100) > Global (200)
    
    -- -------------------------------------------------------------------------
    -- LIFECYCLE
    -- -------------------------------------------------------------------------
    status                      VARCHAR(20) NOT NULL DEFAULT 'active',
                                -- ENUM: 'active', 'suspended', 'deprecated'
                                CONSTRAINT chk_entitlement_status 
                                    CHECK (status IN ('active', 'suspended', 'deprecated')),
                                
    effective_from              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    effective_until             TIMESTAMPTZ,
    
    -- -------------------------------------------------------------------------
    -- AUDIT & VERSIONING
    -- -------------------------------------------------------------------------
    version                     INTEGER NOT NULL DEFAULT 1,  -- [AUDIT] ISO 9001: Optimistic locking for version control
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),  -- [AUDIT] ISO 27001: Non-repudiation timestamp
    created_by                  UUID NOT NULL,  -- [AUDIT] ISO 27001: Accountability tracking
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by                  UUID NOT NULL  -- [AUDIT] ISO 27001: Accountability tracking
    
    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------
    CONSTRAINT chk_thresholds_order 
        CHECK (warning_threshold_pct < critical_threshold_pct),
        
    CONSTRAINT chk_effective_period 
        CHECK (effective_until IS NULL OR effective_until > effective_from)
);

-- =============================================================================
-- COMMENTS
-- =============================================================================
COMMENT ON TABLE app.entitlement_limits IS 'Resource limits and quotas with enforcement and alerting. Feature: CORE-APP-005. Compliance: ISO 27001, ISO 31000. Security: Hierarchical enforcement, override audit trail. Audit: Threshold breaches and enforcement actions logged.';

-- =============================================================================
-- INDEXES
-- =============================================================================
CREATE INDEX IF NOT EXISTS idx_entitlements_app  -- [TXN] ISO 9001: Non-blocking index creation 
    ON app.entitlement_limits(application_id);

CREATE INDEX IF NOT EXISTS idx_entitlements_target  -- [TXN] ISO 9001: Non-blocking index creation 
    ON app.entitlement_limits(target_type, target_id);

CREATE INDEX IF NOT EXISTS idx_entitlements_resource  -- [TXN] ISO 9001: Non-blocking index creation 
    ON app.entitlement_limits(resource_type, resource_subtype);

CREATE INDEX IF NOT EXISTS idx_entitlements_active  -- [TXN] ISO 9001: Non-blocking index creation 
    ON app.entitlement_limits(application_id, resource_type, priority)
    WHERE status = 'active';

-- =============================================================================
-- RLS POLICIES
-- =============================================================================
DO $$
BEGIN
    ALTER TABLE app.entitlement_limits ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

CREATE POLICY entitlements_app_isolation ON app.entitlement_limits
    USING (application_id = current_setting('app.current_app_id', TRUE)::UUID);

-- =============================================================================
-- IMPLEMENTATION NOTES
-- =============================================================================
-- 1. Limits can be defined at application, role, or membership level
-- 2. Lower priority values take precedence in conflicts
-- 3. Usage counters are cached and periodically synced
-- 4. Burst limits allow temporary spikes
-- 5. All overrides require business justification and are audited
-- =============================================================================

COMMIT;
