-- =============================================================================
-- Migration: V027__core_chart_of_accounts
-- Description: Core table: chart_of_accounts
-- Dependencies: V026
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- USSD KERNEL CORE SCHEMA - CHART OF ACCOUNTS
-- Enterprise-Grade Immutable Ledger System
-- =============================================================================
-- FILENAME:    024_chart_of_accounts.sql
-- SCHEMA:      ussd_core
-- TABLE:       chart_of_accounts
-- DESCRIPTION: Master chart of accounts for double-entry bookkeeping
--              supporting hierarchical account structure and multiple
--              accounting standards (GAAP, IFRS).
-- =============================================================================

/*
================================================================================
COMPLIANCE FRAMEWORK
================================================================================

ISO/IEC 27001:2022 (Information Security Management Systems)
├── A.5.9 Information assets - COA inventory
├── A.12.4 Logging and monitoring - COA change monitoring
└── A.18.1 Compliance - Financial reporting compliance

Financial Regulations
├── GAAP/IFRS: Standard-compliant account structure
├── Audit trail: COA change tracking
├── Segregation: Proper account segregation
└── Reporting: Financial statement support

================================================================================
ENTERPRISE POSTGRESQL CODING PRACTICES
================================================================================

1. ACCOUNT TYPES
   - ASSET: Balance sheet assets
   - LIABILITY: Balance sheet liabilities
   - EQUITY: Owner's equity
   - REVENUE: Income accounts
   - EXPENSE: Expense accounts
   - MEMO: Statistical/memo accounts

2. ACCOUNT CATEGORIES
   - Current vs non-current
   - Operating vs non-operating
   - Restricted vs unrestricted

3. HIERARCHY
   - Parent-child relationships
   - Roll-up structure
   - Level indicators

================================================================================
SECURITY IMPLEMENTATION NOTES
================================================================================

COA SECURITY:
- Immutable account codes
- Versioned account changes
- Approval workflow for modifications

================================================================================
PERFORMANCE OPTIMIZATION ANNOTATIONS
================================================================================

INDEXES:
- PRIMARY KEY: coa_code
- TYPE: account_type + coa_code
- PARENT: parent_coa_code
- CATEGORY: account_category

================================================================================
AUDIT AND LOGGING REQUIREMENTS
================================================================================

AUDIT EVENTS:
- ACCOUNT_CREATED
- ACCOUNT_MODIFIED
- ACCOUNT_RETIRED

RETENTION: Permanent
================================================================================
*/

-- -----------------------------------------------------------------------------
-- CREATE TABLE: chart_of_accounts
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.chart_of_accounts (
    -- Primary identifier
    coa_code VARCHAR(50) PRIMARY KEY,
    
    -- Account details
    account_name VARCHAR(200) NOT NULL,
    account_name_local VARCHAR(200),
    account_description TEXT,
    
    -- Classification
    account_type VARCHAR(20) NOT NULL
        CHECK (account_type IN ('ASSET', 'LIABILITY', 'EQUITY', 'REVENUE', 'EXPENSE', 'MEMO')),
    account_category VARCHAR(50)
        CHECK (account_category IN ('CURRENT', 'NON_CURRENT', 'OPERATING', 'NON_OPERATING', 'RESTRICTED', 'UNRESTRICTED')),
    account_subcategory VARCHAR(50),
    
    -- Hierarchy
    parent_coa_code VARCHAR(50) REFERENCES core.chart_of_accounts(coa_code) ON DELETE RESTRICT,
    account_level INTEGER DEFAULT 1 CHECK (account_level > 0 AND account_level <= 10),
    is_leaf_account BOOLEAN DEFAULT TRUE,
    
    -- Normal balance
    normal_balance VARCHAR(6) NOT NULL
        CHECK (normal_balance IN ('DEBIT', 'CREDIT')),
    
    -- Configuration
    is_active BOOLEAN DEFAULT TRUE,
    is_system_account BOOLEAN DEFAULT FALSE,
    is_bank_account BOOLEAN DEFAULT FALSE,
    is_cash_account BOOLEAN DEFAULT FALSE,
    is_control_account BOOLEAN DEFAULT FALSE,
    requires_cost_center BOOLEAN DEFAULT FALSE,
    requires_project BOOLEAN DEFAULT FALSE,
    requires_customer BOOLEAN DEFAULT FALSE,
    
    -- Application scope
    application_id UUID,  -- NULL for system-wide accounts
    
    -- Financial statement mapping
    balance_sheet_section VARCHAR(50)
        CHECK (balance_sheet_section IN ('CURRENT_ASSETS', 'NON_CURRENT_ASSETS', 'CURRENT_LIABILITIES', 'NON_CURRENT_LIABILITIES', 'EQUITY')),
    income_statement_section VARCHAR(50)
        CHECK (income_statement_section IN ('REVENUE', 'COST_OF_SALES', 'OPERATING_EXPENSES', 'OTHER_INCOME', 'OTHER_EXPENSES')),
    cash_flow_section VARCHAR(50)
        CHECK (cash_flow_section IN ('OPERATING', 'INVESTING', 'FINANCING')),
    
    -- Reporting codes for regulatory filing
    tax_reporting_code VARCHAR(50),
    regulatory_reporting_code VARCHAR(50),
    
    -- Validity period
    valid_from DATE NOT NULL DEFAULT CURRENT_DATE,
    valid_to DATE,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    superseded_by VARCHAR(50) REFERENCES core.chart_of_accounts(coa_code),
    record_hash VARCHAR(64) NOT NULL DEFAULT 'PENDING'
);

