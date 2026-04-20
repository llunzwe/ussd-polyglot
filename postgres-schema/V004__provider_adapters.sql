-- =============================================================================
-- Migration: V003__provider_adapters
-- Description: USSD Provider Adapters (Africa's Talking, Twilio, etc.)
-- Dependencies: V001, V002
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- PROVIDER ADAPTERS
-- =============================================================================

CREATE TABLE IF NOT EXISTS ussd.provider_adapters (
    adapter_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Provider identification
    provider_name VARCHAR(50) NOT NULL 
        CHECK (provider_name IN ('africas_talking', 'twilio', 'hubtel', 'route_mobile', 'ecocash', 'onemoney', 'telecash', 'custom')),
    provider_code VARCHAR(20) NOT NULL UNIQUE,
    provider_category VARCHAR(20) DEFAULT 'ussd_gateway' 
        CHECK (provider_category IN ('ussd_gateway', 'mobile_money', 'payment_processor')),
    
    -- Zimbabwe Mobile Money Provider Specific
    is_zimbabwe_mobile_money BOOLEAN DEFAULT FALSE,
    zimbabwe_mno VARCHAR(20) CHECK (zimbabwe_mno IN ('econet', 'netone', 'telecel')), -- Mobile Network Operator
    
    -- Adapter configuration
    api_base_url VARCHAR(255) NOT NULL,
    api_version VARCHAR(20) DEFAULT 'v1',
    
    -- Authentication (encrypted)
    api_key_encrypted TEXT NOT NULL,
    api_secret_encrypted TEXT,
    
    -- Webhook configuration
    webhook_url VARCHAR(255),
    webhook_secret_encrypted TEXT,
    
    -- Retry and circuit breaker
    max_retries INTEGER DEFAULT 3 CHECK (max_retries BETWEEN 0 AND 10),
    retry_delay_ms INTEGER DEFAULT 1000,
    circuit_breaker_threshold INTEGER DEFAULT 5,
    circuit_breaker_timeout_sec INTEGER DEFAULT 60,
    
    -- Provider-specific settings (NULL = not configured, must be set explicitly)
    provider_config JSONB,
    /*
    provider_config JSONB structure - Complete Business Kernel Configuration:
    
    AFRICA'S TALKING (USSD, SMS, WhatsApp):
    {
        "provider_type": "africas_talking",
        "environment": "sandbox|production",
        
        "credentials": {
            "username": "sandbox",
            "api_key_id": "key_reference",
            "api_key_encrypted": true
        },
        
        "ussd": {
            "enabled": true,
            "shortcode": "*384#",
            "session_timeout_seconds": 180,
            "supported_networks": ["safaricom", "airtel_kenya", "mtn", "orange"],
            "callback_format": "form-urlencoded",
            "callback_url": "https://api.example.com/webhooks/at/ussd",
            "welcome_message": "Welcome to Our Service",
            "exit_message": "Thank you for using our service"
        },
        
        "sms": {
            "enabled": true,
            "shortcode": "12345",
            "sender_id": "MyBusiness",
            "default_sender_id": "AFRICASTKNG",
            "bulk_sms_enabled": true,
            "two_way_sms_enabled": true,
            "callback_url": "https://api.example.com/webhooks/at/sms",
            "delivery_reports_enabled": true,
            "rate_limit_per_minute": 100,
            "rate_limit_per_hour": 1000,
            "supported_features": ["bulk", "premium", "subscription"]
        },
        
        "whatsapp": {
            "enabled": true,
            "whatsapp_business_id": "waba_123456",
            "phone_number_id": "phonenumber_123456",
            "phone_number": "+254711XXXYYY",
            "messaging_enabled": true,
            "templates_enabled": true,
            "callback_url": "https://api.example.com/webhooks/at/whatsapp",
            "webhook_verification_token": "verify_token_here",
            "session_timeout_hours": 24
        },
        
        "endpoints": {
            "base_url": "https://api.africastalking.com",
            "ussd_callback": "/ussd/callback",
            "sms_send": "/version1/messaging",
            "sms_bulk": "/version1/messaging/bulk",
            "sms_subscription": "/version1/subscription",
            "voice_calls": "/version1/call",
            "airtime_send": "/version1/airtime/send",
            "mobile_money": "/version1/mobile/b2c",
            "whatsapp_send": "/whatsapp/messaging"
        },
        
        "webhooks": {
            "secret": "webhook_signing_secret",
            "ip_whitelist": ["52.XXX.XXX.XXX", "54.XXX.XXX.XXX"]
        },
        
        "features": {
            "ussd_push": true,
            "sms_two_way": true,
            "whatsapp_business": true,
            "voice_ivr": false,
            "airtime": false,
            "mobile_money_b2c": false
        }
    }
    
    Mobile Money (ecocash, onemoney, telecash) - PAYMENTS ONLY:
    {
        "provider_type": "mobile_money",
        "api_version": "v2.0",
        "merchant_code": "123456",           -- 6-digit business merchant code
        "merchant_name": "Business Ltd",
        "authentication": {
            "auth_method": "api_key+rsa",    -- ecocash: api_key+rsa
            "api_key_id": "key_id_here",     -- onemoney: api_key+hmac
            "rsa_public_key": "...",         -- telecash: oauth2
            "ip_whitelist": ["196.44.x.x"]
        },
        "endpoints": {
            "base_url": "https://api.ecocash.co.zw/v2",
            "payment": "/payments/merchant",   -- Receive payments (C2B)
            "payout": "/payments/payout",      -- Send payouts (B2C) 
            "refund": "/payments/refund",
            "balance": "/account/balance",
            "transaction_status": "/transactions/status"
        },
        "webhooks": {
            "endpoint": "https://api.example.com/webhooks/mm",
            "secret": "webhook_signing_secret",
            "events": ["payment_received", "payout_completed", "refund_processed"]
        },
        "supported_currencies": ["ZWL", "USD"],
        "transaction_limits": {
            "min_amount": 1.00,
            "max_amount": 10000.00,
            "daily_limit": 50000.00
        },
        "settlement": {
            "bank_account": "1234567890",
            "settlement_frequency": "daily",
            "settlement_time": "06:00"
        },
        "note": "Business merchant API - payments and payouts only. Not an agent system."
    }
    */
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    is_default BOOLEAN DEFAULT FALSE,
    
    -- Environment
    environment VARCHAR(20) DEFAULT 'production' 
        CHECK (environment IN ('sandbox', 'production')),
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT chk_valid_webhook_url CHECK (webhook_url IS NULL OR webhook_url ~ '^https?://')
);

-- Only one default adapter per environment
CREATE UNIQUE INDEX IF NOT EXISTS idx_provider_adapters_default 
    ON ussd.provider_adapters(environment) 
    WHERE is_default = TRUE;

-- Lookup by provider code
CREATE INDEX IF NOT EXISTS idx_provider_adapters_code 
    ON ussd.provider_adapters(provider_code) 
    WHERE is_active = TRUE;

COMMENT ON TABLE ussd.provider_adapters IS 
'ADR-002: JSONB for Provider Configuration

DECISION: Use JSONB provider_config instead of separate columns

RATIONALE:
- Different providers have different configuration needs
- Africa''s Talking needs: ussd, sms, whatsapp config
- Mobile money needs: merchant_code, auth methods, endpoints
- Avoids schema changes when providers add features

TRADE-OFFS:
- (+) Flexibility, extensibility
- (+) Single table for all providers
- (-) Less type safety
- (-) Query complexity for nested fields

VALIDATION:
- Application-layer schema validation required
- Document structure enforced in provider_config JSONB comments';

-- =============================================================================
-- PROVIDER WEBHOOK LOG
-- =============================================================================

CREATE TABLE IF NOT EXISTS ussd.provider_webhook_log (
    log_id UUID DEFAULT gen_random_uuid(),
    
    -- Request tracking
    adapter_id UUID NOT NULL REFERENCES ussd.provider_adapters(adapter_id),
    session_id UUID,
    
    -- Request details
    request_method VARCHAR(10) NOT NULL,
    request_path TEXT NOT NULL,
    request_headers JSONB,
    request_body JSONB,
    
    -- Response details
    response_status INTEGER,
    response_body JSONB,
    response_time_ms INTEGER,
    
    -- Processing result
    is_success BOOLEAN DEFAULT FALSE,
    error_message TEXT,
    
    -- Idempotency
    idempotency_key VARCHAR(255),
    
    -- Timestamp
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Partition key
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT pk_ussd_provider_webhook_log_log_id_created_at PRIMARY KEY (log_id, created_at));

-- Convert to hypertable for time-series data
SELECT create_hypertable(
    'ussd.provider_webhook_log',
    'created_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_webhook_log_adapter 
    ON ussd.provider_webhook_log(adapter_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_webhook_log_session 
    ON ussd.provider_webhook_log(session_id) 
    WHERE session_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_webhook_log_idempotency 
    ON ussd.provider_webhook_log(idempotency_key) 
    WHERE idempotency_key IS NOT NULL;

COMMENT ON TABLE ussd.provider_webhook_log IS 'Webhook request/response log for provider integrations';

-- =============================================================================
-- DEAD LETTER QUEUE
-- =============================================================================

CREATE TABLE IF NOT EXISTS ussd.webhook_dead_letter_queue (
    dlq_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Original request reference
    adapter_id UUID NOT NULL REFERENCES ussd.provider_adapters(adapter_id),
    original_log_id UUID,
    
    -- Request details
    request_payload JSONB NOT NULL,
    request_headers JSONB,
    
    -- Failure tracking
    failure_reason TEXT NOT NULL,
    failure_count INTEGER DEFAULT 1,
    last_failure_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Retry scheduling
    next_retry_at TIMESTAMPTZ,
    max_retries INTEGER DEFAULT 5,
    
    -- Resolution
    is_resolved BOOLEAN DEFAULT FALSE,
    resolved_at TIMESTAMPTZ,
    resolution_action VARCHAR(50), -- 'retry_succeeded', 'manual_resolved', 'discarded'
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_dlq_pending 
    ON ussd.webhook_dead_letter_queue(next_retry_at) 
    WHERE is_resolved = FALSE AND failure_count < max_retries;

CREATE INDEX IF NOT EXISTS idx_dlq_adapter 
    ON ussd.webhook_dead_letter_queue(adapter_id, created_at DESC);

COMMENT ON TABLE ussd.webhook_dead_letter_queue IS 'Failed webhook requests for retry or manual resolution';

-- =============================================================================
-- BATCH PROCESSING QUEUE
-- =============================================================================

CREATE TABLE IF NOT EXISTS ussd.batch_ussd_queue (
    batch_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Batch configuration
    adapter_id UUID NOT NULL REFERENCES ussd.provider_adapters(adapter_id),
    application_id UUID NOT NULL,
    
    -- Batch content
    session_requests JSONB NOT NULL, -- Array of session init requests
    total_count INTEGER NOT NULL,
    
    -- Processing status
    status VARCHAR(20) DEFAULT 'pending' 
        CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'partial')),
    processed_count INTEGER DEFAULT 0,
    success_count INTEGER DEFAULT 0,
    failure_count INTEGER DEFAULT 0,
    
    -- Results
    results JSONB DEFAULT '[]',
    
    -- Scheduling
    scheduled_at TIMESTAMPTZ,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_batch_queue_status 
    ON ussd.batch_ussd_queue(status, scheduled_at) 
    WHERE status IN ('pending', 'processing');

COMMENT ON TABLE ussd.batch_ussd_queue IS 'Batch USSD request processing queue';

-- =============================================================================
-- AUDIT TRIGGERS (Not WORM - these tables need to be mutable for operations)
-- =============================================================================

-- Audit trigger for provider configuration changes
CREATE OR REPLACE FUNCTION ussd.audit_provider_adapter_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM core.log_audit_event(
        'DATA_CHANGE'::VARCHAR(50),
        'INFO'::VARCHAR(20),
        'PROVIDER_ADAPTER_UPDATED'::VARCHAR(100),
        'UPDATE'::VARCHAR(50),
        'SUCCESS'::VARCHAR(20),
        NULL::UUID,
        'SYSTEM'::VARCHAR(50),
        'ussd'::VARCHAR(50),
        'provider_adapters'::VARCHAR(100),
        NEW.adapter_id::TEXT,
        jsonb_build_object('old_is_active', OLD.is_active, 'new_is_active', NEW.is_active,
                           'old_config', OLD.provider_config, 'new_config', NEW.provider_config),
        jsonb_build_object('updated_at', NEW.updated_at)
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_provider_adapters_audit ON ussd.provider_adapters;
CREATE TRIGGER trg_provider_adapters_audit
    AFTER UPDATE ON ussd.provider_adapters
    FOR EACH ROW
    EXECUTE FUNCTION ussd.audit_provider_adapter_change();

-- WORM for webhook logs (immutable audit trail)
CREATE TRIGGER trg_provider_webhook_log_prevent_update
    BEFORE UPDATE ON ussd.provider_webhook_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_provider_webhook_log_prevent_delete
    BEFORE DELETE ON ussd.provider_webhook_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

CREATE TRIGGER trg_provider_webhook_log_prevent_truncate
    BEFORE TRUNCATE ON ussd.provider_webhook_log
    FOR EACH STATEMENT
    EXECUTE FUNCTION core.prevent_truncate();

-- WORM for DLQ (immutable failure records)
CREATE TRIGGER trg_webhook_dlq_prevent_update
    BEFORE UPDATE ON ussd.webhook_dead_letter_queue
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_webhook_dlq_prevent_delete
    BEFORE DELETE ON ussd.webhook_dead_letter_queue
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

CREATE TRIGGER trg_webhook_dlq_prevent_truncate
    BEFORE TRUNCATE ON ussd.webhook_dead_letter_queue
    FOR EACH STATEMENT
    EXECUTE FUNCTION core.prevent_truncate();

-- Batch queue needs updates for status changes - audit only
CREATE OR REPLACE FUNCTION ussd.audit_batch_queue_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status != NEW.status THEN
        PERFORM core.log_audit_event(
            'DATA_CHANGE'::VARCHAR(50),
            'INFO'::VARCHAR(20),
            'BATCH_QUEUE_STATUS_CHANGE'::VARCHAR(100),
            'UPDATE'::VARCHAR(50),
            'SUCCESS'::VARCHAR(20),
            NULL::UUID,
            'SYSTEM'::VARCHAR(50),
            'ussd'::VARCHAR(50),
            'batch_ussd_queue'::VARCHAR(100),
            NEW.batch_id::TEXT,
            jsonb_build_object('old_status', OLD.status, 'new_status', NEW.status),
            jsonb_build_object('processed', NEW.processed_count, 'success', NEW.success_count)
        );
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_batch_queue_audit ON ussd.batch_ussd_queue;
CREATE TRIGGER trg_batch_queue_audit
    AFTER UPDATE ON ussd.batch_ussd_queue
    FOR EACH ROW
    EXECUTE FUNCTION ussd.audit_batch_queue_change();

COMMIT;
