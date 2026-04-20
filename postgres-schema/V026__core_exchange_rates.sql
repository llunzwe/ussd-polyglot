-- =============================================================================
-- Migration: V029__core_exchange_rates
-- Description: Core table: exchange_rates
-- Dependencies: V028
-- Generated: 2026-04-02 16:56:46 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- USSD KERNEL CORE SCHEMA - EXCHANGE RATES
-- Enterprise-Grade Immutable Ledger System
-- =============================================================================
-- FILENAME:    026_exchange_rates.sql
-- SCHEMA:      ussd_core
-- TABLE:       exchange_rates
-- DESCRIPTION: Historical and current exchange rates for multi-currency
--              transactions with source attribution and validity periods.
-- =============================================================================

/*
================================================================================
COMPLIANCE FRAMEWORK
================================================================================

ISO/IEC 27001:2022 (Information Security Management Systems)
├── A.12.4 Logging and monitoring - Rate change monitoring
├── A.14.2 Business continuity - Rate source redundancy
└── A.18.1 Compliance - Regulatory rate reporting

Financial Regulations
├── Rate sourcing: Authorized rate sources only
├── Audit trail: Complete rate history
├── Markup disclosure: Transparent fee structure
└── Reporting: Regulatory rate reporting

================================================================================
ENTERPRISE POSTGRESQL CODING PRACTICES
================================================================================

1. RATE TYPES
   - SPOT: Current market rate
   - FORWARD: Future delivery rate
   - FIXING: Daily fixing rate
   - INTERNAL: Institution-specific rate

2. RATE SOURCES
   - Central bank rates
   - Market data providers (Reuters, Bloomberg)
   - Internal treasury
   - Correspondent bank rates

3. VALIDITY
   - Valid from/to timestamps
   - Rate expiration
   - Historical rate preservation

================================================================================
SECURITY IMPLEMENTATION NOTES
================================================================================

RATE INTEGRITY:
- Source authentication
- Rate validation ranges
- Tamper detection
- Audit trail

================================================================================
PERFORMANCE OPTIMIZATION ANNOTATIONS
================================================================================

INDEXES:
- PRIMARY KEY: rate_id
- CURRENCY: from_currency + to_currency + valid_from
- SOURCE: source + rate_type
- DATE: valid_from DESC

================================================================================
AUDIT AND LOGGING REQUIREMENTS
================================================================================

AUDIT EVENTS:
- RATE_CREATED
- RATE_EXPIRED
- RATE_ACCESSED

RETENTION: 7 years
================================================================================
*/

-- -----------------------------------------------------------------------------
-- CREATE TABLE: exchange_rates
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.exchange_rates (
    -- Primary identifier
    rate_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    rate_reference VARCHAR(100) UNIQUE NOT NULL,
    
    -- Currency pair
    from_currency VARCHAR(3) NOT NULL CHECK (from_currency ~ '^[A-Z]{3}$'),
    to_currency VARCHAR(3) NOT NULL CHECK (to_currency ~ '^[A-Z]{3}$'),
    
    -- Rate details
    rate_type VARCHAR(20) NOT NULL
        CHECK (rate_type IN ('SPOT', 'FORWARD', 'FIXING', 'INTERNAL', 'HISTORICAL')),
    rate_value NUMERIC(20, 10) NOT NULL CHECK (rate_value > 0),
    
    -- Inverse rate (for efficiency)
    inverse_rate NUMERIC(20, 10) GENERATED ALWAYS AS (1 / rate_value) STORED,
    
    -- Source
    source VARCHAR(100) NOT NULL,
    source_reference VARCHAR(255),
    source_timestamp TIMESTAMPTZ,
    
    -- Validity period
    valid_from TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    valid_to TIMESTAMPTZ,
    
    -- Rate metadata (FX specific)
    bid_rate NUMERIC(20, 10),
    ask_rate NUMERIC(20, 10),
    mid_rate NUMERIC(20, 10) GENERATED ALWAYS AS (
        CASE 
            WHEN bid_rate IS NOT NULL AND ask_rate IS NOT NULL THEN (bid_rate + ask_rate) / 2
            ELSE rate_value
        END
    ) STORED,
    spread_percentage NUMERIC(10, 6) GENERATED ALWAYS AS (
        CASE 
            WHEN bid_rate IS NOT NULL AND ask_rate IS NOT NULL AND bid_rate > 0 
            THEN ((ask_rate - bid_rate) / bid_rate) * 100
            ELSE NULL
        END
    ) STORED,
    
    -- Forward rate specific
    delivery_date DATE,
    
    -- Status
    is_current BOOLEAN DEFAULT TRUE,
    is_market_rate BOOLEAN DEFAULT TRUE,
    
    -- Usage tracking
    access_count INTEGER DEFAULT 0,
    last_accessed_at TIMESTAMPTZ,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    record_hash VARCHAR(64) NOT NULL DEFAULT 'PENDING',
    
    -- Constraints
    CONSTRAINT chk_different_currencies CHECK (from_currency != to_currency)
);

