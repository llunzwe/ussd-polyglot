-- V074: P0 Fixes — Missing tables, temporal schema, outbox enhancements
-- Date: 2026-04-17
-- Description: Addresses critical schema gaps identified during production audit.

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. mobile_money schema — provider callbacks and payment attempts
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS mobile_money.provider_callbacks (
    callback_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    provider_name       VARCHAR(50) NOT NULL,
    transaction_reference VARCHAR(100) NOT NULL,
    payload             JSONB NOT NULL,
    received_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at        TIMESTAMPTZ,
    status              VARCHAR(20) NOT NULL DEFAULT 'pending',
    CONSTRAINT chk_provider_callbacks_status CHECK (status IN ('pending', 'processed', 'failed'))
);

CREATE INDEX IF NOT EXISTS idx_provider_callbacks_ref ON mobile_money.provider_callbacks(transaction_reference);
CREATE INDEX IF NOT EXISTS idx_provider_callbacks_status ON mobile_money.provider_callbacks(status) WHERE status = 'pending';

CREATE TABLE IF NOT EXISTS mobile_money.payment_attempts (
    attempt_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    payment_id          UUID NOT NULL,
    provider_name       VARCHAR(50) NOT NULL,
    request_payload     JSONB NOT NULL,
    response_payload    JSONB,
    status              VARCHAR(20) NOT NULL,
    attempted_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at        TIMESTAMPTZ,
    CONSTRAINT chk_payment_attempts_status CHECK (status IN ('pending', 'success', 'failed', 'timeout'))
);

CREATE INDEX IF NOT EXISTS idx_payment_attempts_payment ON mobile_money.payment_attempts(payment_id);
CREATE INDEX IF NOT EXISTS idx_payment_attempts_status ON mobile_money.payment_attempts(status);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. temporal schema — Saga engine tables
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS temporal.saga_instances (
    saga_id             UUID PRIMARY KEY,
    tenant_id           UUID NOT NULL,
    status              VARCHAR(20) NOT NULL,
    current_step        INTEGER NOT NULL DEFAULT 0,
    total_steps         INTEGER NOT NULL,
    payload             JSONB,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at        TIMESTAMPTZ,
    CONSTRAINT chk_saga_status CHECK (status IN ('pending', 'running', 'completed', 'failed', 'compensating', 'compensated'))
);

CREATE INDEX IF NOT EXISTS idx_saga_instances_tenant ON temporal.saga_instances(tenant_id, status);
CREATE INDEX IF NOT EXISTS idx_saga_instances_status ON temporal.saga_instances(status) WHERE status IN ('pending', 'running', 'compensating');

CREATE TABLE IF NOT EXISTS temporal.saga_steps (
    step_id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    saga_id             UUID NOT NULL REFERENCES temporal.saga_instances(saga_id) ON DELETE CASCADE,
    step_number         INTEGER NOT NULL,
    service_name        VARCHAR(100) NOT NULL,
    action              VARCHAR(100) NOT NULL,
    status              VARCHAR(20) NOT NULL,
    input_payload       JSONB,
    output_payload      JSONB,
    error_message       TEXT,
    compensation_action VARCHAR(100),
    executed_at         TIMESTAMPTZ,
    compensated_at      TIMESTAMPTZ,
    CONSTRAINT chk_saga_step_status CHECK (status IN ('pending', 'executing', 'completed', 'failed', 'compensating', 'compensated'))
);

CREATE INDEX IF NOT EXISTS idx_saga_steps_saga ON temporal.saga_steps(saga_id, step_number);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. events.cdc_outbox enhancements
-- ═══════════════════════════════════════════════════════════════════════════════

