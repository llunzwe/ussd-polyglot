-- =============================================================================
-- Migration: V030__core_bad_debt_provision
-- Description: Core table: bad_debt_provision
-- Dependencies: V029
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- USSD KERNEL CORE SCHEMA - BAD DEBT PROVISION
-- Enterprise-Grade Immutable Ledger System
-- =============================================================================
-- FILENAME:    027_bad_debt_provision.sql
-- SCHEMA:      ussd_core
-- TABLE:       bad_debt_provision
-- DESCRIPTION: Bad debt provisioning records for accounting compliance
--              with IFRS 9 expected credit loss (ECL) requirements.
-- =============================================================================

/*
================================================================================
COMPLIANCE FRAMEWORK
================================================================================

ISO/IEC 27001:2022 (Information Security Management Systems)
├── A.12.4 Logging and monitoring - Provision monitoring
├── A.18.1 Compliance - IFRS 9 compliance
└── A.18.2 Compliance - Audit trail

IFRS 9 Compliance
├── ECL calculation: Expected credit loss methodology
├── Staging: 3-stage impairment model
├── Forward-looking: Macroeconomic factors
└── Disclosure: Required provision disclosures

Financial Regulations
├── Capital adequacy: Provision impact on capital
├── Regulatory reporting: Provision reporting
├── Audit: Provision methodology audit
└── Stress testing: Provision scenario analysis

================================================================================
ENTERPRISE POSTGRESQL CODING PRACTICES
================================================================================

1. STAGES (IFRS 9)
   - STAGE_1: 12-month ECL
   - STAGE_2: Lifetime ECL (significant increase in credit risk)
   - STAGE_3: Lifetime ECL (credit impaired)

2. PROVISION TYPES
   - SPECIFIC: Individual asset provision
   - COLLECTIVE: Portfolio-level provision
   - GENERAL: General reserve

3. CALCULATION
   - PD: Probability of default
   - LGD: Loss given default
   - EAD: Exposure at default
   - ECL: Expected credit loss

================================================================================
SECURITY IMPLEMENTATION NOTES
================================================================================

PROVISION SECURITY:
- Immutable provision records
- Calculation audit trail
- Approval workflow for adjustments

================================================================================
PERFORMANCE OPTIMIZATION ANNOTATIONS
================================================================================

INDEXES:
- PRIMARY KEY: provision_id
- ACCOUNT: account_id + calculation_date
- DATE: calculation_date
- STAGE: provision_stage

================================================================================
AUDIT AND LOGGING REQUIREMENTS
================================================================================

AUDIT EVENTS:
- PROVISION_CALCULATED
- PROVISION_ADJUSTED
- PROVISION_RELEASED

RETENTION: 7 years
================================================================================
*/