-- -----------------------------------------------------------------------------
-- INDEXES
-- -----------------------------------------------------------------------------
-- Currency pair lookups
CREATE INDEX IF NOT EXISTS idx_exchange_rates_currency_pair 
    ON core.exchange_rates(from_currency, to_currency, valid_from DESC);

-- Current rate lookups
CREATE INDEX IF NOT EXISTS idx_exchange_rates_current 
    ON core.exchange_rates(from_currency, to_currency, rate_type) 
    WHERE is_current = TRUE;

-- Rate type queries
CREATE INDEX IF NOT EXISTS idx_exchange_rates_type 
    ON core.exchange_rates(rate_type, created_at);

-- Source tracking
CREATE INDEX IF NOT EXISTS idx_exchange_rates_source 
    ON core.exchange_rates(source, created_at);

-- Validity period queries
CREATE INDEX IF NOT EXISTS idx_exchange_rates_validity 
    ON core.exchange_rates(valid_from, valid_to);

-- Expired rates for cleanup (use fixed date for index - application filters by NOW())
CREATE INDEX IF NOT EXISTS idx_exchange_rates_expired 
    ON core.exchange_rates(valid_to) 
    WHERE valid_to IS NOT NULL;

-- Forward rates
CREATE INDEX IF NOT EXISTS idx_exchange_rates_forward 
    ON core.exchange_rates(delivery_date, from_currency, to_currency) 
    WHERE rate_type = 'FORWARD';

-- -----------------------------------------------------------------------------
-- IMMUTABILITY TRIGGERS
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_exchange_rates_prevent_update ON core.exchange_rates;
CREATE TRIGGER trg_exchange_rates_prevent_update
    BEFORE UPDATE ON core.exchange_rates
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

DROP TRIGGER IF EXISTS trg_exchange_rates_prevent_delete ON core.exchange_rates;
CREATE TRIGGER trg_exchange_rates_prevent_delete
    BEFORE DELETE ON core.exchange_rates
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

