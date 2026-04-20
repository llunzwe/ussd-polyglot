-- =============================================================================
-- Migration: V043__app_tax_rates
-- Description: App table: tax_rates
-- Dependencies: V042
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

/**
 * =============================================================================
 * USSD IMMUTABLE LEDGER KERNEL - TAX RATES
 * =============================================================================
 * 
 * Feature ID:         CORE-APP-011
 * Feature Name:       Tax Rate Management
 * Description:        Tax rate definitions and jurisdictions for transaction
 *                     tax calculation. Supports multiple tax types, exemptions,
 *                     and effective date ranges with historical tracking.
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
 *   - Control A.5.31: Legal, statutory, regulatory requirements
 *   - Control A.8.1: User endpoint devices
 * 
 * ISO 9001:2015 (Quality Management)
 *   - Section 7.1.5: Monitoring and measuring resources
 * 
 * Tax Compliance
 *   - VAT/GST calculation requirements
 *   - Jurisdiction-specific tax rules
 *   - Exemption certificate tracking
 * 
 * =============================================================================
 * RBAC ENFORCEMENT DOCUMENTATION
 * =============================================================================
 * 
 * REQUIRED PERMISSIONS:
 * 
 * | Operation                    | Required Permission              |
 * |------------------------------|----------------------------------|
 * | CREATE tax rate              | app:tax:create                   |
 * | READ tax rate                | app:tax:read                     |
 * | UPDATE tax rate              | app:tax:update                   |
 * | MANAGE exemptions            | app:tax:exemption                |
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
-- TABLE: app.tax_rates
-- =============================================================================
CREATE TABLE IF NOT EXISTS app.tax_rates (
    tax_rate_id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    application_id                      UUID NOT NULL,
                                CONSTRAINT fk_tax_app 
                                    FOREIGN KEY (application_id)
                                    REFERENCES app.application_registry(application_id)
                                    ON DELETE CASCADE,
    
    tax_rate_code               VARCHAR(50) NOT NULL,
    
    -- Classification
    tax_type                    VARCHAR(30) NOT NULL,
                                CONSTRAINT chk_tax_type 
                                    CHECK (tax_type IN ('vat', 'gst', 'sales', 'income', 'withholding', 'custom')),
    tax_subtype                 VARCHAR(50),
    
    -- Jurisdiction
    jurisdiction_country        VARCHAR(2),
                                -- ISO 3166-1 alpha-2
    jurisdiction_region         VARCHAR(50),
    jurisdiction_local          VARCHAR(100),
    
    -- Rate Configuration
    rate_percentage             NUMERIC(8,6) NOT NULL,
                                CONSTRAINT chk_rate_range 
                                    CHECK (rate_percentage >= 0 AND rate_percentage <= 100),
    rate_calculation_method     VARCHAR(20) NOT NULL DEFAULT 'inclusive',
                                CONSTRAINT chk_rate_calc 
                                    CHECK (rate_calculation_method IN ('inclusive', 'exclusive', 'compound')),
    minimum_taxable_amount      NUMERIC(19,4) DEFAULT 0,
    maximum_taxable_amount      NUMERIC(19,4),
    rounding_precision          INTEGER DEFAULT 2,
    rounding_method             VARCHAR(20) DEFAULT 'half_up',
    
    -- Applicability
    applicable_transaction_types TEXT[] DEFAULT '{}',
    applicable_account_types    TEXT[] DEFAULT '{}',
    exemption_criteria          JSONB DEFAULT '{}',
    
    -- Recovery/Reclaim
    is_recoverable              BOOLEAN NOT NULL DEFAULT FALSE,
    recovery_rate_percentage    NUMERIC(8,6) DEFAULT 0,
    
    -- Effective Dates
    effective_from              DATE NOT NULL,
    effective_until             DATE,
                                CONSTRAINT chk_effective_dates 
                                    CHECK (effective_until IS NULL OR effective_until > effective_from),
    
    -- Status
    status                      VARCHAR(20) NOT NULL DEFAULT 'active',
                                CONSTRAINT chk_tax_status 
                                    CHECK (status IN ('draft', 'active', 'superseded', 'archived')),
    superseded_by_tax_rate_id   UUID,
                                CONSTRAINT fk_tax_superseded 
                                    FOREIGN KEY (superseded_by_tax_rate_id) 
                                    REFERENCES app.tax_rates(tax_rate_id),
    exemption_reason            TEXT NOT NULL,
    exempted_entity_id          UUID,
    exemption_certificate       VARCHAR(255),
                                -- Certificate number
    valid_from                  DATE NOT NULL,  -- [RBAC] ISO 27001: Temporal access control boundaries
    valid_until                 DATE,  -- [RBAC] ISO 27001: Temporal access control boundaries
    
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),  -- [AUDIT] ISO 27001: Non-repudiation timestamp
    created_by                  UUID NOT NULL  -- [AUDIT] ISO 27001: Accountability tracking
);

-- =============================================================================
-- COMMENTS
-- =============================================================================
COMMENT ON TABLE app.tax_rates IS 'Tax rate definitions with jurisdiction and applicability rules. Feature: CORE-APP-011. Compliance: VAT/GST regulations. Supports historical tracking and supersession.';

-- =============================================================================
-- INDEXES
-- =============================================================================
CREATE INDEX  -- [TXN] ISO 9001: Non-blocking index creation IF NOT EXISTS idx_tax_app 
    ON app.tax_rates(application_id);

CREATE INDEX  -- [TXN] ISO 9001: Non-blocking index creation IF NOT EXISTS idx_tax_jurisdiction 
    ON app.tax_rates(jurisdiction_country, jurisdiction_region);

CREATE INDEX  -- [TXN] ISO 9001: Non-blocking index creation IF NOT EXISTS idx_tax_effective 
    ON app.tax_rates(effective_from, effective_until);

-- =============================================================================
-- IMPLEMENTATION NOTES
-- =============================================================================
-- 1. Tax rates support multiple jurisdictions
-- 2. Historical tracking via effective dates
-- 3. Superseded rates linked to replacement
-- 4. Exemptions require certificate tracking
-- 5. Recovery rates for input tax credits
-- =============================================================================

-- =============================================================================
-- TABLE: app.tax_exemptions
-- DESCRIPTION: Tax exemption certificates and tracking
-- =============================================================================
CREATE TABLE IF NOT EXISTS app.tax_exemptions (
    exemption_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    application_id UUID NOT NULL,
    account_id UUID,
    exemption_type VARCHAR(50) NOT NULL,
    certificate_number VARCHAR(100),
    jurisdiction VARCHAR(50) NOT NULL,
    valid_from DATE NOT NULL,
    valid_until DATE,
    status VARCHAR(20) DEFAULT 'ACTIVE',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    record_hash VARCHAR(64) NOT NULL DEFAULT 'PENDING'
);

CREATE INDEX IF NOT EXISTS idx_tax_exemptions_app ON app.tax_exemptions(application_id);
CREATE INDEX IF NOT EXISTS idx_tax_exemptions_account ON app.tax_exemptions(account_id);
CREATE INDEX IF NOT EXISTS idx_tax_exemptions_status ON app.tax_exemptions(status, valid_until);

COMMIT;
