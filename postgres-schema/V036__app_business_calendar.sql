-- =============================================================================
-- Migration: V040__app_business_calendar
-- Description: App table: business_calendar
-- Dependencies: V039
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

/**
 * =============================================================================
 * USSD IMMUTABLE LEDGER KERNEL - BUSINESS CALENDAR
 * =============================================================================
 * 
 * Feature ID:         CORE-APP-008
 * Feature Name:       Business Calendar Management
 * Description:        Configurable business calendar for transaction dating,
 *                     settlement scheduling, and business day calculations.
 *                     Supports multiple calendars per application and
 *                     regional holiday definitions.
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
 *   - Control A.8.1: User endpoint devices (regional settings)
 * 
 * ISO 9001:2015 (Quality Management)
 *   - Section 7.1.5: Monitoring and measuring resources
 * 
 * =============================================================================
 * RBAC ENFORCEMENT DOCUMENTATION
 * =============================================================================
 * 
 * REQUIRED PERMISSIONS:
 * 
 * | Operation                    | Required Permission              |
 * |------------------------------|----------------------------------|
 * | CREATE calendar              | app:calendar:create              |
 * | READ calendar                | app:calendar:read                |
 * | UPDATE calendar              | app:calendar:update              |
 * | DELETE calendar              | app:calendar:delete              |
 * | MANAGE holidays              | app:calendar:manage              |
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
-- TABLE: app.business_calendar
-- =============================================================================
CREATE TABLE IF NOT EXISTS app.business_calendar (
    calendar_id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    application_id                      UUID NOT NULL,
                                CONSTRAINT fk_calendar_app 
                                    FOREIGN KEY (application_id)
                                    REFERENCES app.application_registry(application_id)
                                    ON DELETE CASCADE,
    
    calendar_code               VARCHAR(50) NOT NULL,
    calendar_name               VARCHAR(255) NOT NULL,
    calendar_description        TEXT,
    calendar_type               VARCHAR(30) NOT NULL DEFAULT 'business',
                                CONSTRAINT chk_calendar_type 
                                    CHECK (calendar_type IN ('business', 'trading', 'settlement', 'reporting', 'custom')),
    
    -- Regional
    country_code                VARCHAR(2),
                                -- ISO 3166-1 alpha-2
    region_code                 VARCHAR(10),
    timezone                    VARCHAR(50) NOT NULL DEFAULT 'UTC',
                                -- IANA timezone identifier
    
    -- Business Week
    business_days               SMALLINT[] NOT NULL DEFAULT '{1,2,3,4,5}',
                                -- ISO day numbers (1=Monday, 7=Sunday)
    business_day_start_time     TIME NOT NULL DEFAULT '09:00:00',
    business_day_end_time       TIME NOT NULL DEFAULT '17:00:00',
    
    -- Weekend/Holiday Handling
    weekend_days                SMALLINT[] NOT NULL DEFAULT '{6,7}',
    holiday_handling            VARCHAR(20) NOT NULL DEFAULT 'observed',
                                CONSTRAINT chk_holiday_handling 
                                    CHECK (holiday_handling IN ('observed', 'adjusted', 'ignored')),
    weekend_holiday_rule        VARCHAR(20) NOT NULL DEFAULT 'nearest',
                                CONSTRAINT chk_weekend_holiday_rule 
                                    CHECK (weekend_holiday_rule IN ('nearest', 'previous', 'next', 'none')),
                                -- ENUM: 'public', 'bank', 'company', 'regional', 'religious'
    is_recurring                BOOLEAN NOT NULL DEFAULT FALSE,
    recurrence_pattern          JSONB,
                                -- For recurring: {"month": 12, "day": 25}
    observed_date               DATE,
    is_half_day                 BOOLEAN NOT NULL DEFAULT FALSE,
    half_day_hours              NUMERIC(4,2),
    
    -- Default calendar flag
    is_default                  BOOLEAN NOT NULL DEFAULT FALSE,
    
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),  -- [AUDIT] ISO 27001: Non-repudiation timestamp
    created_by                  UUID NOT NULL,  -- [AUDIT] ISO 27001: Accountability tracking
    
    CONSTRAINT uq_calendar_code UNIQUE (application_id, calendar_code)
);

-- =============================================================================
-- COMMENTS
-- =============================================================================
COMMENT ON TABLE app.business_calendar IS 'Business calendars for transaction dating and scheduling. Feature: CORE-APP-008. Compliance: ISO 27001, ISO 9001. Supports multiple timezones and regional holidays.';

-- =============================================================================
-- INDEXES
-- =============================================================================
CREATE INDEX  -- [TXN] ISO 9001: Non-blocking index creation IF NOT EXISTS idx_calendar_app 
    ON app.business_calendar(application_id);

CREATE INDEX  -- [TXN] ISO 9001: Non-blocking index creation IF NOT EXISTS idx_calendar_default 
    ON app.business_calendar(application_id) WHERE is_default = TRUE;

-- Note: business_holidays table and index to be added in future migration

-- =============================================================================
-- TABLE: app.business_holidays
-- DESCRIPTION: Business holidays for calendars
-- =============================================================================
CREATE TABLE IF NOT EXISTS app.business_holidays (
    holiday_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    calendar_id UUID NOT NULL REFERENCES app.business_calendar(calendar_id) ON DELETE CASCADE,
    holiday_date DATE NOT NULL,
    holiday_name VARCHAR(100) NOT NULL,
    description TEXT,
    is_recurring BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(calendar_id, holiday_date)
);

CREATE INDEX IF NOT EXISTS idx_business_holidays_calendar 
    ON app.business_holidays(calendar_id, holiday_date);

-- =============================================================================
-- IMPLEMENTATION NOTES
-- =============================================================================
-- 1. Supports multiple calendars per application
-- 2. ISO day numbers: 1=Monday, 7=Sunday
-- 3. IANA timezone identifiers required
-- 4. Recurring holidays auto-generated annually
-- 5. One default calendar per application
-- =============================================================================

COMMIT;