-- -----------------------------------------------------------------------------
-- HASH COMPUTATION TRIGGER
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.compute_exchange_rate_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.record_hash := core.generate_hash(
        NEW.rate_id::TEXT || 
        NEW.rate_reference || 
        NEW.from_currency ||
        NEW.to_currency ||
        NEW.rate_type ||
        NEW.rate_value::TEXT ||
        NEW.source ||
        NEW.valid_from::TEXT ||
        NEW.created_at::TEXT
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_exchange_rates_compute_hash ON core.exchange_rates;
CREATE TRIGGER trg_exchange_rates_compute_hash
    BEFORE INSERT ON core.exchange_rates
    FOR EACH ROW
    EXECUTE FUNCTION core.compute_exchange_rate_hash();

-- -----------------------------------------------------------------------------
-- HELPER FUNCTIONS
-- -----------------------------------------------------------------------------

-- Function to create a new exchange rate
CREATE OR REPLACE FUNCTION core.create_exchange_rate(
    p_from_currency VARCHAR(3),
    p_to_currency VARCHAR(3),
    p_rate_type VARCHAR(20),
    p_rate_value NUMERIC,
    p_source VARCHAR(100),
    p_created_by UUID DEFAULT NULL,
    p_bid_rate NUMERIC DEFAULT NULL,
    p_ask_rate NUMERIC DEFAULT NULL,
    p_source_reference VARCHAR(255) DEFAULT NULL,
    p_delivery_date DATE DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_rate_id UUID;
    v_reference VARCHAR(100);
BEGIN
    -- Generate reference
    v_reference := 'FX-' || p_from_currency || p_to_currency || '-' || TO_CHAR(NOW(), 'YYYYMMDD-HH24MISS') || '-' || SUBSTRING(MD5(RANDOM()::TEXT), 1, 4);
    
    INSERT INTO core.exchange_rates (
        rate_reference,
        from_currency,
        to_currency,
        rate_type,
        rate_value,
        bid_rate,
        ask_rate,
        source,
        source_reference,
        delivery_date,
        created_by
    ) VALUES (
        v_reference,
        p_from_currency,
        p_to_currency,
        p_rate_type,
        p_rate_value,
        p_bid_rate,
        p_ask_rate,
        p_source,
        p_source_reference,
        p_delivery_date,
        p_created_by
    ) RETURNING rate_id INTO v_rate_id;
    
    RETURN v_rate_id;
END;
$$;

-- Function to get current exchange rate
CREATE OR REPLACE FUNCTION core.get_exchange_rate(
    p_from_currency VARCHAR(3),
    p_to_currency VARCHAR(3),
    p_rate_type VARCHAR(20) DEFAULT 'SPOT'
)
RETURNS TABLE (
    rate_value NUMERIC,
    inverse_rate NUMERIC,
    bid_rate NUMERIC,
    ask_rate NUMERIC,
    source VARCHAR(100),
    valid_from TIMESTAMPTZ
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Update access count
    UPDATE core.exchange_rates
    SET access_count = access_count + 1,
        last_accessed_at = NOW()
    WHERE from_currency = p_from_currency
      AND to_currency = p_to_currency
      AND rate_type = p_rate_type
      AND is_current = TRUE;
    
    RETURN QUERY
    SELECT 
        er.rate_value,
        er.inverse_rate,
        er.bid_rate,
        er.ask_rate,
        er.source,
        er.valid_from
    FROM core.exchange_rates er
    WHERE er.from_currency = p_from_currency
      AND er.to_currency = p_to_currency
      AND er.rate_type = p_rate_type
      AND er.is_current = TRUE
    ORDER BY er.valid_from DESC
    LIMIT 1;
END;
$$;

-- Function to convert amount using current rate
CREATE OR REPLACE FUNCTION core.convert_currency(
    p_amount NUMERIC,
    p_from_currency VARCHAR(3),
    p_to_currency VARCHAR(3),
    p_rate_type VARCHAR(20) DEFAULT 'SPOT'
)
RETURNS TABLE (
    converted_amount NUMERIC,
    rate_used NUMERIC,
    rate_source VARCHAR(100),
    rate_timestamp TIMESTAMPTZ
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rate RECORD;
BEGIN
    -- Same currency, no conversion needed
    IF p_from_currency = p_to_currency THEN
        RETURN QUERY SELECT p_amount, 1::NUMERIC, 'DIRECT'::VARCHAR(100), NOW()::TIMESTAMPTZ;
        RETURN;
    END IF;
    
    SELECT * INTO v_rate
    FROM core.get_exchange_rate(p_from_currency, p_to_currency, p_rate_type);
    
    IF NOT FOUND THEN
        -- Try inverse rate
        SELECT * INTO v_rate
        FROM core.get_exchange_rate(p_to_currency, p_from_currency, p_rate_type);
        
        IF FOUND THEN
            RETURN QUERY SELECT 
                ROUND(p_amount / v_rate.rate_value, 8),
                1 / v_rate.rate_value,
                v_rate.source,
                v_rate.valid_from;
        ELSE
            RAISE EXCEPTION 'Exchange rate not found for % to %', p_from_currency, p_to_currency;
        END IF;
    ELSE
        RETURN QUERY SELECT 
            ROUND(p_amount * v_rate.rate_value, 8),
            v_rate.rate_value,
            v_rate.source,
            v_rate.valid_from;
    END IF;
END;
$$;

-- Function to get rate history
CREATE OR REPLACE FUNCTION core.get_rate_history(
    p_from_currency VARCHAR(3),
    p_to_currency VARCHAR(3),
    p_start_date DATE,
    p_end_date DATE,
    p_rate_type VARCHAR(20) DEFAULT 'SPOT'
)
RETURNS TABLE (
    rate_date DATE,
    avg_rate NUMERIC,
    min_rate NUMERIC,
    max_rate NUMERIC,
    rate_count BIGINT
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        er.created_at::DATE as rate_date,
        AVG(er.rate_value)::NUMERIC as avg_rate,
        MIN(er.rate_value)::NUMERIC as min_rate,
        MAX(er.rate_value)::NUMERIC as max_rate,
        COUNT(*) as rate_count
    FROM core.exchange_rates er
    WHERE er.from_currency = p_from_currency
      AND er.to_currency = p_to_currency
      AND er.rate_type = p_rate_type
      AND er.created_at::DATE BETWEEN p_start_date AND p_end_date
    GROUP BY er.created_at::DATE
    ORDER BY rate_date;
END;
$$;

-- Function to expire old rates
CREATE OR REPLACE FUNCTION core.expire_old_rates(
    p_from_currency VARCHAR(3),
    p_to_currency VARCHAR(3),
    p_rate_type VARCHAR(20),
    p_valid_to TIMESTAMPTZ
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_expired_count INTEGER := 0;
BEGIN
    -- Note: Since table is immutable, we update the is_current flag by creating new records
    -- In practice, this would be handled by the rate loading process setting valid_to
    
    -- For this implementation, we just count what would be expired
    SELECT COUNT(*) INTO v_expired_count
    FROM core.exchange_rates
    WHERE from_currency = p_from_currency
      AND to_currency = p_to_currency
      AND rate_type = p_rate_type
      AND is_current = TRUE
      AND valid_from < p_valid_to;
    
    RETURN v_expired_count;
END;
$$;

-- Function to get exchange rate statistics
CREATE OR REPLACE FUNCTION core.get_exchange_rate_statistics(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS TABLE (
    from_currency VARCHAR(3),
    to_currency VARCHAR(3),
    rate_type VARCHAR(20),
    rate_count BIGINT,
    avg_rate NUMERIC,
    rate_volatility NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        er.from_currency,
        er.to_currency,
        er.rate_type,
        COUNT(*) as rate_count,
        AVG(er.rate_value)::NUMERIC as avg_rate,
        STDDEV(er.rate_value)::NUMERIC as rate_volatility
    FROM core.exchange_rates er
    WHERE (p_start_date IS NULL OR er.created_at::DATE >= p_start_date)
      AND (p_end_date IS NULL OR er.created_at::DATE <= p_end_date)
    GROUP BY er.from_currency, er.to_currency, er.rate_type
    ORDER BY rate_count DESC;
END;
$$;

-- -----------------------------------------------------------------------------
-- INITIAL DATA: Common currency pairs
-- -----------------------------------------------------------------------------
-- Note: These are placeholder rates for initialization only
-- Real rates should be loaded from authorized sources

INSERT INTO core.exchange_rates (
    rate_reference, from_currency, to_currency, rate_type, 
    rate_value, source, is_current, is_market_rate
) VALUES 
('FX-INIT-USD-EUR-001', 'USD', 'EUR', 'SPOT', 0.8500000000, 'INIT', TRUE, FALSE),
('FX-INIT-EUR-USD-001', 'EUR', 'USD', 'SPOT', 1.1764705882, 'INIT', TRUE, FALSE),
('FX-INIT-USD-GBP-001', 'USD', 'GBP', 'SPOT', 0.7300000000, 'INIT', TRUE, FALSE),
('FX-INIT-GBP-USD-001', 'GBP', 'USD', 'SPOT', 1.3698630137, 'INIT', TRUE, FALSE),
('FX-INIT-USD-JPY-001', 'USD', 'JPY', 'SPOT', 110.0000000000, 'INIT', TRUE, FALSE),
('FX-INIT-EUR-GBP-001', 'EUR', 'GBP', 'SPOT', 0.8588000000, 'INIT', TRUE, FALSE);

-- -----------------------------------------------------------------------------
-- COMMENTS
-- -----------------------------------------------------------------------------
COMMENT ON TABLE core.exchange_rates IS 'Historical and current exchange rates for multi-currency transactions';
COMMENT ON COLUMN core.exchange_rates.rate_id IS 'Unique identifier for the exchange rate';
COMMENT ON COLUMN core.exchange_rates.rate_type IS 'SPOT, FORWARD, FIXING, INTERNAL, or HISTORICAL';
COMMENT ON COLUMN core.exchange_rates.rate_value IS 'Exchange rate value (units of to_currency per 1 unit of from_currency)';
COMMENT ON COLUMN core.exchange_rates.is_current IS 'TRUE if this is the most current rate for the currency pair';

-- =============================================================================
-- END OF FILE
-- =============================================================================

COMMIT;
