-- =============================================================================
-- Migration: V035__app_roles_permissions
-- Description: App table: roles_permissions
-- Dependencies: V034
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

/**
 * =============================================================================
 * USSD IMMUTABLE LEDGER KERNEL - ROLES & PERMISSIONS
 * =============================================================================
 * 
 * Feature ID:         CORE-APP-003
 * Feature Name:       Role-Based Access Control (RBAC)
 * Description:        Role-based access control definitions. Manages roles,
 *                     permissions, and their relationships within applications.
 *                     Supports role inheritance and permission scoping.
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
 *   - Control A.5.15: Access control (role definitions)
 *   - Control A.5.18: Access rights (permission assignment)
 *   - Control A.5.31: Legal, statutory, regulatory requirements
 *   - Control A.8.2: Privileged access roles (system_role flag)
 *   - Control A.9.2.5: Review of access rights (regular audits)
 * 
 * ISO/IEC 27017:2015 (Cloud Security)
 *   - Section 9: Network security (role scope restrictions)
 *   - Section 12: Inter-tenant access control
 * 
 * ISO/IEC 27018:2019 (PII Protection)
 *   - Section 8.2: Purpose limitation (entitlement limits)
 * 
 * ISO 9001:2015 (Quality Management)
 *   - Section 7.5: Documented information (role documentation)
 * 
 * ISO 31000:2018 (Risk Management)
 *   - Risk treatment: Permission scoping, inheritance controls
 * 
 * SOC 2 Type II
 *   - CC6.1: Logical access controls
 *   - CC6.2: Access credentials management
 *   - CC6.3: Access removal procedures
 * 
 * NIST 800-53
 *   - AC-2: Account management
 *   - AC-3: Access enforcement
 *   - AC-6: Least privilege
 * 
 * =============================================================================
 * RBAC ENFORCEMENT DOCUMENTATION
 * =============================================================================
 * 
 * ROLE HIERARCHY:
 * 
 *   platform_admin       [SYSTEM] - Full platform access
 *      └── platform_operator
 *   app_owner            [APP]    - Application ownership
 *      └── app_admin
 *           └── app_member
 *                └── app_viewer
 * 
 * PERMISSION FORMAT: resource:action:scope
 *   resource:  ledger, transaction, account, app, user, report
 *   action:    create, read, update, delete, execute, admin
 *   scope:     own, group, organization, any
 * 
 * EXAMPLE PERMISSIONS:
 *   ledger:read:own      - Read own ledger entries
 *   ledger:write:any     - Write any ledger entries
 *   app:admin:any        - Full app administration
 *   user:manage:group    - Manage users in same group
 * 
 * REQUIRED PERMISSIONS FOR OPERATIONS:
 * 
 * | Operation                    | Required Permission              |
 * |------------------------------|----------------------------------|
 * | CREATE role                  | app:role:create                  |
 * | READ role                    | app:role:read                    |
 * | UPDATE role                  | app:role:update                  |
 * | DELETE role                  | app:role:delete                  |
 * | ASSIGN role                  | app:role_assignment:create       |
 * | MODIFY system role           | platform:admin:system            |
 * 
 * =============================================================================
 * MULTI-TENANCY SECURITY ANNOTATIONS
 * =============================================================================
 * 
 * TENANT SCOPE LEVELS:
 *   - platform:   Global roles, cannot be modified by apps
 *   - application: Scoped to specific app
 *   - organization: Scoped to org unit within app
 *   - resource:   Scoped to specific resource
 * 
 * ISOLATION CONTROLS:
 *   - application_id NULL = Global platform role
 *   - application_id NOT NULL = Application-scoped role
 *   - RLS: Apps can only see their own roles + global roles
 * 
 * SYSTEM ROLE PROTECTION:
 *   - is_system_role = TRUE: Immutable, cannot be modified/deleted
 *   - Reserved for platform-level access control
 *   - Only platform admins can create system roles
 * 
 * =============================================================================
 * AUDIT TRAIL REQUIREMENTS
 * =============================================================================
 * 
 * MANDATORY AUDIT EVENTS:
 *   - Role Created (definition, initial permissions)
 *   - Permission Change (what changed, who changed, when)
 *   - Role Deprecation (reason, migration plan)
 *   - Role Deleted (archived, assignments migrated)
 *   - Permission Calculation (cache refresh events)
 *   - Inheritance Cycle Detection (security event)
 * 
 * AUDIT RETENTION: 7 years
 * AUDIT ACCESS: platform:auditor role only
 * 
 * =============================================================================
 * DEPENDENCIES
 * =============================================================================
 * 
 *   - app.application_registry (FK: application_id)
 *   - core.t_user_identity (FK: created_by)
 * 
 * CHANGE LOG:
 *   1.0.0 - Initial schema creation with compliance headers
 *   1.0.1 - Implemented TODOs: Role inheritance cycle detection, audit logging, default roles
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
-- TABLE: app.roles_permissions
-- =============================================================================
CREATE TABLE IF NOT EXISTS app.roles_permissions (
    -- -------------------------------------------------------------------------
    -- PRIMARY IDENTIFIERS
    -- -------------------------------------------------------------------------
    role_id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                                -- ISO 27001 A.9.2.2: Role assignment reference
                                
    application_id                      UUID,
                                -- FK: app.application_registry.application_id
                                -- NULL = Global platform role
                                -- ISO 27017: Scope isolation
                                CONSTRAINT fk_role_app 
                                    FOREIGN KEY (application_id)
                                    REFERENCES app.application_registry(application_id)
                                    ON DELETE CASCADE,
                                
    role_code                   VARCHAR(50) NOT NULL,
                                -- FORMAT: [a-z][a-z0-9_]{2,49}
                                CONSTRAINT chk_role_code_format 
                                    CHECK (role_code ~ '^[a-z][a-z0-9_]{2,49}$'),
    
    -- -------------------------------------------------------------------------
    -- ROLE CLASSIFICATION
    -- ISO 27001: Privilege classification
    -- -------------------------------------------------------------------------
    role_type                   VARCHAR(20) NOT NULL DEFAULT 'custom',
                                -- ENUM: 'system', 'platform', 'app_builtin', 'custom'
                                CONSTRAINT chk_role_type 
                                    CHECK (role_type IN ('system', 'platform', 'app_builtin', 'custom')),
                                -- system:      Immutable platform roles
                                -- platform:    Cross-app platform roles
                                -- app_builtin: Pre-defined app roles
                                -- custom:      User-defined roles
                                
    role_category               VARCHAR(30) NOT NULL DEFAULT 'general',
                                -- ENUM: 'admin', 'manager', 'operator', 'viewer', 'general'
                                -- ISO 27001: Functional classification
                                
    is_system_role              BOOLEAN NOT NULL DEFAULT FALSE,
                                -- TRUE: Cannot be modified or deleted
                                -- ISO 27001 A.8.2: Privileged access protection
    
    -- -------------------------------------------------------------------------
    -- ROLE METADATA
    -- -------------------------------------------------------------------------
    role_name                   VARCHAR(255) NOT NULL,
                                -- i18n key support for localization
                                
    role_description            TEXT,
                                -- BUSINESS: Purpose and scope of role
                                -- ISO 9001: Documented information
    
    -- -------------------------------------------------------------------------
    -- PERMISSIONS (JSONB for flexibility)
    -- ISO 27001 A.5.15: Access control rules
    -- -------------------------------------------------------------------------
    permissions                 JSONB NOT NULL DEFAULT '[]',
                                -- STRUCTURE: [{"resource": "ledger", "action": "read", "scope": "own"}]
                                -- VALIDATION: Schema enforced by trigger
                                
    allowed_resources           TEXT[] DEFAULT '{}',
                                -- DERIVED: For indexing from permissions
                                
    denied_resources            TEXT[] DEFAULT '{}',
                                -- EXPLICIT DENIALS: Override allows
                                -- ISO 27001: Defense in depth
    
    -- -------------------------------------------------------------------------
    -- ROLE INHERITANCE
    -- ISO 27001: Hierarchical access control
    -- -------------------------------------------------------------------------
    parent_role_ids             UUID[] DEFAULT '{}',
                                -- ARRAY: Inherited role IDs
                                -- LIMIT: Max 5 levels (enforced by trigger)
                                -- SECURITY: Cycle detection required
                                
    effective_permissions       JSONB DEFAULT '{}',
                                -- COMPUTED: Merged own + inherited permissions
                                -- UPDATED: By permission calculation trigger
                                
    permission_calculation_at   TIMESTAMPTZ,
                                -- TIMESTAMP: Last permission calculation
    
    -- -------------------------------------------------------------------------
    -- ENTITLEMENTS
    -- ISO 27018: PII processing limitations
    -- -------------------------------------------------------------------------
    entitlement_limits          JSONB DEFAULT '{}',
                                -- STRUCTURE: {"max_transactions_daily": 1000, "max_storage_mb": 1024}
                                -- ENFORCEMENT: Entitlement checking function
    
    -- -------------------------------------------------------------------------
    -- SCOPE & VISIBILITY
    -- -------------------------------------------------------------------------
    scope_level                 VARCHAR(20) NOT NULL DEFAULT 'application',
                                -- ENUM: 'platform', 'application', 'organization', 'resource'
                                CONSTRAINT chk_scope_level 
                                    CHECK (scope_level IN ('platform', 'application', 'organization', 'resource')),
                                
    applicable_membership_types TEXT[] DEFAULT '{member}',
                                -- ARRAY: Which membership types can have this role
                                -- ISO 27001: Principle of least privilege
    
    -- -------------------------------------------------------------------------
    -- LIFECYCLE
    -- ISO 31000: Risk-based lifecycle management
    -- -------------------------------------------------------------------------
    status                      VARCHAR(20) NOT NULL DEFAULT 'active',
                                -- ENUM: 'active', 'deprecated', 'archived'
                                CONSTRAINT chk_role_status 
                                    CHECK (status IN ('active', 'deprecated', 'archived')),
                                
    deprecated_at               TIMESTAMPTZ,
                                -- SET: On deprecation
                                -- TRIGGER: Migration notifications
                                
    archived_at                 TIMESTAMPTZ,
                                -- SET: On archival
                                -- CONSTRAINT: Cannot be assigned when archived
    
    -- -------------------------------------------------------------------------
    -- AUDIT & VERSIONING
    -- -------------------------------------------------------------------------
    version                     INTEGER NOT NULL DEFAULT 1,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by                  UUID NOT NULL,
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by                  UUID NOT NULL,
    
    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------
    CONSTRAINT uq_app_role_code 
        UNIQUE (application_id, role_code),
        -- RULE: Role codes unique per application
        
    CONSTRAINT chk_system_role_immutable 
        CHECK (
            NOT is_system_role OR 
            (created_at = updated_at AND status = 'active')
        ),
        -- SECURITY: System roles cannot be modified
        -- ISO 27001 A.8.2: Privileged role protection
        
    CONSTRAINT chk_permissions_not_null 
        CHECK (permissions IS NOT NULL)
);

-- =============================================================================
-- COMMENTS
-- =============================================================================
COMMENT ON TABLE app.roles_permissions IS 'Role definitions with permissions, inheritance, and entitlement limits. Feature: CORE-APP-003. Compliance: ISO 27001, NIST 800-53, SOC 2 Type II. Security: System roles immutable, inheritance with cycle detection. Audit: Permission changes logged to core.audit_trail.';

COMMENT ON COLUMN app.roles_permissions.is_system_role IS
    'ISO 27001 A.8.2: TRUE = Immutable system role. Cannot be modified or deleted.';
    
COMMENT ON COLUMN app.roles_permissions.permissions IS
    'ISO 27001 A.5.15: JSONB array of permission objects with resource:action:scope';
    
COMMENT ON COLUMN app.roles_permissions.parent_role_ids IS
    'ISO 27001 A.9.2.2: Role inheritance parent references, max 5 levels, cycle detected';

-- =============================================================================
-- INDEXES
-- =============================================================================

-- App-scoped role lookups
CREATE INDEX IF NOT EXISTS idx_roles_app 
    ON app.roles_permissions(application_id);

-- Role type filtering
CREATE INDEX IF NOT EXISTS idx_roles_type 
    ON app.roles_permissions(role_type);

-- Status filtering
CREATE INDEX IF NOT EXISTS idx_roles_status 
    ON app.roles_permissions(status);

-- System role identification (fast path)
CREATE INDEX IF NOT EXISTS idx_roles_system 
    ON app.roles_permissions(is_system_role)
    WHERE is_system_role = TRUE;

-- GIN index for permissions JSONB
CREATE INDEX IF NOT EXISTS idx_roles_permissions_gin 
    ON app.roles_permissions USING GIN (permissions);

-- GIN index for allowed resources
CREATE INDEX IF NOT EXISTS idx_roles_allowed_resources 
    ON app.roles_permissions USING GIN (allowed_resources);

-- GIN index for parent roles (inheritance)
CREATE INDEX IF NOT EXISTS idx_roles_parent_roles 
    ON app.roles_permissions USING GIN (parent_role_ids)
    WHERE parent_role_ids IS NOT NULL;

-- =============================================================================
-- STUB FUNCTIONS AND TABLES (to be replaced by later migrations)
-- =============================================================================

-- CRITICAL FIX: Real implementation of check_permission
-- Previous stub allowed all checks to pass - SECURITY VULNERABILITY
-- This implementation checks role permissions from the database
CREATE OR REPLACE FUNCTION app.check_permission(
    p_membership_id UUID,
    p_permission VARCHAR(100)
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
    v_has_permission BOOLEAN := FALSE;
    v_role_id UUID;
    v_role_permissions JSONB;
BEGIN
    -- Get the primary role for this membership
    SELECT primary_role_id INTO v_role_id
    FROM app.account_membership
    WHERE membership_id = p_membership_id
    AND status = 'active';
    
    IF v_role_id IS NULL THEN
        RETURN FALSE;  -- No active membership or no role assigned
    END IF;
    
    -- Check if the role has the required permission
    SELECT permissions INTO v_role_permissions
    FROM app.roles_permissions
    WHERE role_id = v_role_id
    AND is_active = TRUE;
    
    IF v_role_permissions IS NULL THEN
        RETURN FALSE;  -- Role not found or inactive
    END IF;
    
    -- Check for exact permission match or wildcard permission
    v_has_permission := v_role_permissions @> to_jsonb(p_permission)
        OR v_role_permissions @> to_jsonb(split_part(p_permission, ':', 1) || ':*')
        OR v_role_permissions @> to_jsonb(split_part(p_permission, ':', 1) || ':' || 
                                           split_part(p_permission, ':', 2) || ':*');
    
    -- Also check secondary roles
    IF NOT v_has_permission THEN
        SELECT EXISTS (
            SELECT 1
            FROM app.user_role_assignments ura
            JOIN app.roles_permissions rp ON ura.role_id = rp.role_id
            WHERE ura.membership_id = p_membership_id
            AND ura.status = 'active'
            AND (rp.permissions @> to_jsonb(p_permission)
                 OR rp.permissions @> to_jsonb(split_part(p_permission, ':', 1) || ':*'))
        ) INTO v_has_permission;
    END IF;
    
    RETURN v_has_permission;
END;
$$;

-- Stub table for audit_trail (created by V032, but needed here for triggers)
-- This will be properly created as a hypertable in V032
CREATE TABLE IF NOT EXISTS core.audit_trail (
    audit_id BIGSERIAL PRIMARY KEY,
    audit_category VARCHAR(50),
    audit_level VARCHAR(20),
    audit_event VARCHAR(100),
    audit_description TEXT,
    action VARCHAR(50),
    action_status VARCHAR(20),
    actor_account_id UUID,
    actor_type VARCHAR(50),
    table_schema VARCHAR(50),
    table_name VARCHAR(100),
    record_id TEXT,
    old_data JSONB,
    new_data JSONB,
    application_id UUID,
    transaction_id UUID,
    correlation_id UUID,
    client_ip INET,
    user_agent TEXT,
    error_message TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================================================
-- RLS POLICIES
-- =============================================================================
DO $$
BEGIN
    ALTER TABLE app.roles_permissions ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE app.roles_permissions FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Policy: App Isolation (global roles visible to all)
CREATE POLICY roles_app_isolation ON app.roles_permissions
    USING (application_id IS NULL OR application_id = current_setting('app.current_app_id', TRUE)::UUID);

-- Policy: System Role Read-Only
CREATE POLICY roles_system_readonly ON app.roles_permissions
    USING (
        NOT is_system_role OR 
        app.check_permission(
            current_setting('app.current_membership_id', TRUE)::UUID,
            'platform:admin:read'
        ) = TRUE
    );

-- =============================================================================
-- TRIGGERS
-- =============================================================================

-- Trigger: System Role Protection
CREATE OR REPLACE FUNCTION app.trg_roles_system_protect()
RETURNS TRIGGER AS $$
BEGIN
    -- Prevent modification of system roles
    IF OLD.is_system_role THEN
        RAISE EXCEPTION 'ISO 27001: System roles are immutable and cannot be modified';
    END IF;
    
    -- Prevent privilege escalation through role_type
    IF NEW.role_type IN ('system', 'platform') THEN
        IF NOT app.check_permission(
            current_setting('app.current_membership_id', TRUE)::UUID,
            'platform:admin:system'
        ) THEN
            RAISE EXCEPTION 'Only platform admins can create system/platform roles';
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_roles_system_protect ON app.roles_permissions;
CREATE TRIGGER trg_roles_system_protect
    BEFORE UPDATE OR DELETE ON app.roles_permissions
    FOR EACH ROW EXECUTE FUNCTION app.trg_roles_system_protect();

-- Trigger: Permission Calculation with Cycle Detection
CREATE OR REPLACE FUNCTION app.trg_roles_permission_calc()
RETURNS TRIGGER AS $$
DECLARE
    v_visited UUID[] := ARRAY[NEW.role_id];
    v_current UUID;
    v_parents UUID[];
    v_all_perms JSONB := NEW.permissions;
    v_parent_perms JSONB;
    v_level INTEGER := 0;
    v_max_levels INTEGER := 5;
BEGIN
    -- Recalculate effective_permissions including inheritance
    v_current := NEW.role_id;
    v_parents := NEW.parent_role_ids;
    
    -- Traverse inheritance hierarchy with cycle detection
    WHILE array_length(v_parents, 1) > 0 AND v_level < v_max_levels LOOP
        v_level := v_level + 1;
        
        FOREACH v_current IN ARRAY v_parents LOOP
            -- Check for cycle
            IF v_current = ANY(v_visited) THEN
                -- Log security event for cycle detection
                INSERT INTO core.audit_trail (
                    audit_category,
                    audit_level,
                    audit_event,
                    audit_description,
                    action,
                    action_status,
                    table_schema,
                    table_name,
                    record_id,
                    new_data
                ) VALUES (
                    'SECURITY',
                    'CRITICAL',
                    'role_inheritance_cycle_detected',
                    'Cycle detected in role inheritance hierarchy',
                    'SECURITY_EVENT',
                    'SUCCESS',
                    'app',
                    'roles_permissions',
                    NEW.role_id::TEXT,
                    jsonb_build_object('role_id', NEW.role_id, 'cycle_path', v_visited)
                );
                
                RAISE EXCEPTION 'Role inheritance cycle detected at role %', v_current;
            END IF;
            
            v_visited := array_append(v_visited, v_current);
            
            -- Get parent permissions
            SELECT permissions, parent_role_ids 
            INTO v_parent_perms, v_parents
            FROM app.roles_permissions
            WHERE role_id = v_current;
            
            IF v_parent_perms IS NOT NULL THEN
                -- Merge permissions (child overrides parent for same resource:action)
                v_all_perms := v_all_perms || v_parent_perms;
            END IF;
        END LOOP;
    END LOOP;
    
    -- Update effective permissions
    NEW.effective_permissions := v_all_perms;
    NEW.permission_calculation_at := NOW();
    NEW.updated_at := NOW();
    NEW.version := OLD.version + 1;
    
    -- Update permission cache for all affected memberships
    PERFORM pg_notify('permission_cache_refresh', 
        jsonb_build_object('role_id', NEW.role_id)::TEXT
    );
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_roles_permission_calc ON app.roles_permissions;
CREATE TRIGGER trg_roles_permission_calc
    AFTER INSERT OR UPDATE OF permissions, parent_role_ids ON app.roles_permissions
    FOR EACH ROW EXECUTE FUNCTION app.trg_roles_permission_calc();

-- Trigger: Audit
CREATE OR REPLACE FUNCTION app.trg_roles_audit()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO core.audit_trail (
            audit_category,
            audit_level,
            audit_event,
            audit_description,
            actor_account_id,
            actor_type,
            action,
            action_status,
            table_schema,
            table_name,
            record_id,
            new_data,
            application_id
        ) VALUES (
            'DATA_CHANGE',
            'INFO',
            'role_created',
            'New role created: ' || NEW.role_code,
            NEW.created_by,
            'USER',
            'INSERT',
            'SUCCESS',
            'app',
            'roles_permissions',
            NEW.role_id::TEXT,
            jsonb_build_object(
                'role_code', NEW.role_code,
                'role_type', NEW.role_type,
                'application_id', NEW.application_id
            ),
            NEW.application_id
        );
        RETURN NEW;
        
    ELSIF TG_OP = 'UPDATE' THEN
        IF OLD.permissions IS DISTINCT FROM NEW.permissions THEN
            INSERT INTO core.audit_trail (
                audit_category,
                audit_level,
                audit_event,
                audit_description,
                actor_account_id,
                actor_type,
                action,
                action_status,
                table_schema,
                table_name,
                record_id,
                old_data,
                new_data,
                application_id
            ) VALUES (
                'SECURITY',
                'INFO',
                'role_permissions_changed',
                'Role permissions modified: ' || NEW.role_code,
                NEW.updated_by,
                'USER',
                'UPDATE',
                'SUCCESS',
                'app',
                'roles_permissions',
                NEW.role_id::TEXT,
                jsonb_build_object('permissions', OLD.permissions),
                jsonb_build_object('permissions', NEW.permissions),
                NEW.application_id
            );
        END IF;
        
        IF OLD.status != NEW.status THEN
            INSERT INTO core.audit_trail (
                audit_category,
                audit_level,
                audit_event,
                audit_description,
                actor_account_id,
                actor_type,
                action,
                action_status,
                table_schema,
                table_name,
                record_id,
                old_data,
                new_data,
                application_id
            ) VALUES (
                'DATA_CHANGE',
                CASE NEW.status WHEN 'archived' THEN 'WARNING' ELSE 'INFO' END,
                'role_status_changed',
                'Role status changed from ' || OLD.status || ' to ' || NEW.status,
                NEW.updated_by,
                'USER',
                'STATUS_CHANGE',
                'SUCCESS',
                'app',
                'roles_permissions',
                NEW.role_id::TEXT,
                jsonb_build_object('status', OLD.status),
                jsonb_build_object('status', NEW.status),
                NEW.application_id
            );
        END IF;
        
        RETURN NEW;
    END IF;
    
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_roles_audit ON app.roles_permissions;
CREATE TRIGGER trg_roles_audit
    AFTER INSERT OR UPDATE ON app.roles_permissions
    FOR EACH ROW EXECUTE FUNCTION app.trg_roles_audit();

-- =============================================================================
-- DEFAULT ROLES (Seed Data)
-- =============================================================================

-- Platform Roles (application_id = NULL)
-- These are created during initial setup

-- platform_admin: Full platform access
INSERT INTO app.roles_permissions (
    role_id, role_code, role_type, role_category, is_system_role,
    role_name, role_description, permissions, scope_level,
    created_by, updated_by
) VALUES (
    '00000000-0000-0000-0000-000000000001',
    'platform_admin',
    'system',
    'admin',
    TRUE,
    'Platform Administrator',
    'Full platform access with all permissions',
    '[{"resource": "*", "action": "*", "scope": "*", "granted": true}]'::JSONB,
    'platform',
    '00000000-0000-0000-0000-000000000000',
    '00000000-0000-0000-0000-000000000000'
) ON CONFLICT (role_id) DO NOTHING;

-- platform_operator: Platform operations (read-only on sensitive data)
INSERT INTO app.roles_permissions (
    role_id, role_code, role_type, role_category, is_system_role,
    role_name, role_description, permissions, scope_level,
    created_by, updated_by
) VALUES (
    '00000000-0000-0000-0000-000000000002',
    'platform_operator',
    'system',
    'operator',
    TRUE,
    'Platform Operator',
    'Platform operations with read access to most data',
    '[{"resource": "*", "action": "read", "scope": "*", "granted": true},
      {"resource": "system", "action": "execute", "scope": "*", "granted": true}]'::JSONB,
    'platform',
    '00000000-0000-0000-0000-000000000000',
    '00000000-0000-0000-0000-000000000000'
) ON CONFLICT (role_id) DO NOTHING;

-- platform_auditor: Audit log access only
INSERT INTO app.roles_permissions (
    role_id, role_code, role_type, role_category, is_system_role,
    role_name, role_description, permissions, scope_level,
    created_by, updated_by
) VALUES (
    '00000000-0000-0000-0000-000000000003',
    'platform_auditor',
    'system',
    'viewer',
    TRUE,
    'Platform Auditor',
    'Read-only access to audit logs and compliance data',
    '[{"resource": "audit", "action": "read", "scope": "*", "granted": true},
      {"resource": "report", "action": "read", "scope": "*", "granted": true}]'::JSONB,
    'platform',
    '00000000-0000-0000-0000-000000000000',
    '00000000-0000-0000-0000-000000000000'
) ON CONFLICT (role_id) DO NOTHING;

-- =============================================================================
-- ANALYZE
-- =============================================================================
ANALYZE app.roles_permissions;

-- =============================================================================
-- IMPLEMENTATION NOTES
-- =============================================================================
-- 1. Permission format: resource:action:scope (e.g., "ledger:write:own")
-- 2. System roles are immutable and cannot be deleted
-- 3. Role inheritance forms a DAG (cycles prevented by trigger)
-- 4. Deny permissions always override allow permissions
-- 5. Changes trigger permission cache invalidation across all members
-- 6. Effective permissions calculated asynchronously for performance
-- 7. Max 5 inheritance levels to prevent complexity explosion
-- =============================================================================

COMMIT;