-- Ensure tenant_id column exists (idempotent)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'events' AND table_name = 'cdc_outbox' AND column_name = 'tenant_id'
    ) THEN
        ALTER TABLE events.cdc_outbox ADD COLUMN tenant_id UUID;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'events' AND table_name = 'cdc_outbox' AND column_name = 'processed_at'
    ) THEN
        ALTER TABLE events.cdc_outbox ADD COLUMN processed_at TIMESTAMPTZ;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'events' AND table_name = 'cdc_outbox' AND column_name = 'processor_id'
    ) THEN
        ALTER TABLE events.cdc_outbox ADD COLUMN processor_id VARCHAR(100);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'events' AND table_name = 'cdc_outbox' AND column_name = 'retry_count'
    ) THEN
        ALTER TABLE events.cdc_outbox ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0;
    END IF;
END $$;

-- Idempotent index for polling unprocessed events
CREATE INDEX IF NOT EXISTS idx_cdc_outbox_unprocessed ON events.cdc_outbox(processed_at, retry_count)
    WHERE processed_at IS NULL AND retry_count < 10;

COMMENT ON TABLE events.cdc_outbox IS 'Outbox pattern table for cross-service event propagation. Populated by Rust payment-engine; consumed by Go orchestrator poller. Single-writer principle preserved.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. ops schema — integrity check schedules (owner: audit service)
-- ═══════════════════════════════════════════════════════════════════════════════

-- Ensure ops.integrity_check_schedules is properly documented
COMMENT ON TABLE ops.integrity_check_schedules IS 'Owned by Rust audit-service. Stores daily/periodic Merkle root computation schedules.';

-- Add status constraint if not already present
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_schema = 'ops' AND table_name = 'integrity_check_schedules'
        AND constraint_name = 'chk_integrity_schedule_status'
    ) THEN
        ALTER TABLE ops.integrity_check_schedules
        ADD CONSTRAINT chk_integrity_schedule_status CHECK (status IN ('active', 'paused', 'disabled'));
    END IF;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. sdk schema — query patterns (owner: ledger-query-service)
-- ═══════════════════════════════════════════════════════════════════════════════

COMMENT ON TABLE sdk.query_patterns IS 'Owned by Rust ledger-query-service. Pre-defined analytical query templates for tenant dashboards.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. app.api_keys — ensure rate_limit_tier and permissions exist
-- ═══════════════════════════════════════════════════════════════════════════════

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'app' AND table_name = 'api_keys' AND column_name = 'rate_limit_tier'
    ) THEN
        ALTER TABLE app.api_keys ADD COLUMN rate_limit_tier VARCHAR(20) NOT NULL DEFAULT 'standard';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'app' AND table_name = 'api_keys' AND column_name = 'permissions'
    ) THEN
        ALTER TABLE app.api_keys ADD COLUMN permissions TEXT[] NOT NULL DEFAULT ARRAY['read'];
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'app' AND table_name = 'api_keys' AND column_name = 'api_key_hash'
    ) THEN
        ALTER TABLE app.api_keys ADD COLUMN api_key_hash VARCHAR(64);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_api_keys_hash ON app.api_keys(api_key_hash);
    END IF;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 7. app.application_registry — ensure phone_regex in configuration
-- ═══════════════════════════════════════════════════════════════════════════════

COMMENT ON COLUMN app.application_registry.configuration IS 'JSONB containing tenant-specific config. Expected keys: phone_regex (default ^2637[1378]\\d{8}$), currency_code, timezone.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 8. app.api_request_log — request logging table
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS app.api_request_log (
    log_id              BIGSERIAL PRIMARY KEY,
    tenant_id           UUID,
    api_key_id          UUID REFERENCES app.api_keys(api_key_id),
    request_id          UUID DEFAULT gen_random_uuid(),
    method              VARCHAR(10) NOT NULL,
    path                TEXT NOT NULL,
    query_params        TEXT,
    status_code         INTEGER,
    response_time_ms    INTEGER,
    client_ip           INET,
    user_agent          TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_api_request_log_tenant ON app.api_request_log(tenant_id, created_at);
CREATE INDEX IF NOT EXISTS idx_api_request_log_time ON app.api_request_log(created_at DESC);

SELECT migrate_execution('V074__p0_fixes.sql', '2026-04-17 00:00:00+00');
