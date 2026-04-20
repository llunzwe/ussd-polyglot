-- =============================================================================
-- Migration: V063__messaging_sms_schema
-- Description: SMS Messaging Schema for Africa's Talking Integration
-- Dependencies: V001-V062
-- =============================================================================
-- PURPOSE: Complete SMS messaging system for business applications using
--          Africa's Talking SMS API. Supports transactional SMS, bulk campaigns,
--          delivery tracking, and two-way messaging.
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- SCHEMA: messaging
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS messaging;
COMMENT ON SCHEMA messaging IS 
'ADR-003: Separate Tables for SMS vs WhatsApp

DECISION: Separate tables (sms_messages, whatsapp_messages) vs unified

RATIONALE:
- Different API models (SMS fire-and-forget vs WhatsApp session-based)
- Different pricing models (per SMS vs conversation-based)
- Different compliance requirements (WhatsApp 24h rule)
- Different template systems

TRADE-OFFS:
- (+) Clean separation of concerns
- (+) Optimized indexes per channel
- (+) Different retention policies
- (-) More tables to maintain
- (-) Cross-channel analytics require UNION queries';

-- =============================================================================
-- TABLE: sms_messages
-- DESCRIPTION: All SMS messages (outbound and inbound)
-- =============================================================================
CREATE TABLE IF NOT EXISTS messaging.sms_messages (
    message_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Message classification
    message_type VARCHAR(20) NOT NULL DEFAULT 'outbound'
        CHECK (message_type IN ('outbound', 'inbound', 'bulk', 'scheduled')),
    
    -- Business context
    application_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    account_id UUID REFERENCES core.account_registry(account_id),
    
    -- Sender information
    sender_id VARCHAR(50) NOT NULL, -- Africa's Talking sender ID or shortcode
    sender_name VARCHAR(100), -- Display name
    
    -- Recipient information
    recipient_msisdn VARCHAR(20) NOT NULL,
    recipient_msisdn_hash VARCHAR(64), -- For privacy lookups
    
    -- Message content
    message_text TEXT NOT NULL,
    message_text_encrypted BYTEA, -- For sensitive content
    
    -- Character encoding and segmentation
    encoding VARCHAR(20) DEFAULT 'GSM-7' 
        CHECK (encoding IN ('GSM-7', 'UCS-2')),
    segment_count INTEGER DEFAULT 1, -- Number of SMS parts
    character_count INTEGER, -- Total characters
    
    -- Template reference (for registered templates)
    template_id UUID,
    template_variables JSONB, -- Variables substituted in template
    
    -- Africa's Talking specific
    at_message_id VARCHAR(100), -- AT's message ID
    at_batch_id VARCHAR(100), -- For bulk sends
    at_queue_name VARCHAR(50), -- AT queue used
    
    -- Status tracking
    status VARCHAR(30) DEFAULT 'pending'
        CHECK (status IN (
            'pending',      -- Waiting to be sent
            'queued',       -- Queued at AT
            'sent',         -- Sent to operator
            'delivered',    -- Delivered to recipient
            'failed',       -- Failed to send
            'rejected',     -- Rejected by operator
            'expired',      -- Message expired
            'received'      -- Inbound message received
        )),
    
    -- Delivery tracking
    sent_at TIMESTAMPTZ,
    delivered_at TIMESTAMPTZ,
    failed_at TIMESTAMPTZ,
    
    -- Failure details
    failure_reason TEXT,
    failure_code VARCHAR(50),
    retry_count INTEGER DEFAULT 0,
    max_retries INTEGER DEFAULT 3,
    
    -- Cost tracking
    cost_per_sms NUMERIC(10, 4), -- Cost per SMS part
    total_cost NUMERIC(10, 4), -- Total cost (segments * cost)
    currency VARCHAR(3) DEFAULT 'USD',
    
    -- Provider adapter reference
    provider_adapter_id UUID REFERENCES ussd.provider_adapters(adapter_id),
    
    -- Session correlation (if triggered from USSD)
    session_id UUID,
    
    -- Scheduled messaging
    scheduled_at TIMESTAMPTZ,
    
    -- Reply tracking (for two-way SMS)
    reply_to_message_id UUID REFERENCES messaging.sms_messages(message_id),
    is_reply BOOLEAN DEFAULT FALSE,
    
    -- Metadata
    metadata JSONB DEFAULT '{}',
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    
    -- Constraints
    CONSTRAINT chk_valid_msisdn CHECK (recipient_msisdn ~ '^\+[1-9][0-9]{7,14}$'),
    CONSTRAINT chk_message_not_empty CHECK (LENGTH(TRIM(message_text)) > 0),
    CONSTRAINT chk_scheduled_future CHECK (scheduled_at IS NULL OR scheduled_at > created_at)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_sms_messages_app ON messaging.sms_messages(application_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sms_messages_status ON messaging.sms_messages(status, created_at) 
    WHERE status IN ('pending', 'queued', 'sent');
CREATE INDEX IF NOT EXISTS idx_sms_messages_recipient ON messaging.sms_messages(recipient_msisdn_hash, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sms_messages_at_id ON messaging.sms_messages(at_message_id) 
    WHERE at_message_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sms_messages_scheduled ON messaging.sms_messages(scheduled_at, status) 
    WHERE scheduled_at IS NOT NULL AND status = 'pending';

-- Foreign key indexes for performance
CREATE INDEX IF NOT EXISTS idx_sms_messages_adapter ON messaging.sms_messages(provider_adapter_id);
CREATE INDEX IF NOT EXISTS idx_sms_messages_session ON messaging.sms_messages(session_id) WHERE session_id IS NOT NULL;

COMMENT ON TABLE messaging.sms_messages IS 
'SMS MESSAGING - Africa''s Talking Integration
ISO 27001: A.13.2 (Information Transfer)
GDPR: Art 32 (Security), Art 33 (Breach Notification)

FEATURES:
- Single SMS and bulk campaign support
- Template-based messaging with variable substitution
- Delivery receipt tracking
- Character encoding detection (GSM-7 vs UCS-2)
- Segment calculation for concatenated SMS

COMPLIANCE:
- MSISDN hashed for privacy lookups
- Cost tracking per message/segment
- Rate limiting per application
- Opt-out handling for marketing messages';

-- =============================================================================
-- TABLE: sms_templates
-- DESCRIPTION: Registered SMS templates for transactional messaging
-- =============================================================================
CREATE TABLE IF NOT EXISTS messaging.sms_templates (
    template_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Template identification
    template_code VARCHAR(50) UNIQUE NOT NULL,
    template_name VARCHAR(100) NOT NULL,
    
    -- Business context
    application_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    
    -- Template content
    template_text TEXT NOT NULL,
    description TEXT,
    
    -- Variables (placeholders like {{name}}, {{amount}}, {{reference}})
    variables JSONB DEFAULT '[]', -- ["name", "amount", "reference"]
    
    -- Africa's Talking template registration
    at_template_id VARCHAR(100), -- AT's registered template ID
    at_template_status VARCHAR(20) DEFAULT 'pending'
        CHECK (at_template_status IN ('pending', 'submitted', 'approved', 'rejected')),
    
    -- Template type
    template_type VARCHAR(30) DEFAULT 'transactional'
        CHECK (template_type IN ('transactional', 'promotional', 'otp', 'alert')),
    
    -- Character analysis
    character_count INTEGER,
    segment_count INTEGER DEFAULT 1,
    encoding VARCHAR(20) DEFAULT 'GSM-7',
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    is_default BOOLEAN DEFAULT FALSE, -- Default template for its type
    
    -- Validity period
    valid_from DATE NOT NULL DEFAULT CURRENT_DATE,
    valid_until DATE,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    approved_by UUID,
    approved_at TIMESTAMPTZ,
    
    CONSTRAINT chk_valid_template CHECK (template_text ~ '\{\{[a-zA-Z_][a-zA-Z0-9_]*\}\}')
);

CREATE INDEX IF NOT EXISTS idx_sms_templates_app ON messaging.sms_templates(application_id, template_type, is_active);
CREATE INDEX IF NOT EXISTS idx_sms_templates_code ON messaging.sms_templates(template_code, is_active);

COMMENT ON TABLE messaging.sms_templates IS 'Registered SMS templates for Africa\'s Talking';

-- =============================================================================
-- TABLE: sms_delivery_receipts
-- DESCRIPTION: Delivery receipts from Africa's Talking
-- =============================================================================
CREATE TABLE IF NOT EXISTS messaging.sms_delivery_receipts (
    receipt_id UUID DEFAULT gen_random_uuid(),
    
    -- Link to original message
    message_id UUID NOT NULL REFERENCES messaging.sms_messages(message_id),
    
    -- Africa's Talking receipt data
    at_message_id VARCHAR(100) NOT NULL,
    at_status VARCHAR(30) NOT NULL, -- Sent, Delivered, Failed, etc.
    at_network_code VARCHAR(20), -- MNO network code
    at_failure_reason TEXT, -- Failure reason if any
    at_retry_count INTEGER, -- Number of retries
    
    -- Delivery details
    delivery_status VARCHAR(30) NOT NULL
        CHECK (delivery_status IN ('sent', 'delivered', 'failed', 'expired', 'rejected')),
    delivered_at TIMESTAMPTZ,
    
    -- Raw webhook data (for audit)
    raw_webhook_data JSONB,
    
    -- Processing
    processed BOOLEAN DEFAULT FALSE,
    processed_at TIMESTAMPTZ,
    
    -- Timestamp
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Partition key for time-series
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT pk_messaging_sms_delivery_receipts_receipt_id_received_at PRIMARY KEY (receipt_id, received_at));

-- Convert to hypertable
SELECT create_hypertable(
    'messaging.sms_delivery_receipts',
    'received_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_sms_receipts_message ON messaging.sms_delivery_receipts(message_id);
CREATE INDEX IF NOT EXISTS idx_sms_receipts_at_id ON messaging.sms_delivery_receipts(at_message_id);
CREATE INDEX IF NOT EXISTS idx_sms_receipts_unprocessed ON messaging.sms_delivery_receipts(processed) 
    WHERE processed = FALSE;

COMMENT ON TABLE messaging.sms_delivery_receipts IS 'SMS delivery receipts from Africa\'s Talking';

-- =============================================================================
-- TABLE: sms_bulk_campaigns
-- DESCRIPTION: Bulk SMS campaigns
-- =============================================================================
CREATE TABLE IF NOT EXISTS messaging.sms_bulk_campaigns (
    campaign_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Campaign identification
    campaign_code VARCHAR(50) UNIQUE NOT NULL,
    campaign_name VARCHAR(100) NOT NULL,
    
    -- Business context
    application_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    
    -- Message content
    template_id UUID REFERENCES messaging.sms_templates(template_id),
    message_text TEXT NOT NULL,
    
    -- Recipients
    recipient_count INTEGER NOT NULL DEFAULT 0,
    recipient_list_source VARCHAR(100), -- File name or source identifier
    
    -- Africa's Talking batch
    at_batch_id VARCHAR(100),
    
    -- Status
    status VARCHAR(20) DEFAULT 'draft'
        CHECK (status IN ('draft', 'scheduled', 'sending', 'paused', 'completed', 'cancelled')),
    
    -- Scheduling
    scheduled_at TIMESTAMPTZ,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    
    -- Progress tracking
    sent_count INTEGER DEFAULT 0,
    delivered_count INTEGER DEFAULT 0,
    failed_count INTEGER DEFAULT 0,
    pending_count INTEGER DEFAULT 0,
    
    -- Cost tracking
    total_cost NUMERIC(12, 4),
    currency VARCHAR(3) DEFAULT 'USD',
    
    -- Rate limiting
    rate_limit_per_minute INTEGER DEFAULT 100,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    
    CONSTRAINT chk_scheduled_after_created CHECK (scheduled_at IS NULL OR scheduled_at >= created_at)
);

CREATE INDEX IF NOT EXISTS idx_sms_campaigns_app ON messaging.sms_bulk_campaigns(application_id, status);
CREATE INDEX IF NOT EXISTS idx_sms_campaigns_scheduled ON messaging.sms_bulk_campaigns(scheduled_at, status) 
    WHERE status = 'scheduled';

COMMENT ON TABLE messaging.sms_bulk_campaigns IS 'Bulk SMS campaigns via Africa\'s Talking';

-- =============================================================================
-- TABLE: sms_bulk_recipients
-- DESCRIPTION: Individual recipients for bulk campaigns
-- =============================================================================
CREATE TABLE IF NOT EXISTS messaging.sms_bulk_recipients (
    recipient_id UUID DEFAULT gen_random_uuid(),
    
    campaign_id UUID NOT NULL REFERENCES messaging.sms_bulk_campaigns(campaign_id) ON DELETE CASCADE,
    
    -- Recipient details
    msisdn VARCHAR(20) NOT NULL,
    msisdn_hash VARCHAR(64),
    
    -- Personalization
    personalization_data JSONB DEFAULT '{}', -- {"name": "John", "amount": "100"}
    
    -- Message reference
    message_id UUID REFERENCES messaging.sms_messages(message_id),
    
    -- Status
    status VARCHAR(20) DEFAULT 'pending'
        CHECK (status IN ('pending', 'queued', 'sent', 'delivered', 'failed', 'skipped')),
    
    -- Processing
    processed_at TIMESTAMPTZ,
    error_message TEXT,
    
    -- Partition key
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE,
    
    UNIQUE (campaign_id, msisdn, created_at),
    CONSTRAINT pk_messaging_sms_bulk_recipients_recipient_id_created_at PRIMARY KEY (recipient_id, created_at));

-- Convert to hypertable
SELECT create_hypertable(
    'messaging.sms_bulk_recipients',
    'created_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_sms_bulk_recipients_campaign ON messaging.sms_bulk_recipients(campaign_id, status);
CREATE INDEX IF NOT EXISTS idx_sms_bulk_recipients_pending ON messaging.sms_bulk_recipients(campaign_id, status) 
    WHERE status = 'pending';

COMMENT ON TABLE messaging.sms_bulk_recipients IS 'Individual recipients for bulk SMS campaigns';

-- =============================================================================
-- TABLE: sms_inbound_webhooks
-- DESCRIPTION: Log of incoming SMS webhooks from Africa's Talking
-- =============================================================================
CREATE TABLE IF NOT EXISTS messaging.sms_inbound_webhooks (
    webhook_id UUID DEFAULT gen_random_uuid(),
    
    -- Webhook data from Africa's Talking
    from_msisdn VARCHAR(20) NOT NULL,
    to_shortcode VARCHAR(20) NOT NULL,
    message_text TEXT NOT NULL,
    message_id VARCHAR(100), -- AT's message ID
    network_code VARCHAR(20), -- MNO network code
    
    -- Processing
    processed BOOLEAN DEFAULT FALSE,
    processed_at TIMESTAMPTZ,
    
    -- Link to created message record
    message_record_id UUID REFERENCES messaging.sms_messages(message_id),
    
    -- Raw data
    raw_payload JSONB NOT NULL,
    
    -- IP and security
    source_ip INET,
    signature_valid BOOLEAN, -- Webhook signature validation
    
    -- Timestamps
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT pk_messaging_sms_inbound_webhooks_webhook_id_received_at PRIMARY KEY (webhook_id, received_at));

-- Convert to hypertable
SELECT create_hypertable(
    'messaging.sms_inbound_webhooks',
    'received_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_sms_inbound_unprocessed ON messaging.sms_inbound_webhooks(processed, received_at) 
    WHERE processed = FALSE;
CREATE INDEX IF NOT EXISTS idx_sms_inbound_from ON messaging.sms_inbound_webhooks(from_msisdn, received_at DESC);

COMMENT ON TABLE messaging.sms_inbound_webhooks IS 'Incoming SMS webhooks from Africa\'s Talking';

-- =============================================================================
-- TRIGGERS AND FUNCTIONS
-- =============================================================================

-- Trigger: Auto-hash MSISDN and calculate segments
CREATE OR REPLACE FUNCTION messaging.hash_sms_msisdn()
RETURNS TRIGGER AS $$
BEGIN
    NEW.recipient_msisdn_hash := encode(digest(NEW.recipient_msisdn, 'sha256'), 'hex');
    
    -- Calculate character and segment count
    NEW.character_count := LENGTH(NEW.message_text);
    
    -- Determine encoding and segments
    IF NEW.message_text ~ '[^\x00-\x7F]' THEN
        NEW.encoding := 'UCS-2';
        NEW.segment_count := CEIL(NEW.character_count::NUMERIC / 70);
    ELSE
        NEW.encoding := 'GSM-7';
        NEW.segment_count := CEIL(NEW.character_count::NUMERIC / 160);
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION messaging.hash_sms_msisdn() IS 
'Hashes MSISDN and calculates SMS segments/encoding on insert.
GSM-7: 160 chars per segment, UCS-2: 70 chars per segment (for special chars).';

DROP TRIGGER IF EXISTS trg_sms_messages_hash ON messaging.sms_messages;
CREATE TRIGGER trg_sms_messages_hash
    BEFORE INSERT ON messaging.sms_messages
    FOR EACH ROW
    EXECUTE FUNCTION messaging.hash_sms_msisdn();

-- Triggers: Update timestamps (uses core.update_timestamp for DRY principle)
DROP TRIGGER IF EXISTS trg_sms_messages_update ON messaging.sms_messages;
CREATE TRIGGER trg_sms_messages_update
    BEFORE UPDATE ON messaging.sms_messages
    FOR EACH ROW
    EXECUTE FUNCTION core.update_timestamp();

DROP TRIGGER IF EXISTS trg_sms_templates_update ON messaging.sms_templates;
CREATE TRIGGER trg_sms_templates_update
    BEFORE UPDATE ON messaging.sms_templates
    FOR EACH ROW
    EXECUTE FUNCTION core.update_timestamp();

DROP TRIGGER IF EXISTS trg_sms_campaigns_update ON messaging.sms_bulk_campaigns;
CREATE TRIGGER trg_sms_campaigns_update
    BEFORE UPDATE ON messaging.sms_bulk_campaigns
    FOR EACH ROW
    EXECUTE FUNCTION core.update_timestamp();

-- =============================================================================
-- WORM TRIGGERS (Immutability)
-- =============================================================================

CREATE TRIGGER trg_sms_messages_prevent_update
    BEFORE UPDATE ON messaging.sms_messages
    FOR EACH ROW
    WHEN (OLD.status IN ('delivered', 'failed', 'expired', 'rejected'))
    EXECUTE FUNCTION core.prevent_update();

-- =============================================================================
-- RLS POLICIES
-- =============================================================================

DO $$
BEGIN
    ALTER TABLE messaging.sms_messages ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE messaging.sms_messages FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE messaging.sms_templates ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE messaging.sms_templates FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE messaging.sms_bulk_campaigns ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE messaging.sms_bulk_campaigns FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Policy: Application-scoped access
CREATE POLICY sms_messages_app_isolation ON messaging.sms_messages
    FOR ALL
    TO ussd_app_user
    USING (application_id = current_setting('app.current_application_id', true)::UUID);

CREATE POLICY sms_templates_app_isolation ON messaging.sms_templates
    FOR ALL
    TO ussd_app_user
    USING (application_id = current_setting('app.current_application_id', true)::UUID);

CREATE POLICY sms_campaigns_app_isolation ON messaging.sms_bulk_campaigns
    FOR ALL
    TO ussd_app_user
    USING (application_id = current_setting('app.current_application_id', true)::UUID);

-- =============================================================================
-- GRANTS
-- =============================================================================

GRANT USAGE ON SCHEMA messaging TO ussd_gateway_role, ussd_app_user;
GRANT SELECT, INSERT, UPDATE ON messaging.sms_messages TO ussd_gateway_role;
GRANT SELECT, INSERT, UPDATE ON messaging.sms_templates TO ussd_gateway_role;
GRANT SELECT, INSERT, UPDATE ON messaging.sms_delivery_receipts TO ussd_gateway_role;
GRANT SELECT, INSERT, UPDATE ON messaging.sms_bulk_campaigns TO ussd_gateway_role;
GRANT SELECT, INSERT, UPDATE ON messaging.sms_bulk_recipients TO ussd_gateway_role;
GRANT SELECT, INSERT ON messaging.sms_inbound_webhooks TO ussd_gateway_role;

COMMIT;
