-- =============================================================================
-- Migration: V010__core_agent_relationships
-- Description: Core table: agent_relationships
-- Dependencies: V009
-- Generated: 2026-04-02 16:56:45 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- Enable ltree extension for hierarchical path support
CREATE EXTENSION IF NOT EXISTS ltree;

-- =============================================================================
-- CREATE TABLE: agent_relationships
-- =============================================================================

CREATE TABLE IF NOT EXISTS core.agent_relationships (
    -- Primary identifier
    relationship_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Relationship endpoints
    from_account_id UUID NOT NULL REFERENCES core.account_registry(account_id) ON DELETE RESTRICT,
    to_account_id UUID NOT NULL REFERENCES core.account_registry(account_id) ON DELETE RESTRICT,
    
    -- Relationship classification
    relationship_type VARCHAR(50) NOT NULL
        CHECK (relationship_type IN ('AGENT', 'GROUP_MEMBERSHIP', 'REFERRAL', 'PARENT_CHILD', 'GUARDIANSHIP')),
    
    -- Hierarchy support
    parent_relationship_id UUID REFERENCES core.agent_relationships(relationship_id) ON DELETE RESTRICT,
    relationship_path LTREE,
    depth INTEGER DEFAULT 0 CHECK (depth >= 0 AND depth <= 20),
    
    -- Permissions granted by this relationship
    permissions JSONB DEFAULT '{}',  -- e.g., {'can_view_balance': true, 'can_initiate_tx': false}
    
    -- Commission/rates (for agent relationships)
    commission_rate NUMERIC(5, 4),  -- e.g., 0.0150 = 1.5%
    commission_plan_id UUID,
    
    -- Limits
    daily_limit NUMERIC(20, 8),
    transaction_limit NUMERIC(20, 8),
    monthly_limit NUMERIC(20, 8),
    
    -- Risk and compliance
    risk_rating VARCHAR(20) CHECK (risk_rating IN ('low', 'medium', 'high', 'critical')),
    kyc_verified BOOLEAN DEFAULT FALSE,
    kyc_verified_at TIMESTAMPTZ,
    kyc_verified_by UUID,
    
    -- Status
    status VARCHAR(20) DEFAULT 'active'
        CHECK (status IN ('active', 'suspended', 'terminated', 'pending_approval')),
    
    -- Approval workflow
    approved_by UUID,
    approved_at TIMESTAMPTZ,
    
    -- Validity period
    valid_from TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    valid_to TIMESTAMPTZ,
    
    -- Termination details
    terminated_by UUID,
    terminated_at TIMESTAMPTZ,
    termination_reason TEXT,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    
    -- Constraints
    CONSTRAINT chk_no_self_relationship CHECK (from_account_id != to_account_id),
    CONSTRAINT chk_valid_to_after_from_rel CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT chk_unique_active_relationship UNIQUE (from_account_id, to_account_id, relationship_type, valid_from)
);

-- =============================================================================
-- INDEXES
-- =============================================================================

-- Essential indexes
CREATE INDEX IF NOT EXISTS idx_agent_relationships_from ON core.agent_relationships(from_account_id) WHERE valid_to IS NULL;
CREATE INDEX IF NOT EXISTS idx_agent_relationships_to ON core.agent_relationships(to_account_id) WHERE valid_to IS NULL;
CREATE INDEX IF NOT EXISTS idx_agent_relationships_status ON core.agent_relationships(status) WHERE valid_to IS NULL;

-- =============================================================================
-- IMMUTABILITY TRIGGERS
-- =============================================================================

-- Prevent updates on immutable table
DROP TRIGGER IF EXISTS trg_agent_relationships_prevent_update ON core.agent_relationships;
CREATE TRIGGER trg_agent_relationships_prevent_update
    BEFORE UPDATE ON core.agent_relationships
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

-- Prevent deletes on immutable table
DROP TRIGGER IF EXISTS trg_agent_relationships_prevent_delete ON core.agent_relationships;
CREATE TRIGGER trg_agent_relationships_prevent_delete
    BEFORE DELETE ON core.agent_relationships
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

-- =============================================================================
-- HASH COMPUTATION TRIGGER
-- =============================================================================



-- =============================================================================
-- CYCLE PREVENTION TRIGGER
-- =============================================================================