-- -----------------------------------------------------------------------------
-- CREATE TABLE: bad_debt_provision
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.bad_debt_provision (
    -- Primary identifier
    provision_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    provision_reference VARCHAR(100) UNIQUE NOT NULL,
    
    -- Account/asset reference
    account_id UUID REFERENCES core.account_registry(account_id) ON DELETE RESTRICT,
    portfolio_segment VARCHAR(100),
    product_type VARCHAR(50),
    
    -- IFRS 9 Stage
    provision_stage VARCHAR(20) NOT NULL
        CHECK (provision_stage IN ('STAGE_1', 'STAGE_2', 'STAGE_3')),
    
    -- Provision type
    provision_type VARCHAR(20) NOT NULL
        CHECK (provision_type IN ('SPECIFIC', 'COLLECTIVE', 'GENERAL')),
    
    -- Calculation inputs
    exposure_amount NUMERIC(20, 8) NOT NULL CHECK (exposure_amount >= 0),
    probability_of_default NUMERIC(10, 6) NOT NULL CHECK (probability_of_default >= 0 AND probability_of_default <= 1),
    loss_given_default NUMERIC(10, 6) NOT NULL CHECK (loss_given_default >= 0 AND loss_given_default <= 1),
    time_horizon_months INTEGER NOT NULL CHECK (time_horizon_months > 0),
    discount_rate NUMERIC(10, 6) CHECK (discount_rate >= 0),
    
    -- Calculation result (ECL = PD * LGD * EAD)
    provision_amount NUMERIC(20, 8) NOT NULL CHECK (provision_amount >= 0),
    provision_percentage NUMERIC(10, 6) GENERATED ALWAYS AS (
        CASE 
            WHEN exposure_amount > 0 THEN (provision_amount / exposure_amount) * 100
            ELSE 0
        END
    ) STORED,
    
    -- Calculation context
    calculation_date DATE NOT NULL,
    calculation_method VARCHAR(50),
    macroeconomic_scenario VARCHAR(50) DEFAULT 'BASELINE'
        CHECK (macroeconomic_scenario IN ('BASELINE', 'DOWNTURN', 'UPTURN', 'STRESS')),
    model_version VARCHAR(20),
    model_parameters JSONB,
    
    -- Status
    is_adjusted BOOLEAN DEFAULT FALSE,
    adjustment_reason TEXT,
    original_provision_amount NUMERIC(20, 8),
    
    -- COA posting
    posted_to_coa BOOLEAN DEFAULT FALSE,
    posting_reference VARCHAR(100),
    posted_at TIMESTAMPTZ,
    coa_code VARCHAR(50),
    
    -- Release tracking
    is_released BOOLEAN DEFAULT FALSE,
    released_at TIMESTAMPTZ,
    released_by UUID,
    release_amount NUMERIC(20, 8),
    release_reason TEXT,
    
    -- Write-off linkage
    write_off_reference VARCHAR(100),
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    calculated_by UUID,
    approved_by UUID,
    approved_at TIMESTAMPTZ,
    record_hash VARCHAR(64) NOT NULL DEFAULT 'PENDING'
);

-- -----------------------------------------------------------------------------
-- INDEXES
-- -----------------------------------------------------------------------------
-- Account-based lookups
CREATE INDEX IF NOT EXISTS idx_bad_debt_account 
    ON core.bad_debt_provision(account_id, calculation_date DESC);

-- Calculation date queries
CREATE INDEX IF NOT EXISTS idx_bad_debt_calculation_date 
    ON core.bad_debt_provision(calculation_date, provision_stage);

-- Stage-based reporting
CREATE INDEX IF NOT EXISTS idx_bad_debt_stage 
    ON core.bad_debt_provision(provision_stage, calculation_date);

-- Portfolio analysis
CREATE INDEX IF NOT EXISTS idx_bad_debt_portfolio 
    ON core.bad_debt_provision(portfolio_segment, calculation_date);

-- Unposted provisions
CREATE INDEX IF NOT EXISTS idx_bad_debt_unposted 
    ON core.bad_debt_provision(posted_to_coa, calculation_date) 
    WHERE posted_to_coa = FALSE;

-- Released provisions
CREATE INDEX IF NOT EXISTS idx_bad_debt_released 
    ON core.bad_debt_provision(is_released, released_at) 
    WHERE is_released = TRUE;

-- COA posting tracking
CREATE INDEX IF NOT EXISTS idx_bad_debt_coa 
    ON core.bad_debt_provision(coa_code, posted_at) 
    WHERE coa_code IS NOT NULL;

-- -----------------------------------------------------------------------------
-- IMMUTABILITY TRIGGERS
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_bad_debt_prevent_update ON core.bad_debt_provision;
CREATE TRIGGER trg_bad_debt_prevent_update
    BEFORE UPDATE ON core.bad_debt_provision
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

DROP TRIGGER IF EXISTS trg_bad_debt_prevent_delete ON core.bad_debt_provision;
CREATE TRIGGER trg_bad_debt_prevent_delete
    BEFORE DELETE ON core.bad_debt_provision
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

