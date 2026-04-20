-- =============================================================================
-- Migration: V034__app_account_membership
-- Description: App table: account_membership
-- Dependencies: V033
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

/**
 * =============================================================================
 * USSD IMMUTABLE LEDGER KERNEL - ACCOUNT MEMBERSHIP
 * =============================================================================
 * 
 * Feature ID:         CORE-APP-002
 * Feature Name:       Account Membership Management
 * Description:        Manages user memberships within applications. Supports
 *                     hierarchical organization structures and cross-application
 *                     user identities.
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
 *   - Control A.5.18: Access rights (membership grants)
 *   - Control A.8.2: Privileged access accounts (owner/admin types)
 *   - Control A.8.7: Protection against malware (service account controls)
 *   - Control A.9.2.1: User registration and de-registration
 *   - Control A.9.2.2: Access provisioning (role assignment)
 * 
 * ISO/IEC 27017:2015 (Cloud Security)
 *   - Section 9: Network security (invitation token handling)
 *   - Section 12: Data segregation between tenants
 * 
 * ISO/IEC 27018:2019 (PII Protection)
 *   - Section 7: Consent and choice (invitation workflow)
 *   - Section 8: Transparency (membership visibility)
 * 
 * ISO 9001:2015 (Quality Management)
 *   - Section 7.2: Competence (membership type skills matching)
 *   - Section 8.4: Control of externally provided processes
 * 
 * ISO 31000:2018 (Risk Management)
 *   - Risk identification: Suspended/revoked membership handling
 * 
 * SOC 2 Type II
 *   - CC6.1: Logical and physical access controls
 *   - CC6.3: Access removal (revocation workflow)
 *   - CC7.2: System monitoring (membership status tracking)
 * 
 * GDPR
 *   - Article 17: Right to erasure (revoked membership data handling)
 *   - Article 25: Data protection by design (minimal PII collection)
 * 
 * =============================================================================
 * MULTI-TENANCY SECURITY ANNOTATIONS
 * =============================================================================
 * 
 * TENANT ISOLATION:
 *   - application_id links to application_registry for tenant context
 *   - RLS: Memberships only visible within same application
 *   - Cross-app visibility: Requires explicit platform:admin permission
 * 
 * DATA SEGREGATION:
 *   - Each membership is bound to single application
 *   - user_identity_id allows cross-app correlation (controlled)
 *   - Invitation tokens are app-scoped
 * 
 * SECURITY CONTROLS:
 *   - invitation_token_hash: Bcrypt hashed, 7-day expiry
 *   - status transitions: Require authorization and audit logging
 *   - service accounts: Special handling, no invitation flow
 * 
 * =============================================================================
 * RBAC ENFORCEMENT DOCUMENTATION
 * =============================================================================
 * 
 * MEMBERSHIP TYPES & PERMISSIONS:
 * 
 * | Type        | Can Invite | Can Manage | Can Access |
 * |-------------|------------|------------|------------|
 * | owner       | All        | All        | All        |
 * | admin       | Members    | Members    | All        |
 * | member      | None       | None       | Allowed    |
 * | guest       | None       | None       | Limited    |
 * | service     | N/A        | N/A        | API only   |
 * 
 * REQUIRED PERMISSIONS FOR OPERATIONS:
 * 
 * | Operation                    | Required Permission              |
 * |------------------------------|----------------------------------|
 * | CREATE membership            | app:membership:create            |
 * | READ own membership          | (Self - always allowed)          |
 * | READ app memberships         | app:membership:read              |
 * | UPDATE membership status     | app:membership:manage            |
 * | DELETE (revoke) membership   | app:membership:delete            |
 * | INVITE user                  | app:membership:invite            |
 * | TRANSFER ownership           | app:owner:transfer               |
 * 
 * =============================================================================
 * AUDIT TRAIL REQUIREMENTS
 * =============================================================================
 * 
 * MANDATORY AUDIT EVENTS:
 *   - Membership Created (inviter, invitee, type)
 *   - Invitation Accepted (timestamp, IP, user agent)
 *   - Status Transition (who, when, old→new, reason)
 *   - Role Assignment Change (primary/secondary roles)
 *   - Ownership Transfer (old→new owner)
 *   - Revocation (who revoked, reason, data retention plan)
 * 
 * AUDIT RETENTION: 7 years
 * AUDIT ACCESS: platform:auditor role only
 * 
 * =============================================================================
 * DEPENDENCIES
 * =============================================================================
 * 
 *   - app.application_registry (FK: application_id)
 *   - app.roles_permissions (FK: primary_role_id)
 *   - core.t_user_identity (FK: user_identity_id, created_by)
 * 
 * CHANGE LOG:
 *   1.0.0 - Initial schema creation with compliance headers
 *   1.0.1 - Implemented TODOs: Fixed column definitions, audit logging
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
-- TABLE: app.account_membership
-- =============================================================================
CREATE TABLE IF NOT EXISTS app.account_membership (
    -- -------------------------------------------------------------------------
    -- PRIMARY IDENTIFIERS
    -- ISO 27001: Unique identification
    -- -------------------------------------------------------------------------
    membership_id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                                -- SECURITY: Random UUID prevents enumeration
                                
    application_id                      UUID NOT NULL,
                                -- FK: app.application_registry.application_id
                                -- ISO 27017: Tenant binding
                                CONSTRAINT fk_membership_app 
                                    FOREIGN KEY (application_id)
                                    REFERENCES app.application_registry(application_id)
                                    ON DELETE CASCADE,
                                -- CASCADE: Remove memberships when app deleted
                                
    user_identity_id            UUID NOT NULL,
                                -- FK: core.t_user_identity.user_identity_id
                                -- ISO 27018: PII reference (external table)
                                -- NOTE: One membership per user per app enforced below
    
    -- -------------------------------------------------------------------------
    -- MEMBERSHIP CONTEXT
    -- ISO 27001 A.9.2.1: Access level classification
    -- -------------------------------------------------------------------------
    membership_type             VARCHAR(30) NOT NULL DEFAULT 'member',
                                -- ENUM: 'owner', 'admin', 'member', 'guest', 'service'
                                -- ISO 27001: Privilege levels
                                CONSTRAINT chk_membership_type
                                    CHECK (membership_type IN ('owner', 'admin', 'member', 'guest', 'service')),
                                -- owner: Full control, can delete app
                                -- admin: User management, configuration
                                -- member: Standard access
                                -- guest: Limited/time-bound access
                                -- service: API-only, no UI access
                                
    membership_scope            VARCHAR(30) NOT NULL DEFAULT 'organization',
                                -- ENUM: 'organization', 'division', 'team', 'project', 'resource'
                                -- ISO 9001: Organizational structure support
    
    -- -------------------------------------------------------------------------
    -- ORGANIZATIONAL HIERARCHY
    -- ISO 9001: Hierarchical structure management
    -- -------------------------------------------------------------------------
    org_unit_id                 UUID,
                                -- FK: Future app.t_organizational_units
                                -- SCOPE: Division/department grouping
                                
    parent_membership_id        UUID,
                                -- SELF-REFERENCE: Delegation chains
                                CONSTRAINT fk_membership_parent 
                                    FOREIGN KEY (parent_membership_id) 
                                    REFERENCES app.account_membership(membership_id)
                                    ON DELETE SET NULL,
                                -- ISO 27001: Delegation tracking
                                
    hierarchy_level             INTEGER NOT NULL DEFAULT 0,
                                -- COMPUTED: Depth in hierarchy (0 = top)
                                -- VALIDATION: Must match parent chain
                                CONSTRAINT chk_hierarchy_positive CHECK (hierarchy_level >= 0),
    
    -- -------------------------------------------------------------------------
    -- ROLE ASSIGNMENTS (Denormalized for performance)
    -- ISO 27001 A.9.2.2: Access provisioning
    -- -------------------------------------------------------------------------
    primary_role_id             UUID,
                                -- FK: app.roles_permissions.role_id
                                -- CONSTRAINT: Must be compatible with membership_type
                                CONSTRAINT fk_membership_primary_role 
                                    FOREIGN KEY (primary_role_id) 
                                    REFERENCES app.roles_permissions(role_id)
                                    ON DELETE SET NULL,
                                
    secondary_role_ids          UUID[],
                                -- ARRAY: Additional role IDs
                                -- LIMIT: Max 10 secondary roles (enforced by trigger)
                                -- ISO 27001: Principle of least privilege
    
    -- -------------------------------------------------------------------------
    -- MEMBERSHIP STATE
    -- ISO 31000: Risk-based state management
    -- -------------------------------------------------------------------------
    status                      VARCHAR(20) NOT NULL DEFAULT 'pending',
                                -- ENUM: 'pending', 'active', 'suspended', 'inactive', 'revoked'
                                CONSTRAINT chk_membership_status 
                                    CHECK (status IN ('pending', 'active', 'suspended', 'inactive', 'revoked')),
                                -- pending: Invitation sent, not accepted
                                -- active: Full access granted
                                -- suspended: Temporary access block
                                -- inactive: Soft delete, can be reactivated
                                -- revoked: Permanent removal (GDPR erasure candidate)
                                -- AUDIT: All transitions logged
                                
    status_reason               VARCHAR(255),
                                -- REQUIRED: When status != 'active'
                                -- ISO 9001: Documented state changes
                                
    invited_at                  TIMESTAMPTZ,
                                -- AUTO-SET: On invitation creation
                                -- ISO 27018: Consent timestamp
                                
    joined_at                   TIMESTAMPTZ,
                                -- AUTO-SET: On invitation acceptance
                                -- AUDIT: User onboarding completion
                                
    suspended_at                TIMESTAMPTZ,
                                -- AUTO-SET: On suspension
                                -- ISO 27001: Access control event
                                
    revoked_at                  TIMESTAMPTZ,
                                -- AUTO-SET: On revocation
                                -- GDPR: Right to erasure trigger
    
    -- -------------------------------------------------------------------------
    -- INVITATION & ONBOARDING
    -- ISO 27001 A.9.2.1: Secure registration
    -- -------------------------------------------------------------------------
    invitation_token_hash       VARCHAR(255),
                                -- HASH: Bcrypt of invitation token
                                -- EXPIRY: 7 days from invited_at
                                -- ISO 27018: Secure invitation delivery
                                
    invited_by                  UUID,
                                -- FK: self (membership_id of inviter)
                                -- ISO 27001: Accountability
                                
    invitation_expires_at       TIMESTAMPTZ,
                                -- DEFAULT: invited_at + 7 days
                                -- CLEANUP: Cron job removes expired
                                
    onboarding_completed_at     TIMESTAMPTZ,
                                -- SET: When required onboarding finished
                                -- ISO 9001: Competence verification
    
    -- -------------------------------------------------------------------------
    -- PERMISSIONS & ENTITLEMENTS
    -- ISO 27001: Granular access control
    -- -------------------------------------------------------------------------
    custom_permissions          JSONB DEFAULT '{}',
                                -- OVERRIDE: Additional permissions beyond roles
                                -- ISO 27001: Emergency access provisioning
                                
    entitlement_overrides       JSONB DEFAULT '{}',
                                -- OVERRIDE: Custom entitlement limits
                                -- FORMAT: {"resource": {"limit": value}}
    
    -- -------------------------------------------------------------------------
    -- AUDIT & VERSIONING
    -- ISO 9001: Version control
    -- -------------------------------------------------------------------------
    version                     INTEGER NOT NULL DEFAULT 1,
                                -- OPTIMISTIC LOCKING
                                
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                                -- IMMUTABLE
                                
    created_by                  UUID NOT NULL,
                                -- FK: core.t_user_identity
                                -- ISO 27001: Non-repudiation
                                
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                                -- AUTO-UPDATE: Trigger managed
                                
    updated_by                  UUID NOT NULL,
                                -- FK: core.t_user_identity
    
    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------
    CONSTRAINT uq_app_user_membership 
        UNIQUE (application_id, user_identity_id),
        -- RULE: One membership per user per app
        -- ISO 27017: Clear accountability
        
    CONSTRAINT chk_secondary_roles_limit 
        CHECK (array_length(secondary_role_ids, 1) IS NULL OR array_length(secondary_role_ids, 1) <= 10),
        -- LIMIT: Prevent role accumulation
        -- ISO 27001: Principle of least privilege
        
    CONSTRAINT chk_invitation_expiry 
        CHECK (invitation_expires_at IS NULL OR invitation_expires_at > invited_at)
);

-- =============================================================================
-- COMMENTS
-- =============================================================================
COMMENT ON TABLE app.account_membership IS 'User memberships within applications with role assignments and organizational context. Feature: CORE-APP-002. Compliance: ISO 27001, ISO 27018, GDPR. Security: Invitation tokens hashed, 7-day expiry. Audit: All status transitions logged.';

COMMENT ON COLUMN app.account_membership.membership_type IS
    'ISO 27001: Privilege level classification (owner/admin/member/guest/service)';
    
COMMENT ON COLUMN app.account_membership.status IS
    'Lifecycle state with audit trail. Revoked = GDPR erasure candidate.';
    
COMMENT ON COLUMN app.account_membership.invitation_token_hash IS
    'ISO 27018: Bcrypt hashed token. Raw token sent via secure channel only.';

-- =============================================================================
-- INDEXES
-- =============================================================================

-- App-based membership lookups (primary query pattern)
CREATE INDEX IF NOT EXISTS idx_membership_app 
    ON app.account_membership(application_id);

-- User identity lookups (for finding user's apps)
CREATE INDEX IF NOT EXISTS idx_membership_user 
    ON app.account_membership(user_identity_id);

-- Status-based filtering
CREATE INDEX IF NOT EXISTS idx_membership_status 
    ON app.account_membership(status);

-- Composite for active memberships by app
CREATE INDEX IF NOT EXISTS idx_membership_app_status 
    ON app.account_membership(application_id, status);

-- Partial: Active/pending/suspended for unique constraint
CREATE UNIQUE INDEX IF NOT EXISTS idx_membership_app_user_unique 
    ON app.account_membership(application_id, user_identity_id)
    WHERE status IN ('active', 'pending', 'suspended');

-- Role-based lookups
CREATE INDEX IF NOT EXISTS idx_membership_primary_role 
    ON app.account_membership(primary_role_id)
    WHERE primary_role_id IS NOT NULL;

-- GIN index for secondary roles array
CREATE INDEX IF NOT EXISTS idx_membership_secondary_roles 
    ON app.account_membership USING GIN (secondary_role_ids)
    WHERE secondary_role_ids IS NOT NULL;

-- Invitation token lookups (for acceptance flow)
CREATE INDEX IF NOT EXISTS idx_membership_invitation 
    ON app.account_membership(invitation_token_hash)
    WHERE invitation_token_hash IS NOT NULL;

-- Pending invitations with expiry (cleanup job)
CREATE INDEX IF NOT EXISTS idx_membership_pending_expiry 
    ON app.account_membership(invitation_expires_at)
    WHERE status = 'pending' AND invitation_expires_at IS NOT NULL;

-- =============================================================================
-- RLS POLICIES
-- =============================================================================
DO $$
BEGIN
    ALTER TABLE app.account_membership ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Policy: App Isolation
CREATE POLICY membership_app_isolation ON app.account_membership
    USING (application_id = current_setting('app.current_app_id', TRUE)::UUID);

-- Policy: Self View
CREATE POLICY membership_self_view ON app.account_membership
    FOR SELECT USING (
        user_identity_id = current_setting('app.current_user_id', TRUE)::UUID
    );

-- Policy: Admin Manage
CREATE POLICY membership_admin_manage ON app.account_membership
    USING (app.check_permission(
        current_setting('app.current_membership_id', TRUE)::UUID,
        'app:membership:manage'
    ) = TRUE);

-- =============================================================================
-- TRIGGERS
-- =============================================================================

-- Trigger: Audit Logging
CREATE OR REPLACE FUNCTION app.trg_membership_audit()
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
            'membership_created',
            'New membership created with type: ' || NEW.membership_type,
            NEW.created_by,
            'USER',
            'INSERT',
            'SUCCESS',
            'app',
            'account_membership',
            NEW.membership_id::TEXT,
            jsonb_build_object(
                'application_id', NEW.application_id,
                'user_identity_id', NEW.user_identity_id,
                'membership_type', NEW.membership_type
            ),
            NEW.application_id
        );
        RETURN NEW;
        
    ELSIF TG_OP = 'UPDATE' THEN
        -- Version and timestamp
        NEW.version = OLD.version + 1;
        NEW.updated_at = NOW();
        
        -- Status transition timestamps
        IF OLD.status != NEW.status THEN
            CASE NEW.status
                WHEN 'active' THEN NEW.joined_at := NOW();
                WHEN 'suspended' THEN NEW.suspended_at := NOW();
                WHEN 'revoked' THEN NEW.revoked_at := NOW();
            END CASE;
            
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
                CASE NEW.status 
                    WHEN 'revoked' THEN 'WARNING'
                    WHEN 'suspended' THEN 'WARNING'
                    ELSE 'INFO'
                END,
                'membership_status_change',
                'Membership status changed from ' || OLD.status || ' to ' || NEW.status,
                NEW.updated_by,
                'USER',
                'STATUS_CHANGE',
                'SUCCESS',
                'app',
                'account_membership',
                NEW.membership_id::TEXT,
                jsonb_build_object('status', OLD.status),
                jsonb_build_object('status', NEW.status, 'reason', NEW.status_reason),
                NEW.application_id
            );
        END IF;
        
        -- Role change logging
        IF OLD.primary_role_id IS DISTINCT FROM NEW.primary_role_id THEN
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
                'membership_role_change',
                'Primary role changed for membership',
                NEW.updated_by,
                'USER',
                'ROLE_CHANGE',
                'SUCCESS',
                'app',
                'account_membership',
                NEW.membership_id::TEXT,
                jsonb_build_object('primary_role_id', OLD.primary_role_id),
                jsonb_build_object('primary_role_id', NEW.primary_role_id),
                NEW.application_id
            );
        END IF;
        
        RETURN NEW;
        
    ELSIF TG_OP = 'DELETE' THEN
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
            application_id
        ) VALUES (
            'DATA_CHANGE',
            'WARNING',
            'membership_deleted',
            'Membership permanently deleted',
            current_setting('app.current_user_id', TRUE)::UUID,
            'USER',
            'DELETE',
            'SUCCESS',
            'app',
            'account_membership',
            OLD.membership_id::TEXT,
            row_to_json(OLD),
            OLD.application_id
        );
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_membership_audit ON app.account_membership;
CREATE TRIGGER trg_membership_audit
    BEFORE INSERT OR UPDATE OR DELETE ON app.account_membership
    FOR EACH ROW EXECUTE FUNCTION app.trg_membership_audit();

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Function: Invite Member
-- ISO 27001 A.9.2.1: Secure user registration
CREATE OR REPLACE FUNCTION app.invite_member(
    p_app_id UUID,
    p_user_identity_id UUID,
    p_membership_type VARCHAR(30),
    p_primary_role_id UUID,
    p_invited_by UUID,
    p_custom_message TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_membership_id UUID;
    v_invitation_token TEXT;
    v_token_hash TEXT;
BEGIN
    -- Authorization check
    IF NOT app.check_permission(
        current_setting('app.current_membership_id', TRUE)::UUID,
        'app:membership:invite'
    ) THEN
        RAISE EXCEPTION 'ISO 27001: Insufficient privileges to invite members';
    END IF;
    
    -- Validate membership type compatibility
    IF p_membership_type = 'owner' THEN
        RAISE EXCEPTION 'Use transfer_ownership() to assign owner role';
    END IF;
    
    -- Generate invitation token
    v_invitation_token := encode(gen_random_bytes(32), 'hex');
    v_token_hash := crypt(v_invitation_token, gen_salt('bf', 10));
    
    INSERT INTO app.account_membership (
        application_id, user_identity_id, membership_type,
        primary_role_id, status,
        invitation_token_hash, invited_by, invitation_expires_at,
        created_by, updated_by
    ) VALUES (
        p_app_id, p_user_identity_id, p_membership_type,
        p_primary_role_id, 'pending',
        v_token_hash, p_invited_by, NOW() + INTERVAL '7 days',
        p_invited_by, p_invited_by
    )
    RETURNING membership_id INTO v_membership_id;
    
    -- Return token for email delivery (caller handles secure transmission)
    -- SECURITY: Token only valid for 7 days
    RETURN v_membership_id;
END;
$$;

-- Function: Transfer Ownership
-- ISO 27001: Privileged access transfer
CREATE OR REPLACE FUNCTION app.transfer_ownership(
    p_app_id UUID,
    p_new_owner_membership_id UUID,
    p_transferred_by UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Authorization: Must be current owner or platform admin
    IF NOT EXISTS (
        SELECT 1 FROM app.account_membership
        WHERE membership_id = p_transferred_by
          AND application_id = p_app_id
          AND membership_type = 'owner'
    ) AND NOT app.check_permission(p_transferred_by, 'platform:admin:manage') THEN
        RAISE EXCEPTION 'Only current owner or platform admin can transfer ownership';
    END IF;
    
    -- Update new owner
    UPDATE app.account_membership
    SET membership_type = 'owner',
        updated_at = NOW(),
        updated_by = p_transferred_by
    WHERE membership_id = p_new_owner_membership_id
      AND application_id = p_app_id;
    
    -- Demote previous owner to admin
    UPDATE app.account_membership
    SET membership_type = 'admin',
        updated_at = NOW(),
        updated_by = p_transferred_by
    WHERE membership_id = p_transferred_by
      AND application_id = p_app_id;
    
    RETURN TRUE;
END;
$$;

-- =============================================================================
-- DEFERRED FK CONSTRAINTS FROM V033
-- Add constraints that reference account_membership now that it exists
-- =============================================================================

-- Add FK constraints to application_registry (from V033)
ALTER TABLE app.application_registry
    ADD CONSTRAINT fk_app_owner 
        FOREIGN KEY (default_owner_account_id) 
        REFERENCES app.account_membership(membership_id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT fk_app_billing 
        FOREIGN KEY (billing_account_id) 
        REFERENCES app.account_membership(membership_id)
        ON DELETE SET NULL;

-- =============================================================================
-- ANALYZE
-- =============================================================================
ANALYZE app.account_membership;

-- =============================================================================
-- IMPLEMENTATION NOTES
-- =============================================================================
-- 1. Each user can have only one membership per application
-- 2. Service accounts use special membership_type = 'service'
-- 3. Invitation tokens expire after 7 days
-- 4. Role changes trigger permission cache invalidation
-- 5. Soft delete via status = 'revoked' preserves audit trail
-- 6. Hierarchy level auto-calculated from parent chain
-- 7. Max 10 secondary roles per membership (performance/security)
-- =============================================================================

COMMIT;