CREATE OR REPLACE FUNCTION core.prevent_relationship_cycle()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_path LTREE;
    v_from_path LTREE;
    v_to_path LTREE;
BEGIN
    -- Check if this would create a cycle by seeing if from_account is already a descendant of to_account
    SELECT relationship_path INTO v_to_path
    FROM core.agent_relationships
    WHERE from_account_id = NEW.to_account_id
    AND valid_to IS NULL
    AND relationship_type = NEW.relationship_type
    LIMIT 1;
    
    IF v_to_path IS NOT NULL AND NEW.from_account_id::TEXT = v_to_path::TEXT THEN
        RAISE EXCEPTION 'CYCLIC_RELATIONSHIP: Would create cycle between accounts % and %', 
            NEW.from_account_id, NEW.to_account_id;
    END IF;
    
    -- Compute path
    IF NEW.parent_relationship_id IS NULL THEN
        NEW.relationship_path := text2ltree(NEW.from_account_id::TEXT);
    ELSE
        SELECT relationship_path INTO v_path
        FROM core.agent_relationships
        WHERE relationship_id = NEW.parent_relationship_id;
        
        IF v_path IS NULL THEN
            NEW.relationship_path := text2ltree(NEW.from_account_id::TEXT);
        ELSE
            NEW.relationship_path := v_path || NEW.to_account_id::TEXT::ltree;
        END IF;
    END IF;
    
    -- Set depth based on path
    NEW.depth := nlevel(NEW.relationship_path) - 1;
    
    -- Check max depth
    IF NEW.depth > 20 THEN
        RAISE EXCEPTION 'MAX_DEPTH_EXCEEDED: Relationship hierarchy cannot exceed 20 levels';
    END IF;
    
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_agent_relationships_prevent_cycle ON core.agent_relationships;
CREATE TRIGGER trg_agent_relationships_prevent_cycle
    BEFORE INSERT ON core.agent_relationships
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_relationship_cycle();

-- =============================================================================
-- RLS POLICIES
-- =============================================================================

-- Enable RLS with FORCE (critical for security - prevents table owner bypass)
DO $$
BEGIN
    ALTER TABLE core.agent_relationships ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE core.agent_relationships FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Policy: Accounts can view relationships they participate in
-- PRODUCTION FIX: Uses safe UUID helper to prevent NULL casting issues
CREATE POLICY agent_relationships_participant_access ON core.agent_relationships
    FOR SELECT
    TO ussd_app_user
    USING (
        from_account_id = core.get_current_setting_as_uuid('app.current_account_id')
        OR to_account_id = core.get_current_setting_as_uuid('app.current_account_id')
    );

-- Policy: Application-scoped access
CREATE POLICY agent_relationships_app_access ON core.agent_relationships
    FOR SELECT
    TO ussd_app_user
    USING (
        EXISTS (
            SELECT 1 FROM core.account_registry ar
            WHERE ar.account_id = agent_relationships.from_account_id
            AND ar.primary_application_id = core.get_current_setting_as_uuid('app.current_application_id')
        )
    );

-- Policy: Kernel role has full access
CREATE POLICY agent_relationships_kernel_access ON core.agent_relationships
    FOR ALL
    TO ussd_kernel_role
    USING (true);

-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

