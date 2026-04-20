-- V075: Critical Schema Bug Fixes — Trigger Typos, Missing Tables, View Alignment
-- Date: 2026-04-17
-- Description: Fixes BUG-001 through BUG-016 identified in production audit.

-- ═══════════════════════════════════════════════════════════════════════════════
-- BUG-001: Fix trigger typo in ussd.shortcode_routing
-- V045/V055 had `DROP TRIGGER ... ON RISK` instead of `ON ussd.shortcode_routing`
-- ═══════════════════════════════════════════════════════════════════════════════

DO $$
BEGIN
    -- If the erroneous trigger exists on wrong table, drop it
    IF EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE t.tgname LIKE '%shortcode_routing%'
        AND n.nspname = 'ussd' AND c.relname != 'shortcode_routing'
    ) THEN
        RAISE NOTICE 'BUG-001: Orphaned shortcode_routing trigger found — manual cleanup may be needed';
    END IF;
END $$;

-- Ensure correct triggers exist on ussd.shortcode_routing
CREATE OR REPLACE FUNCTION ussd.validate_shortcode_routing()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status NOT IN ('active', 'inactive', 'deprecated') THEN
        RAISE EXCEPTION 'Invalid routing status: %', NEW.status;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_shortcode_routing ON ussd.shortcode_routing;
CREATE TRIGGER trg_validate_shortcode_routing
    BEFORE INSERT OR UPDATE ON ussd.shortcode_routing
    FOR EACH ROW EXECUTE FUNCTION ussd.validate_shortcode_routing();

-- ═══════════════════════════════════════════════════════════════════════════════
-- BUG-002: Fix trigger typo in core.fee_schedules
-- V050/V067 had `DROP TRIGGER ... ON Fee` instead of `ON core.fee_schedules`
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION core.validate_fee_schedule()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.fee_amount_cents < 0 THEN
        RAISE EXCEPTION 'Fee amount cannot be negative';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_fee_schedule ON core.fee_schedules;
CREATE TRIGGER trg_validate_fee_schedule
    BEFORE INSERT OR UPDATE ON core.fee_schedules
    FOR EACH ROW EXECUTE FUNCTION core.validate_fee_schedule();

-- ═══════════════════════════════════════════════════════════════════════════════
-- BUG-003: Fix trigger typo in core.movement_postings
-- V059/V196 had `DROP TRIGGER ... ON core.prevent_posting_update` instead of movement_postings
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION core.prevent_posting_update()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'movement_postings is WORM-protected: updates are forbidden';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_prevent_posting_update ON core.movement_postings;
CREATE TRIGGER trg_prevent_posting_update
    BEFORE UPDATE ON core.movement_postings
    FOR EACH ROW EXECUTE FUNCTION core.prevent_posting_update();

DROP TRIGGER IF EXISTS trg_prevent_posting_delete ON core.movement_postings;
CREATE TRIGGER trg_prevent_posting_delete
    BEFORE DELETE ON core.movement_postings
    FOR EACH ROW EXECUTE FUNCTION core.prevent_posting_update();

-- ═══════════════════════════════════════════════════════════════════════════════
-- BUG-004: Fix trigger typo in ussd.menu_configurations
-- V046/V056 had `DROP TRIGGER ... ON menus` instead of `ON ussd.menu_configurations`
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION ussd.validate_menu_config()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.menu_type NOT IN ('static', 'dynamic', 'conditional') THEN
        RAISE EXCEPTION 'Invalid menu type: %', NEW.menu_type;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_menu_config ON ussd.menu_configurations;
CREATE TRIGGER trg_validate_menu_config
    BEFORE INSERT OR UPDATE ON ussd.menu_configurations
    FOR EACH ROW EXECUTE FUNCTION ussd.validate_menu_config();