-- -----------------------------------------------------------------------------
-- INDEXES
-- -----------------------------------------------------------------------------
-- Account type queries
CREATE INDEX IF NOT EXISTS idx_coa_type 
    ON core.chart_of_accounts(account_type, is_active);

-- Hierarchy queries
CREATE INDEX IF NOT EXISTS idx_coa_parent 
    ON core.chart_of_accounts(parent_coa_code) 
    WHERE parent_coa_code IS NOT NULL;

-- Category queries
CREATE INDEX IF NOT EXISTS idx_coa_category 
    ON core.chart_of_accounts(account_category, account_type);

-- Active accounts
CREATE INDEX IF NOT EXISTS idx_coa_active 
    ON core.chart_of_accounts(coa_code) 
    WHERE is_active = TRUE;

-- Leaf accounts (for posting)
CREATE INDEX IF NOT EXISTS idx_coa_leaf 
    ON core.chart_of_accounts(account_type, coa_code) 
    WHERE is_leaf_account = TRUE AND is_active = TRUE;

-- Application-scoped accounts
CREATE INDEX IF NOT EXISTS idx_coa_application 
    ON core.chart_of_accounts(application_id, account_type) 
    WHERE application_id IS NOT NULL;

-- Financial statement mapping
CREATE INDEX IF NOT EXISTS idx_coa_bs_section 
    ON core.chart_of_accounts(balance_sheet_section, account_type) 
    WHERE balance_sheet_section IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_coa_is_section 
    ON core.chart_of_accounts(income_statement_section) 
    WHERE income_statement_section IS NOT NULL;

-- -----------------------------------------------------------------------------
-- IMMUTABILITY TRIGGERS
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_coa_prevent_update ON core.chart_of_accounts;
CREATE TRIGGER trg_coa_prevent_update
    BEFORE UPDATE ON core.chart_of_accounts
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

DROP TRIGGER IF EXISTS trg_coa_prevent_delete ON core.chart_of_accounts;
CREATE TRIGGER trg_coa_prevent_delete
    BEFORE DELETE ON core.chart_of_accounts
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