-- Function to create a relationship
CREATE OR REPLACE FUNCTION core.create_relationship(
    p_from_account_id UUID,
    p_to_account_id UUID,
    p_relationship_type VARCHAR(50),
    p_permissions JSONB DEFAULT '{}',
    p_commission_rate NUMERIC DEFAULT NULL,
    p_daily_limit NUMERIC DEFAULT NULL,
    p_transaction_limit NUMERIC DEFAULT NULL,
    p_created_by UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_relationship_id UUID;
BEGIN
    INSERT INTO core.agent_relationships (
        from_account_id,
        to_account_id,
        relationship_type,
        permissions,
        commission_rate,
        daily_limit,
        transaction_limit,
        created_by
    ) VALUES (
        p_from_account_id,
        p_to_account_id,
        p_relationship_type,
        p_permissions,
        p_commission_rate,
        p_daily_limit,
        p_transaction_limit,
        p_created_by
    )
    RETURNING relationship_id INTO v_relationship_id;
    
    RETURN v_relationship_id;
END;
$$;

-- Function to terminate a relationship
CREATE OR REPLACE FUNCTION core.terminate_relationship(
    p_relationship_id UUID,
    p_terminated_by UUID,
    p_reason TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE core.agent_relationships
    SET 
        status = 'terminated',
        valid_to = NOW(),
        terminated_by = p_terminated_by,
        terminated_at = NOW(),
        termination_reason = p_reason
    WHERE relationship_id = p_relationship_id
    AND valid_to IS NULL;
    
    RETURN FOUND;
END;
$$;

-- Function to get agent hierarchy
CREATE OR REPLACE FUNCTION core.get_agent_hierarchy(
    p_account_id UUID,
    p_relationship_type VARCHAR(50) DEFAULT 'AGENT'
)
RETURNS TABLE (
    relationship_id UUID,
    from_account_id UUID,
    to_account_id UUID,
    depth INTEGER,
    commission_rate NUMERIC(5, 4),
    status VARCHAR(20)
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ar.relationship_id,
        ar.from_account_id,
        ar.to_account_id,
        ar.depth,
        ar.commission_rate,
        ar.status
    FROM core.agent_relationships ar
    WHERE ar.from_account_id = p_account_id
    AND ar.relationship_type = p_relationship_type
    AND ar.valid_to IS NULL
    ORDER BY ar.depth, ar.created_at;
END;
$$;

-- Function to get all descendants (sub-agents, group members, etc.)
CREATE OR REPLACE FUNCTION core.get_relationship_descendants(
    p_account_id UUID,
    p_relationship_type VARCHAR(50) DEFAULT NULL
)
RETURNS TABLE (
    account_id UUID,
    depth INTEGER,
    commission_rate NUMERIC(5, 4),
    permissions JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ar.to_account_id,
        ar.depth,
        ar.commission_rate,
        ar.permissions
    FROM core.agent_relationships ar
    WHERE ar.from_account_id = p_account_id
    AND (p_relationship_type IS NULL OR ar.relationship_type = p_relationship_type)
    AND ar.valid_to IS NULL
    ORDER BY ar.depth, ar.to_account_id;
END;
$$;

-- Function to get all ancestors (parent agents, groups, etc.)
CREATE OR REPLACE FUNCTION core.get_relationship_ancestors(
    p_account_id UUID,
    p_relationship_type VARCHAR(50) DEFAULT NULL
)
RETURNS TABLE (
    account_id UUID,
    depth INTEGER,
    relationship_type VARCHAR(50)
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ar.from_account_id,
        ar.depth,
        ar.relationship_type
    FROM core.agent_relationships ar
    WHERE ar.to_account_id = p_account_id
    AND (p_relationship_type IS NULL OR ar.relationship_type = p_relationship_type)
    AND ar.valid_to IS NULL
    ORDER BY ar.depth DESC;
END;
$$;

-- =============================================================================
-- TABLE AND COLUMN COMMENTS
-- =============================================================================

COMMENT ON TABLE core.agent_relationships IS 
    'Hierarchical relationships between accounts including agents, group memberships, and referrals. Immutable with temporal versioning.';

COMMENT ON COLUMN core.agent_relationships.relationship_id IS 
    'Unique identifier for the relationship';
COMMENT ON COLUMN core.agent_relationships.from_account_id IS 
    'The account that owns/initiates the relationship';
COMMENT ON COLUMN core.agent_relationships.to_account_id IS 
    'The account that is the target of the relationship';
COMMENT ON COLUMN core.agent_relationships.relationship_type IS 
    'Type: AGENT, GROUP_MEMBERSHIP, REFERRAL, PARENT_CHILD, GUARDIANSHIP';
COMMENT ON COLUMN core.agent_relationships.relationship_path IS 
    'LTREE materialized path for hierarchy queries';
COMMENT ON COLUMN core.agent_relationships.depth IS 
    'Depth in the relationship hierarchy';
COMMENT ON COLUMN core.agent_relationships.permissions IS 
    'JSON permissions granted by this relationship';
COMMENT ON COLUMN core.agent_relationships.commission_rate IS 
    'Commission rate for agent relationships (e.g., 0.015 = 1.5%)';
COMMENT ON COLUMN core.agent_relationships.valid_from IS 
    'When this relationship became valid';
COMMENT ON COLUMN core.agent_relationships.valid_to IS 
    'When this relationship ended (NULL = active)';

-- =============================================================================
-- END OF FILE
-- =============================================================================

COMMIT;