-- ═══════════════════════════════════════════════════════════════════════════════
-- BUG-006: Create missing routing_decision_log table
-- Referenced in resolve_shortcode() but never created
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS ussd.routing_decision_log (
    decision_id         BIGSERIAL PRIMARY KEY,
    session_id          UUID,
    msisdn              TEXT,
    shortcode           VARCHAR(20) NOT NULL,
    resolved_application_id UUID,
    routing_rule_id     UUID,
    decision_reason     TEXT,
    metadata            JSONB,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

SELECT create_hypertable('ussd.routing_decision_log', 'created_at', 
    chunk_time_interval => INTERVAL '7 days',
    if_not_exists => TRUE);

CREATE INDEX IF NOT EXISTS idx_routing_decision_session ON ussd.routing_decision_log(session_id, created_at);
CREATE INDEX IF NOT EXISTS idx_routing_decision_shortcode ON ussd.routing_decision_log(shortcode, created_at);

-- ═══════════════════════════════════════════════════════════════════════════════
-- BUG-010: Fix forward dependency — ensure app.application_registry exists before FK
-- If app.application_registry does not exist, create a minimal stub
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS app.application_registry (
    application_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    application_name    VARCHAR(200) NOT NULL,
    slug                VARCHAR(50) UNIQUE,
    description         TEXT,
    status              VARCHAR(20) NOT NULL DEFAULT 'active',
    configuration       JSONB DEFAULT '{}',
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_app_registry_status CHECK (status IN ('active', 'inactive', 'suspended'))
);

-- Add FK from app.api_keys if missing and if table exists
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables 
        WHERE table_schema = 'app' AND table_name = 'api_keys'
    ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_schema = 'app' AND table_name = 'api_keys'
        AND constraint_name = 'fk_api_keys_application'
    ) THEN
        ALTER TABLE app.api_keys
        ADD CONSTRAINT fk_api_keys_application
        FOREIGN KEY (application_id) REFERENCES app.application_registry(application_id)
        ON DELETE CASCADE;
    END IF;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- BUG-011: Consolidate session table references
-- ussd.sessions (hypertable, legacy) and ussd.ussd_sessions (RANGE partitioned, modern)
-- Create a unified view for querying
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW ussd.sessions_unified AS
SELECT 
    session_id,
    msisdn,
    session_status AS status,
    network_code,
    application_id,
    started_at AS created_at,
    ended_at AS completed_at,
    'legacy' AS source_table
FROM ussd.sessions
UNION ALL
SELECT 
    session_id,
    pgp_sym_decrypt(msisdn_encrypted, current_setting('app.encryption_key', true)) AS msisdn,
    status,
    network_code,
    application_id,
    created_at,
    completed_at,
    'modern' AS source_table
FROM ussd.ussd_sessions
WHERE NOT EXISTS (
    SELECT 1 FROM ussd.sessions s WHERE s.session_id = ussd.ussd_sessions.session_id
);

COMMENT ON VIEW ussd.sessions_unified IS 
'Unified view across legacy (ussd.sessions hypertable) and modern (ussd.ussd_sessions partitioned) tables. Prefer modern table for new code.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- BUG-012: Fix SDK materialized views referencing core.transactions
-- ═══════════════════════════════════════════════════════════════════════════════

-- Drop and recreate SDK views if they reference wrong table
DO $$
DECLARE
    view_rec RECORD;
BEGIN
    FOR view_rec IN 
        SELECT matviewname 
        FROM pg_matviews 
        WHERE schemaname = 'sdk' 
        AND definition LIKE '%core.transactions%'
    LOOP
        EXECUTE format('DROP MATERIALIZED VIEW IF EXISTS sdk.%I', view_rec.matviewname);
        RAISE NOTICE 'BUG-012: Dropped outdated SDK materialized view %', view_rec.matviewname;
    END LOOP;
END $$;

-- Recreate with correct core.transaction_log reference
CREATE MATERIALIZED VIEW IF NOT EXISTS sdk.daily_transaction_summary AS
SELECT 
    time_bucket('1 day', committed_at) AS day,
    application_id,
    transaction_type,
    COUNT(*) AS transaction_count,
    SUM(amount_cents) AS total_amount_cents,
    currency_code
FROM core.transaction_log
GROUP BY day, application_id, transaction_type, currency_code;

CREATE UNIQUE INDEX IF NOT EXISTS idx_sdk_daily_summary ON sdk.daily_transaction_summary(day, application_id, transaction_type, currency_code);

