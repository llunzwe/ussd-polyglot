-- =============================================================================
-- Migration: V064__messaging_whatsapp_schema
-- Description: WhatsApp Business Messaging Schema for Africa's Talking
-- Dependencies: V063
-- =============================================================================
-- PURPOSE: Complete WhatsApp Business messaging system for business applications
--          using Africa's Talking WhatsApp API. Supports session-based messaging,
--          templates (required for business-initiated), media, and interactive
--          messages.
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- TABLE: whatsapp_messages
-- DESCRIPTION: All WhatsApp messages (outbound and inbound)
-- =============================================================================
CREATE TABLE IF NOT EXISTS messaging.whatsapp_messages (
    message_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Message direction
    direction VARCHAR(10) NOT NULL DEFAULT 'outbound'
        CHECK (direction IN ('outbound', 'inbound')),
    
    -- Business context
    application_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    account_id UUID REFERENCES core.account_registry(account_id),
    
    -- WhatsApp Business Account
    whatsapp_business_id VARCHAR(100) NOT NULL, -- WABA ID
    phone_number_id VARCHAR(100) NOT NULL, -- WhatsApp phone number ID
    
    -- Recipient/Sender
    recipient_msisdn VARCHAR(20) NOT NULL, -- For outbound
    recipient_msisdn_hash VARCHAR(64),
    sender_msisdn VARCHAR(20), -- For inbound
    
    -- Message content
    message_type VARCHAR(30) NOT NULL DEFAULT 'text'
        CHECK (message_type IN (
            'text', 'template', 'image', 'document', 'audio', 
            'video', 'location', 'contact', 'interactive', 'button',
            'reaction', 'sticker'
        )),
    
    -- Text content
    text_body TEXT,
    text_body_encrypted BYTEA, -- For sensitive content
    
    -- Template reference (for business-initiated messages)
    template_id UUID,
    template_name VARCHAR(100),
    template_language VARCHAR(10) DEFAULT 'en',
    template_parameters JSONB, -- Template variable values
    
    -- Media content
    media_id VARCHAR(100), -- WhatsApp media ID
    media_url TEXT, -- URL to media file
    media_mime_type VARCHAR(100),
    media_filename VARCHAR(255),
    media_caption TEXT,
    media_size_bytes BIGINT,
    
    -- Interactive message
    interactive_type VARCHAR(20), -- button, list, product
    interactive_content JSONB, -- Button/list structure
    
    -- Context (for replies)
    context_message_id VARCHAR(100), -- Message being replied to
    
    -- Africa's Talking / WhatsApp API
    at_message_id VARCHAR(100), -- AT's message ID
    wa_message_id VARCHAR(100), -- WhatsApp's message ID
    
    -- Status tracking
    status VARCHAR(30) DEFAULT 'pending'
        CHECK (status IN (
            'pending',      -- Waiting to be sent
            'submitted',    -- Submitted to WhatsApp
            'sent',         -- Sent to recipient
            'delivered',    -- Delivered to device
            'read',         -- Read by recipient
            'failed',       -- Failed to send
            'rejected',     -- Rejected by WhatsApp
            'received'      -- Inbound message received
        )),
    
    -- Timing
    sent_at TIMESTAMPTZ,
    delivered_at TIMESTAMPTZ,
    read_at TIMESTAMPTZ,
    failed_at TIMESTAMPTZ,
    received_at TIMESTAMPTZ,
    
    -- Failure details
    failure_reason TEXT,
    failure_code VARCHAR(50),
    error_subcode VARCHAR(50),
    
    -- Cost tracking
    cost NUMERIC(10, 4),
    currency VARCHAR(3) DEFAULT 'USD',
    pricing_category VARCHAR(20), -- user_initiated, business_initiated, referral
    
    -- Session (24-hour window tracking)
    session_id UUID, -- Link to messaging session
    session_expires_at TIMESTAMPTZ, -- 24-hour window expiry
    is_within_session BOOLEAN DEFAULT FALSE, -- Within 24h window
    
    -- Provider adapter
    provider_adapter_id UUID REFERENCES ussd.provider_adapters(adapter_id),
    
    -- Metadata
    metadata JSONB DEFAULT '{}',
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    
    -- Constraints
    CONSTRAINT chk_valid_msisdn CHECK (recipient_msisdn ~ '^\+[1-9][0-9]{7,14}$'),
    CONSTRAINT chk_template_required CHECK (
        (direction = 'outbound' AND is_within_session = FALSE AND template_id IS NOT NULL) OR
        (direction = 'outbound' AND is_within_session = TRUE) OR
        (direction = 'inbound')
    )
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_whatsapp_messages_app ON messaging.whatsapp_messages(application_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_whatsapp_messages_status ON messaging.whatsapp_messages(status, created_at) 
    WHERE status IN ('pending', 'submitted', 'sent');
CREATE INDEX IF NOT EXISTS idx_whatsapp_messages_recipient ON messaging.whatsapp_messages(recipient_msisdn_hash, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_whatsapp_messages_wa_id ON messaging.whatsapp_messages(wa_message_id) 
    WHERE wa_message_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_whatsapp_messages_session ON messaging.whatsapp_messages(session_id, is_within_session);

-- Foreign key indexes for performance
CREATE INDEX IF NOT EXISTS idx_whatsapp_messages_adapter ON messaging.whatsapp_messages(provider_adapter_id);

COMMENT ON TABLE messaging.whatsapp_messages IS 
'WHATSAPP BUSINESS API - Africa''s Talking Integration
ISO 27001: A.13.2 (Information Transfer)
GDPR: Art 6(1)(a) (Consent), Art 7 (Conditions for Consent)

BUSINESS API COMPLIANCE:
- 24-hour session window tracking
- Template required for business-initiated messages
- Template approval status verification
- Conversation-based pricing tracking
- User opt-in/opt-out management

SECURITY:
- Contact MSISDN encrypted
- Session isolation between applications
- Media file scanning before storage';

-- =============================================================================
-- TABLE: whatsapp_templates
-- DESCRIPTION: WhatsApp Business message templates (required for outbound)
-- =============================================================================
CREATE TABLE IF NOT EXISTS messaging.whatsapp_templates (
    template_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Template identification
    template_code VARCHAR(50) UNIQUE NOT NULL,
    template_name VARCHAR(100) NOT NULL,
    
    -- Business context
    application_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    
    -- WhatsApp template registration
    wa_template_id VARCHAR(100), -- WhatsApp's template ID
    wa_template_name VARCHAR(100) NOT NULL, -- Registered template name
    wa_template_namespace VARCHAR(100),
    
    -- Template structure
    category VARCHAR(30) NOT NULL DEFAULT 'UTILITY'
        CHECK (category IN ('MARKETING', 'UTILITY', 'AUTHENTICATION')),
    language_code VARCHAR(10) NOT NULL DEFAULT 'en',
    
    -- Template components
    header_type VARCHAR(20) DEFAULT 'none' 
        CHECK (header_type IN ('none', 'text', 'image', 'document', 'video')),
    header_text TEXT,
    header_example TEXT,
    
    body_text TEXT NOT NULL,
    body_example TEXT, -- Example values for variables
    
    footer_text TEXT,
    
    buttons JSONB DEFAULT '[]', -- Button configuration
    
    -- Variables
    variables JSONB DEFAULT '[]', -- ["var1", "var2", "var3"]
    variable_examples JSONB DEFAULT '{}', -- {"var1": "John", "var2": "100"}
    
    -- WhatsApp approval status
    approval_status VARCHAR(20) DEFAULT 'pending'
        CHECK (approval_status IN ('pending', 'submitted', 'approved', 'rejected', 'paused')),
    rejection_reason TEXT,
    submitted_at TIMESTAMPTZ,
    approved_at TIMESTAMPTZ,
    
    -- Quality rating
    quality_score VARCHAR(20), -- green, yellow, red
    quality_score_updated_at TIMESTAMPTZ,
    
    -- Template settings
    is_active BOOLEAN DEFAULT TRUE,
    is_default BOOLEAN DEFAULT FALSE,
    
    -- Usage tracking
    sent_count INTEGER DEFAULT 0,
    delivered_count INTEGER DEFAULT 0,
    read_count INTEGER DEFAULT 0,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    
    CONSTRAINT chk_valid_template_name CHECK (wa_template_name ~ '^[a-z0-9_]+$')
);

CREATE INDEX IF NOT EXISTS idx_whatsapp_templates_app ON messaging.whatsapp_templates(application_id, approval_status, is_active);
CREATE INDEX IF NOT EXISTS idx_whatsapp_templates_name ON messaging.whatsapp_templates(wa_template_name, language_code, is_active);

COMMENT ON TABLE messaging.whatsapp_templates IS 'WhatsApp Business message templates (required for business-initiated)';

-- =============================================================================
-- TABLE: whatsapp_sessions
-- DESCRIPTION: WhatsApp messaging sessions (24-hour window tracking)
-- =============================================================================
CREATE TABLE IF NOT EXISTS messaging.whatsapp_sessions (
    session_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Business context
    application_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    
    -- Contact
    contact_msisdn VARCHAR(20) NOT NULL,
    contact_msisdn_hash VARCHAR(64),
    contact_name VARCHAR(100),
    
    -- WhatsApp Business
    whatsapp_business_id VARCHAR(100) NOT NULL,
    phone_number_id VARCHAR(100) NOT NULL,
    
    -- Session window
    window_opens_at TIMESTAMPTZ NOT NULL, -- When user last messaged
    window_expires_at TIMESTAMPTZ NOT NULL, -- 24 hours later
    is_window_open BOOLEAN DEFAULT TRUE,
    
    -- Session state
    status VARCHAR(20) DEFAULT 'active'
        CHECK (status IN ('active', 'closed', 'expired')),
    
    -- Last activity
    last_message_at TIMESTAMPTZ,
    last_message_direction VARCHAR(10), -- inbound or outbound
    
    -- Message counts
    inbound_count INTEGER DEFAULT 0,
    outbound_count INTEGER DEFAULT 0,
    
    -- Context data
    context_data JSONB DEFAULT '{}',
    
    -- Correlation to other channels
    ussd_session_id UUID,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    closed_at TIMESTAMPTZ,
    
    UNIQUE (application_id, contact_msisdn, whatsapp_business_id)
);

CREATE INDEX IF NOT EXISTS idx_whatsapp_sessions_app ON messaging.whatsapp_sessions(application_id, status);
CREATE INDEX IF NOT EXISTS idx_whatsapp_sessions_contact ON messaging.whatsapp_sessions(contact_msisdn_hash, window_expires_at);
CREATE INDEX IF NOT EXISTS idx_whatsapp_sessions_window ON messaging.whatsapp_sessions(window_expires_at, is_window_open) 
    WHERE is_window_open = TRUE;

COMMENT ON TABLE messaging.whatsapp_sessions IS 'WhatsApp messaging sessions (24-hour window tracking)';

-- =============================================================================
-- TABLE: whatsapp_contacts
-- DESCRIPTION: WhatsApp contact opt-in and profile information
-- =============================================================================
CREATE TABLE IF NOT EXISTS messaging.whatsapp_contacts (
    contact_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Business context
    application_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    
    -- Contact identification
    msisdn VARCHAR(20) NOT NULL,
    msisdn_hash VARCHAR(64),
    
    -- WhatsApp profile
    wa_id VARCHAR(50), -- WhatsApp ID
    profile_name VARCHAR(100),
    profile_picture_url TEXT,
    
    -- Opt-in status (required for business messaging)
    opt_in_status VARCHAR(20) DEFAULT 'pending'
        CHECK (opt_in_status IN ('pending', 'confirmed', 'revoked', 'blocked')),
    opt_in_at TIMESTAMPTZ,
    opt_in_method VARCHAR(50), -- ussd, sms, web, whatsapp
    opt_in_reference VARCHAR(100), -- Transaction or session reference
    
    -- Consent tracking
    consent_version VARCHAR(20),
    consent_accepted_at TIMESTAMPTZ,
    
    -- Blocking
    is_blocked BOOLEAN DEFAULT FALSE,
    blocked_at TIMESTAMPTZ,
    blocked_reason TEXT,
    
    -- Quality metrics
    last_message_at TIMESTAMPTZ,
    message_count INTEGER DEFAULT 0,
    
    -- Custom fields
    tags TEXT[], -- ["vip", "customer", "lead"]
    custom_fields JSONB DEFAULT '{}',
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    UNIQUE (application_id, msisdn)
);

CREATE INDEX IF NOT EXISTS idx_whatsapp_contacts_app ON messaging.whatsapp_contacts(application_id, opt_in_status);
CREATE INDEX IF NOT EXISTS idx_whatsapp_contacts_msisdn ON messaging.whatsapp_contacts(msisdn_hash);
CREATE INDEX IF NOT EXISTS idx_whatsapp_contacts_opted_in ON messaging.whatsapp_contacts(application_id, opt_in_status, is_blocked) 
    WHERE opt_in_status = 'confirmed' AND is_blocked = FALSE;

COMMENT ON TABLE messaging.whatsapp_contacts IS 'WhatsApp contact opt-in and profile management';

-- =============================================================================
-- TABLE: whatsapp_webhooks
-- DESCRIPTION: Incoming WhatsApp webhooks from Africa's Talking
-- =============================================================================
CREATE TABLE IF NOT EXISTS messaging.whatsapp_webhooks (
    webhook_id UUID DEFAULT gen_random_uuid(),
    
    -- Webhook type
    webhook_type VARCHAR(30) NOT NULL
        CHECK (webhook_type IN ('message', 'status', 'template_status', 'phone_number')),
    
    -- Sender/Recipient info
    from_msisdn VARCHAR(20),
    to_phone_number_id VARCHAR(100),
    
    -- Message data (for message webhooks)
    wa_message_id VARCHAR(100),
    message_type VARCHAR(30),
    message_content JSONB, -- Parsed message content
    
    -- Status data (for status webhooks)
    status VARCHAR(30),
    status_timestamp TIMESTAMPTZ,
    
    -- Conversation data
    conversation_id VARCHAR(100),
    conversation_category VARCHAR(20), -- user_initiated, business_initiated, referral
    
    -- Pricing data
    pricing_model VARCHAR(20),
    pricing_cost NUMERIC(10, 4),
    
    -- Processing
    processed BOOLEAN DEFAULT FALSE,
    processed_at TIMESTAMPTZ,
    message_record_id UUID REFERENCES messaging.whatsapp_messages(message_id),
    
    -- Raw data
    raw_payload JSONB NOT NULL,
    
    -- Security
    source_ip INET,
    signature_valid BOOLEAN,
    
    -- Timestamp
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT pk_messaging_whatsapp_webhooks_webhook_id_received_at PRIMARY KEY (webhook_id, received_at));

-- Convert to hypertable
SELECT create_hypertable(
    'messaging.whatsapp_webhooks',
    'received_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_whatsapp_webhooks_unprocessed ON messaging.whatsapp_webhooks(processed, received_at) 
    WHERE processed = FALSE;
CREATE INDEX IF NOT EXISTS idx_whatsapp_webhooks_wa_id ON messaging.whatsapp_webhooks(wa_message_id);

COMMENT ON TABLE messaging.whatsapp_webhooks IS 'Incoming WhatsApp webhooks from Africa\'s Talking';

-- =============================================================================
-- TABLE: whatsapp_media
-- DESCRIPTION: WhatsApp media file tracking
-- =============================================================================
CREATE TABLE IF NOT EXISTS messaging.whatsapp_media (
    media_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Media identification
    wa_media_id VARCHAR(100) UNIQUE NOT NULL,
    
    -- Message reference
    message_id UUID REFERENCES messaging.whatsapp_messages(message_id),
    
    -- Media details
    media_type VARCHAR(20) NOT NULL 
        CHECK (media_type IN ('image', 'document', 'audio', 'video', 'sticker')),
    mime_type VARCHAR(100) NOT NULL,
    file_name VARCHAR(255),
    file_size_bytes BIGINT,
    
    -- Storage
    storage_url TEXT, -- Internal storage URL
    storage_path TEXT, -- File system path
    storage_provider VARCHAR(50), -- s3, gcs, azure, local
    
    -- WhatsApp URLs
    wa_download_url TEXT, -- Temporary download URL from WhatsApp
    url_expires_at TIMESTAMPTZ,
    
    -- Processing
    is_downloaded BOOLEAN DEFAULT FALSE,
    downloaded_at TIMESTAMPTZ,
    download_attempts INTEGER DEFAULT 0,
    last_error TEXT,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_whatsapp_media_message ON messaging.whatsapp_media(message_id);
CREATE INDEX IF NOT EXISTS idx_whatsapp_media_download ON messaging.whatsapp_media(is_downloaded, url_expires_at) 
    WHERE is_downloaded = FALSE;

COMMENT ON TABLE messaging.whatsapp_media IS 'WhatsApp media file tracking and storage';

-- =============================================================================
-- TRIGGERS
-- =============================================================================

-- Trigger: Auto-hash MSISDN and update timestamps
CREATE OR REPLACE FUNCTION messaging.whatsapp_before_insert()
RETURNS TRIGGER AS $$
BEGIN
    -- Hash MSISDN
    IF NEW.recipient_msisdn IS NOT NULL THEN
        NEW.recipient_msisdn_hash := encode(digest(NEW.recipient_msisdn, 'sha256'), 'hex');
    END IF;
    
    -- Set session window for outbound messages
    IF NEW.direction = 'outbound' THEN
        -- Check if there's an active session
        SELECT ws.window_expires_at, ws.session_id, ws.window_expires_at > NOW()
        INTO NEW.session_expires_at, NEW.session_id, NEW.is_within_session
        FROM messaging.whatsapp_sessions ws
        WHERE ws.contact_msisdn = NEW.recipient_msisdn
          AND ws.whatsapp_business_id = NEW.whatsapp_business_id
          AND ws.is_window_open = TRUE
        ORDER BY ws.window_expires_at DESC
        LIMIT 1;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_whatsapp_messages_insert ON messaging.whatsapp_messages;
CREATE TRIGGER trg_whatsapp_messages_insert
    BEFORE INSERT ON messaging.whatsapp_messages
    FOR EACH ROW
    EXECUTE FUNCTION messaging.whatsapp_before_insert();

-- Update timestamp trigger
DROP TRIGGER IF EXISTS trg_whatsapp_messages_update ON messaging.whatsapp_messages;
CREATE TRIGGER trg_whatsapp_messages_update
    BEFORE UPDATE ON messaging.whatsapp_messages
    FOR EACH ROW
    EXECUTE FUNCTION core.update_timestamp();

DROP TRIGGER IF EXISTS trg_whatsapp_templates_update ON messaging.whatsapp_templates;
CREATE TRIGGER trg_whatsapp_templates_update
    BEFORE UPDATE ON messaging.whatsapp_templates
    FOR EACH ROW
    EXECUTE FUNCTION core.update_timestamp();

DROP TRIGGER IF EXISTS trg_whatsapp_sessions_update ON messaging.whatsapp_sessions;
CREATE TRIGGER trg_whatsapp_sessions_update
    BEFORE UPDATE ON messaging.whatsapp_sessions
    FOR EACH ROW
    EXECUTE FUNCTION core.update_timestamp();

-- =============================================================================
-- RLS POLICIES
-- =============================================================================

DO $$
BEGIN
    ALTER TABLE messaging.whatsapp_messages ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE messaging.whatsapp_messages FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE messaging.whatsapp_templates ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE messaging.whatsapp_templates FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE messaging.whatsapp_sessions ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE messaging.whatsapp_sessions FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE messaging.whatsapp_contacts ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE messaging.whatsapp_contacts FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Application-scoped access
CREATE POLICY whatsapp_messages_app_isolation ON messaging.whatsapp_messages
    FOR ALL
    TO ussd_app_user
    USING (application_id = current_setting('app.current_application_id', true)::UUID);

CREATE POLICY whatsapp_templates_app_isolation ON messaging.whatsapp_templates
    FOR ALL
    TO ussd_app_user
    USING (application_id = current_setting('app.current_application_id', true)::UUID);

CREATE POLICY whatsapp_sessions_app_isolation ON messaging.whatsapp_sessions
    FOR ALL
    TO ussd_app_user
    USING (application_id = current_setting('app.current_application_id', true)::UUID);

CREATE POLICY whatsapp_contacts_app_isolation ON messaging.whatsapp_contacts
    FOR ALL
    TO ussd_app_user
    USING (application_id = current_setting('app.current_application_id', true)::UUID);

-- =============================================================================
-- GRANTS
-- =============================================================================

GRANT SELECT, INSERT, UPDATE ON messaging.whatsapp_messages TO ussd_gateway_role;
GRANT SELECT, INSERT, UPDATE ON messaging.whatsapp_templates TO ussd_gateway_role;
GRANT SELECT, INSERT, UPDATE ON messaging.whatsapp_sessions TO ussd_gateway_role;
GRANT SELECT, INSERT, UPDATE ON messaging.whatsapp_contacts TO ussd_gateway_role;
GRANT SELECT, INSERT ON messaging.whatsapp_webhooks TO ussd_gateway_role;
GRANT SELECT, INSERT, UPDATE ON messaging.whatsapp_media TO ussd_gateway_role;

COMMIT;