-- -----------------------------------------------------------------------------
-- HASH COMPUTATION TRIGGER
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.compute_coa_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.record_hash := core.generate_hash(
        NEW.coa_code || 
        NEW.account_name || 
        NEW.account_type ||
        COALESCE(NEW.parent_coa_code, '') ||
        NEW.normal_balance ||
        NEW.valid_from::TEXT ||
        NEW.created_at::TEXT
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_coa_compute_hash ON core.chart_of_accounts;
CREATE TRIGGER trg_coa_compute_hash
    BEFORE INSERT ON core.chart_of_accounts
    FOR EACH ROW
    EXECUTE FUNCTION core.compute_coa_hash();

-- -----------------------------------------------------------------------------
-- HELPER FUNCTIONS
-- -----------------------------------------------------------------------------

-- Function to get account hierarchy
CREATE OR REPLACE FUNCTION core.get_account_hierarchy(
    p_coa_code VARCHAR(50)
)
RETURNS TABLE (
    level INTEGER,
    coa_code VARCHAR(50),
    account_name VARCHAR(200),
    account_type VARCHAR(20),
    parent_coa_code VARCHAR(50),
    is_leaf_account BOOLEAN
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE hierarchy AS (
        -- Base case: start with the given account
        SELECT 
            c.account_level as level,
            c.coa_code,
            c.account_name,
            c.account_type,
            c.parent_coa_code,
            c.is_leaf_account
        FROM core.chart_of_accounts c
        WHERE c.coa_code = p_coa_code
        
        UNION ALL
        
        -- Recursive case: get all children
        SELECT 
            c.account_level as level,
            c.coa_code,
            c.account_name,
            c.account_type,
            c.parent_coa_code,
            c.is_leaf_account
        FROM core.chart_of_accounts c
        INNER JOIN hierarchy h ON c.parent_coa_code = h.coa_code
    )
    SELECT * FROM hierarchy ORDER BY level, coa_code;
END;
$$;

-- Function to get account path
CREATE OR REPLACE FUNCTION core.get_account_path(
    p_coa_code VARCHAR(50)
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_path TEXT := '';
    v_current_code VARCHAR(50) := p_coa_code;
    v_record RECORD;
BEGIN
    WHILE v_current_code IS NOT NULL LOOP
        SELECT coa_code, account_name, parent_coa_code 
        INTO v_record
        FROM core.chart_of_accounts
        WHERE coa_code = v_current_code;
        
        IF NOT FOUND THEN
            EXIT;
        END IF;
        
        IF v_path = '' THEN
            v_path := v_record.account_name;
        ELSE
            v_path := v_record.account_name || ' > ' || v_path;
        END IF;
        
        v_current_code := v_record.parent_coa_code;
    END LOOP;
    
    RETURN v_path;
END;
$$;

-- Function to validate COA code exists and is active
CREATE OR REPLACE FUNCTION core.validate_coa_code(
    p_coa_code VARCHAR(50),
    p_check_leaf BOOLEAN DEFAULT FALSE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_exists BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 
        FROM core.chart_of_accounts 
        WHERE coa_code = p_coa_code 
          AND is_active = TRUE
          AND (valid_to IS NULL OR valid_to >= CURRENT_DATE)
          AND (NOT p_check_leaf OR is_leaf_account = TRUE)
    ) INTO v_exists;
    
    RETURN v_exists;
END;
$$;

-- Function to get trial balance structure
CREATE OR REPLACE FUNCTION core.get_trial_balance_structure()
RETURNS TABLE (
    coa_code VARCHAR(50),
    account_name VARCHAR(200),
    account_type VARCHAR(20),
    normal_balance VARCHAR(6),
    parent_coa_code VARCHAR(50),
    level INTEGER,
    is_leaf_account BOOLEAN
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        c.coa_code,
        c.account_name,
        c.account_type,
        c.normal_balance,
        c.parent_coa_code,
        c.account_level,
        c.is_leaf_account
    FROM core.chart_of_accounts c
    WHERE c.is_active = TRUE
    ORDER BY c.coa_code;
END;
$$;

-- -----------------------------------------------------------------------------
-- INITIAL DATA: Standard Chart of Accounts
-- -----------------------------------------------------------------------------
INSERT INTO core.chart_of_accounts (
    coa_code, account_name, account_type, normal_balance, 
    account_level, is_leaf_account, is_system_account,
    balance_sheet_section, created_by
) VALUES 
-- Assets (1000 series)
('1000', 'ASSETS', 'ASSET', 'DEBIT', 1, FALSE, TRUE, 'CURRENT_ASSETS', NULL),
('1100', 'Current Assets', 'ASSET', 'DEBIT', 2, FALSE, TRUE, 'CURRENT_ASSETS', NULL),
('1110', 'Cash and Cash Equivalents', 'ASSET', 'DEBIT', 3, FALSE, TRUE, 'CURRENT_ASSETS', NULL),
('1111', 'Operating Cash', 'ASSET', 'DEBIT', 4, TRUE, TRUE, 'CURRENT_ASSETS', NULL),
('1112', 'Reserve Cash', 'ASSET', 'DEBIT', 4, TRUE, TRUE, 'CURRENT_ASSETS', NULL),
('1120', 'Receivables', 'ASSET', 'DEBIT', 3, FALSE, TRUE, 'CURRENT_ASSETS', NULL),
('1121', 'Customer Receivables', 'ASSET', 'DEBIT', 4, TRUE, TRUE, 'CURRENT_ASSETS', NULL),
('1122', 'Intercompany Receivables', 'ASSET', 'DEBIT', 4, TRUE, TRUE, 'CURRENT_ASSETS', NULL),
('1130', 'Suspense Accounts', 'ASSET', 'DEBIT', 3, TRUE, TRUE, 'CURRENT_ASSETS', NULL),

-- Liabilities (2000 series)
('2000', 'LIABILITIES', 'LIABILITY', 'CREDIT', 1, FALSE, TRUE, 'CURRENT_LIABILITIES', NULL),
('2100', 'Current Liabilities', 'LIABILITY', 'CREDIT', 2, FALSE, TRUE, 'CURRENT_LIABILITIES', NULL),
('2110', 'Payables', 'LIABILITY', 'CREDIT', 3, FALSE, TRUE, 'CURRENT_LIABILITIES', NULL),
('2111', 'Customer Deposits', 'LIABILITY', 'CREDIT', 4, TRUE, TRUE, 'CURRENT_LIABILITIES', NULL),
('2112', 'Merchant Payables', 'LIABILITY', 'CREDIT', 4, TRUE, TRUE, 'CURRENT_LIABILITIES', NULL),
('2120', 'Accrued Expenses', 'LIABILITY', 'CREDIT', 3, TRUE, TRUE, 'CURRENT_LIABILITIES', NULL),

-- Equity (3000 series)
('3000', 'EQUITY', 'EQUITY', 'CREDIT', 1, FALSE, TRUE, 'EQUITY', NULL),
('3100', 'Retained Earnings', 'EQUITY', 'CREDIT', 2, TRUE, TRUE, 'EQUITY', NULL),
('3200', 'Current Year Earnings', 'EQUITY', 'CREDIT', 2, TRUE, TRUE, 'EQUITY', NULL),

-- Revenue (4000 series)
('4000', 'REVENUE', 'REVENUE', 'CREDIT', 1, FALSE, TRUE, NULL, NULL),
('4100', 'Transaction Revenue', 'REVENUE', 'CREDIT', 2, TRUE, TRUE, NULL, NULL),
('4200', 'Fee Revenue', 'REVENUE', 'CREDIT', 2, TRUE, TRUE, NULL, NULL),
('4300', 'Interest Revenue', 'REVENUE', 'CREDIT', 2, TRUE, TRUE, NULL, NULL),

-- Expenses (5000 series)
('5000', 'EXPENSES', 'EXPENSE', 'DEBIT', 1, FALSE, TRUE, NULL, NULL),
('5100', 'Operating Expenses', 'EXPENSE', 'DEBIT', 2, FALSE, TRUE, NULL, NULL),
('5110', 'Personnel Costs', 'EXPENSE', 'DEBIT', 3, TRUE, TRUE, NULL, NULL),
('5120', 'Technology Costs', 'EXPENSE', 'DEBIT', 3, TRUE, TRUE, NULL, NULL),
('5130', 'Transaction Costs', 'EXPENSE', 'DEBIT', 3, TRUE, TRUE, NULL, NULL),
('5200', 'Bad Debt Expense', 'EXPENSE', 'DEBIT', 2, TRUE, TRUE, NULL, NULL),
('5300', 'Provision for Losses', 'EXPENSE', 'DEBIT', 2, TRUE, TRUE, NULL, NULL);

-- Disable immutability trigger for initial data setup
ALTER TABLE core.chart_of_accounts DISABLE TRIGGER trg_coa_prevent_update;

-- Update parent references
UPDATE core.chart_of_accounts SET parent_coa_code = '1000' WHERE coa_code IN ('1100');
UPDATE core.chart_of_accounts SET parent_coa_code = '1100' WHERE coa_code IN ('1110', '1120', '1130');
UPDATE core.chart_of_accounts SET parent_coa_code = '1110' WHERE coa_code IN ('1111', '1112');
UPDATE core.chart_of_accounts SET parent_coa_code = '1120' WHERE coa_code IN ('1121', '1122');

UPDATE core.chart_of_accounts SET parent_coa_code = '2000' WHERE coa_code IN ('2100');
UPDATE core.chart_of_accounts SET parent_coa_code = '2100' WHERE coa_code IN ('2110', '2120');
UPDATE core.chart_of_accounts SET parent_coa_code = '2110' WHERE coa_code IN ('2111', '2112');

UPDATE core.chart_of_accounts SET parent_coa_code = '3000' WHERE coa_code IN ('3100', '3200');

UPDATE core.chart_of_accounts SET parent_coa_code = '4000' WHERE coa_code IN ('4100', '4200', '4300');

UPDATE core.chart_of_accounts SET parent_coa_code = '5000' WHERE coa_code IN ('5100', '5200', '5300');
UPDATE core.chart_of_accounts SET parent_coa_code = '5100' WHERE coa_code IN ('5110', '5120', '5130');

-- Re-enable immutability trigger after initial data setup
ALTER TABLE core.chart_of_accounts ENABLE TRIGGER trg_coa_prevent_update;

-- -----------------------------------------------------------------------------
-- COMMENTS
-- -----------------------------------------------------------------------------
COMMENT ON TABLE core.chart_of_accounts IS 'Master chart of accounts for double-entry bookkeeping';
COMMENT ON COLUMN core.chart_of_accounts.coa_code IS 'Unique chart of account code (primary key)';
COMMENT ON COLUMN core.chart_of_accounts.account_type IS 'ASSET, LIABILITY, EQUITY, REVENUE, EXPENSE, or MEMO';
COMMENT ON COLUMN core.chart_of_accounts.normal_balance IS 'DEBIT or CREDIT - the expected balance direction';
COMMENT ON COLUMN core.chart_of_accounts.is_leaf_account IS 'TRUE if postings are allowed to this account';

-- =============================================================================
-- END OF FILE
-- =============================================================================

COMMIT;