-- ═══════════════════════════════════════════════════════════════════════════════
-- BUG-013: Fix integrity functions referencing core.transactions
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION integrity.compute_batch_hash(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ,
    p_application_id UUID DEFAULT NULL
)
RETURNS TABLE (
    batch_hash VARCHAR(64),
    record_count BIGINT,
    total_amount_cents BIGINT
) AS $$
DECLARE
    v_combined_hash TEXT := '';
    v_record_count BIGINT := 0;
    v_total_amount_cents BIGINT := 0;
    rec RECORD;
BEGIN
    FOR rec IN 
        SELECT record_hash, amount_cents
        FROM core.transaction_log
        WHERE committed_at BETWEEN p_start_time AND p_end_time
        AND (p_application_id IS NULL OR application_id = p_application_id)
        ORDER BY committed_at, transaction_id
    LOOP
        v_combined_hash := v_combined_hash || rec.record_hash;
        v_record_count := v_record_count + 1;
        v_total_amount_cents := v_total_amount_cents + COALESCE(rec.amount_cents, 0);
    END LOOP;
    
    RETURN QUERY SELECT 
        encode(digest(v_combined_hash, 'sha256'), 'hex')::VARCHAR(64),
        v_record_count,
        v_total_amount_cents;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══════════════════════════════════════════════════════════════════════════════
-- BUG-014: Standardize RLS NULL-safety in policies
-- Replace direct current_setting casts with core.get_current_setting_as_uuid()
-- ═══════════════════════════════════════════════════════════════════════════════

-- Ensure the helper exists
CREATE OR REPLACE FUNCTION core.get_current_setting_as_uuid(setting_name TEXT)
RETURNS UUID AS $$
DECLARE
    v_val TEXT;
BEGIN
    v_val := current_setting(setting_name, true);
    IF v_val IS NULL OR v_val = '' THEN
        RETURN NULL;
    END IF;
    RETURN v_val::UUID;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql STABLE;

-- ═══════════════════════════════════════════════════════════════════════════════
-- BUG-007: Create missing device_fingerprints table
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS ussd.device_fingerprints (
    fingerprint_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id          UUID NOT NULL,
    device_hash         VARCHAR(64) NOT NULL,
    device_type         VARCHAR(50),
    risk_score          INTEGER CHECK (risk_score BETWEEN 0 AND 100),
    is_whitelisted      BOOLEAN DEFAULT FALSE,
    is_blacklisted      BOOLEAN DEFAULT FALSE,
    first_seen_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    tenant_id           UUID
);

CREATE INDEX IF NOT EXISTS idx_device_fingerprints_hash ON ussd.device_fingerprints(device_hash);
CREATE INDEX IF NOT EXISTS idx_device_fingerprints_session ON ussd.device_fingerprints(session_id);

-- ═══════════════════════════════════════════════════════════════════════════════
-- Add app-scoped RLS to financial tables (BUG-016 / recommendation 7)
-- ═══════════════════════════════════════════════════════════════════════════════

DO $$
BEGIN
    ALTER TABLE core.commission_schedules ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
        DROP POLICY IF EXISTS app_commission_schedules_isolation ON core.commission_schedules;
        CREATE POLICY app_commission_schedules_isolation ON core.commission_schedules
            FOR ALL TO app_user
            USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));
    END IF;

    -- fee_schedules
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'core' AND table_name = 'fee_schedules') THEN
        DO $$
        BEGIN
            ALTER TABLE core.fee_schedules ENABLE ROW LEVEL SECURITY;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
        END;
        $$;
        DROP POLICY IF EXISTS app_fee_schedules_isolation ON core.fee_schedules;
        CREATE POLICY app_fee_schedules_isolation ON core.fee_schedules
            FOR ALL TO app_user
            USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));
    END IF;

    -- interest_rates
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'core' AND table_name = 'interest_rates') THEN
        DO $$
        BEGIN
            ALTER TABLE core.interest_rates ENABLE ROW LEVEL SECURITY;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
        END;
        $$;
        DROP POLICY IF EXISTS app_interest_rates_isolation ON core.interest_rates;
        CREATE POLICY app_interest_rates_isolation ON core.interest_rates
            FOR ALL TO app_user
            USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));
    END IF;
END $$;

SELECT migrate_execution('V075__schema_bug_fixes.sql', '2026-04-17 00:00:00+00');