-- -----------------------------------------------------------------------------
-- HASH COMPUTATION TRIGGER
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.compute_provision_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.record_hash := core.generate_hash(
        NEW.provision_id::TEXT || 
        NEW.provision_reference || 
        COALESCE(NEW.account_id::TEXT, '') ||
        COALESCE(NEW.portfolio_segment, '') ||
        NEW.provision_stage ||
        NEW.provision_type ||
        NEW.exposure_amount::TEXT ||
        NEW.probability_of_default::TEXT ||
        NEW.loss_given_default::TEXT ||
        NEW.provision_amount::TEXT ||
        NEW.calculation_date::TEXT ||
        NEW.created_at::TEXT
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_bad_debt_compute_hash ON core.bad_debt_provision;
CREATE TRIGGER trg_bad_debt_compute_hash
    BEFORE INSERT ON core.bad_debt_provision
    FOR EACH ROW
    EXECUTE FUNCTION core.compute_provision_hash();

-- -----------------------------------------------------------------------------
-- HELPER FUNCTIONS
-- -----------------------------------------------------------------------------

-- Function to calculate ECL provision
CREATE OR REPLACE FUNCTION core.calculate_ecl_provision(
    p_exposure_amount NUMERIC,
    p_probability_of_default NUMERIC,
    p_loss_given_default NUMERIC,
    p_time_horizon_months INTEGER,
    p_discount_rate NUMERIC DEFAULT 0
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_ecl NUMERIC;
    v_discount_factor NUMERIC;
BEGIN
    -- Calculate discount factor (if discount rate provided)
    IF p_discount_rate > 0 THEN
        v_discount_factor := 1 / POWER(1 + p_discount_rate, p_time_horizon_months / 12.0);
    ELSE
        v_discount_factor := 1;
    END IF;
    
    -- ECL = PD * LGD * EAD * Discount Factor
    v_ecl := p_exposure_amount * p_probability_of_default * p_loss_given_default * v_discount_factor;
    
    RETURN ROUND(v_ecl, 8);
END;
$$;

-- Function to create a provision record
CREATE OR REPLACE FUNCTION core.create_provision(
    p_account_id UUID,
    p_portfolio_segment VARCHAR(100),
    p_provision_stage VARCHAR(20),
    p_provision_type VARCHAR(20),
    p_exposure_amount NUMERIC,
    p_probability_of_default NUMERIC,
    p_loss_given_default NUMERIC,
    p_time_horizon_months INTEGER,
    p_calculation_date DATE,
    p_calculated_by UUID,
    p_discount_rate NUMERIC DEFAULT 0,
    p_macro_scenario VARCHAR(50) DEFAULT 'BASELINE',
    p_model_version VARCHAR(20) DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_provision_id UUID;
    v_reference VARCHAR(100);
    v_provision_amount NUMERIC;
BEGIN
    -- Calculate provision amount
    v_provision_amount := core.calculate_ecl_provision(
        p_exposure_amount,
        p_probability_of_default,
        p_loss_given_default,
        p_time_horizon_months,
        p_discount_rate
    );
    
    -- Generate reference
    v_reference := 'PRV-' || p_provision_stage || '-' || TO_CHAR(p_calculation_date, 'YYYYMMDD') || '-' || SUBSTRING(MD5(RANDOM()::TEXT), 1, 6);
    
    INSERT INTO core.bad_debt_provision (
        provision_reference,
        account_id,
        portfolio_segment,
        provision_stage,
        provision_type,
        exposure_amount,
        probability_of_default,
        loss_given_default,
        time_horizon_months,
        discount_rate,
        provision_amount,
        calculation_date,
        calculated_by,
        macroeconomic_scenario,
        model_version
    ) VALUES (
        v_reference,
        p_account_id,
        p_portfolio_segment,
        p_provision_stage,
        p_provision_type,
        p_exposure_amount,
        p_probability_of_default,
        p_loss_given_default,
        p_time_horizon_months,
        p_discount_rate,
        v_provision_amount,
        p_calculation_date,
        p_calculated_by,
        p_macro_scenario,
        p_model_version
    ) RETURNING provision_id INTO v_provision_id;
    
    RETURN v_provision_id;
END;
$$;

-- Function to get provision summary by stage
CREATE OR REPLACE FUNCTION core.get_provision_summary_by_stage(
    p_calculation_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    provision_stage VARCHAR(20),
    provision_count BIGINT,
    total_exposure NUMERIC,
    total_provision NUMERIC,
    avg_pd NUMERIC,
    avg_lgd NUMERIC,
    coverage_ratio NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        bdp.provision_stage,
        COUNT(*) as provision_count,
        SUM(bdp.exposure_amount) as total_exposure,
        SUM(bdp.provision_amount) as total_provision,
        AVG(bdp.probability_of_default)::NUMERIC as avg_pd,
        AVG(bdp.loss_given_default)::NUMERIC as avg_lgd,
        CASE 
            WHEN SUM(bdp.exposure_amount) > 0 
            THEN ROUND((SUM(bdp.provision_amount) / SUM(bdp.exposure_amount)) * 100, 4)
            ELSE 0
        END as coverage_ratio
    FROM core.bad_debt_provision bdp
    WHERE bdp.calculation_date = p_calculation_date
      AND bdp.is_released = FALSE
    GROUP BY bdp.provision_stage
    ORDER BY bdp.provision_stage;
END;
$$;

-- Function to get provision summary by portfolio
CREATE OR REPLACE FUNCTION core.get_provision_summary_by_portfolio(
    p_calculation_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    portfolio_segment VARCHAR(100),
    provision_count BIGINT,
    total_exposure NUMERIC,
    total_provision NUMERIC,
    stage_1_provision NUMERIC,
    stage_2_provision NUMERIC,
    stage_3_provision NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        bdp.portfolio_segment,
        COUNT(*) as provision_count,
        SUM(bdp.exposure_amount) as total_exposure,
        SUM(bdp.provision_amount) as total_provision,
        SUM(bdp.provision_amount) FILTER (WHERE bdp.provision_stage = 'STAGE_1') as stage_1_provision,
        SUM(bdp.provision_amount) FILTER (WHERE bdp.provision_stage = 'STAGE_2') as stage_2_provision,
        SUM(bdp.provision_amount) FILTER (WHERE bdp.provision_stage = 'STAGE_3') as stage_3_provision
    FROM core.bad_debt_provision bdp
    WHERE bdp.calculation_date = p_calculation_date
      AND bdp.is_released = FALSE
    GROUP BY bdp.portfolio_segment
    ORDER BY total_provision DESC;
END;
$$;

-- Function to get provision history for an account
CREATE OR REPLACE FUNCTION core.get_account_provision_history(
    p_account_id UUID
)
RETURNS TABLE (
    calculation_date DATE,
    provision_stage VARCHAR(20),
    exposure_amount NUMERIC,
    provision_amount NUMERIC,
    pd NUMERIC,
    lgd NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        bdp.calculation_date,
        bdp.provision_stage,
        bdp.exposure_amount,
        bdp.provision_amount,
        bdp.probability_of_default,
        bdp.loss_given_default
    FROM core.bad_debt_provision bdp
    WHERE bdp.account_id = p_account_id
    ORDER BY bdp.calculation_date DESC, bdp.created_at DESC;
END;
$$;

-- -----------------------------------------------------------------------------
-- COMMENTS
-- -----------------------------------------------------------------------------
COMMENT ON TABLE core.bad_debt_provision IS 'Bad debt provisioning records for IFRS 9 ECL compliance';
COMMENT ON COLUMN core.bad_debt_provision.provision_id IS 'Unique identifier for the provision';
COMMENT ON COLUMN core.bad_debt_provision.provision_stage IS 'IFRS 9 stage: STAGE_1, STAGE_2, or STAGE_3';
COMMENT ON COLUMN core.bad_debt_provision.provision_amount IS 'Expected Credit Loss (ECL) amount';
COMMENT ON COLUMN core.bad_debt_provision.probability_of_default IS 'PD - Probability of default (0-1)';
COMMENT ON COLUMN core.bad_debt_provision.loss_given_default IS 'LGD - Loss given default (0-1)';

-- =============================================================================
-- END OF FILE
-- =============================================================================

COMMIT;
