-- =============================================================================
-- Migration: V065__messaging_functions
-- Description: Messaging Functions for Africa's Talking Integration
-- Dependencies: V063, V064
-- =============================================================================
-- PURPOSE: Core functions for sending SMS and WhatsApp messages through
--          Africa's Talking API. Includes queue management, template processing,
--          and session handling.
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- SMS FUNCTIONS
-- =============================================================================

-- Function: Send single SMS
CREATE OR REPLACE FUNCTION messaging.send_sms(
    p_application_id UUID,
    p_recipient_msisdn VARCHAR(20),
    p_message_text TEXT,
    p_sender_id VARCHAR(50) DEFAULT NULL,
    p_template_id UUID DEFAULT NULL,
    p_template_variables JSONB DEFAULT NULL,
    p_scheduled_at TIMESTAMPTZ DEFAULT NULL,
    p_session_id UUID DEFAULT NULL,
    p_created_by UUID DEFAULT NULL
)
RETURNS TABLE (
    message_id UUID,
    status VARCHAR(30),
    segment_count INTEGER,
    estimated_cost NUMERIC(10, 4),
    error_message TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_message_id UUID;
    v_provider_adapter_id UUID;
    v_sender_id VARCHAR(50);
    v_segment_count INTEGER;
    v_cost_per_sms NUMERIC(10, 4) := 0.008; -- Default cost
    v_total_cost NUMERIC(10, 4);
    v_template_text TEXT;
    v_final_message TEXT;
BEGIN
    -- Validate MSISDN format
    IF p_recipient_msisdn !~ '^\+[1-9][0-9]{7,14}$' THEN
        RETURN QUERY SELECT 
            NULL::UUID, 
            'failed'::VARCHAR(30), 
            0::INTEGER, 
            0::NUMERIC(10, 4), 
            'Invalid MSISDN format'::TEXT;
        RETURN;
    END IF;
    
    -- Get default sender_id from provider config if not provided
    IF p_sender_id IS NULL THEN
        SELECT pa.adapter_id, pa.provider_config->>'sms'->>'sender_id'
        INTO v_provider_adapter_id, v_sender_id
        FROM ussd.provider_adapters pa
        WHERE pa.provider_name = 'africas_talking'
          AND pa.is_active = TRUE
          AND pa.environment = 'production'
        ORDER BY pa.is_default DESC
        LIMIT 1;
    ELSE
        SELECT pa.adapter_id INTO v_provider_adapter_id
        FROM ussd.provider_adapters pa
        WHERE pa.provider_name = 'africas_talking'
          AND pa.is_active = TRUE
        LIMIT 1;
        v_sender_id := p_sender_id;
    END IF;
    
    -- Process template if provided
    IF p_template_id IS NOT NULL THEN
        SELECT template_text INTO v_template_text
        FROM messaging.sms_templates
        WHERE template_id = p_template_id
          AND is_active = TRUE
          AND application_id = p_application_id;
        
        IF v_template_text IS NULL THEN
            RETURN QUERY SELECT 
                NULL::UUID, 
                'failed'::VARCHAR(30), 
                0::INTEGER, 
                0::NUMERIC(10, 4), 
                'Template not found or inactive'::TEXT;
            RETURN;
        END IF;
        
        -- Replace template variables
        v_final_message := v_template_text;
        IF p_template_variables IS NOT NULL THEN
            DECLARE
                v_key TEXT;
                v_value TEXT;
            BEGIN
                FOR v_key, v_value IN SELECT * FROM jsonb_each_text(p_template_variables) LOOP
                    v_final_message := REPLACE(v_final_message, '{{' || v_key || '}}', v_value);
                END LOOP;
            END;
        END IF;
    ELSE
        v_final_message := p_message_text;
    END IF;
    
    -- Calculate segments
    IF v_final_message ~ '[^\x00-\x7F]' THEN
        v_segment_count := CEIL(LENGTH(v_final_message)::NUMERIC / 70);
    ELSE
        v_segment_count := CEIL(LENGTH(v_final_message)::NUMERIC / 160);
    END IF;
    
    v_total_cost := v_segment_count * v_cost_per_sms;
    
    -- Insert message record
    INSERT INTO messaging.sms_messages (
        message_type,
        application_id,
        session_id,
        sender_id,
        recipient_msisdn,
        message_text,
        template_id,
        template_variables,
        segment_count,
        provider_adapter_id,
        scheduled_at,
        status,
        total_cost,
        currency,
        created_by
    ) VALUES (
        CASE WHEN p_scheduled_at IS NOT NULL THEN 'scheduled' ELSE 'outbound' END,
        p_application_id,
        p_session_id,
        COALESCE(v_sender_id, 'AFRICASTKNG'),
        p_recipient_msisdn,
        v_final_message,
        p_template_id,
        p_template_variables,
        v_segment_count,
        v_provider_adapter_id,
        p_scheduled_at,
        CASE WHEN p_scheduled_at IS NOT NULL THEN 'pending' ELSE 'queued' END,
        v_total_cost,
        'USD',
        p_created_by
    )
    RETURNING sms_messages.message_id INTO v_message_id;
    
    RETURN QUERY SELECT 
        v_message_id, 
        CASE WHEN p_scheduled_at IS NOT NULL THEN 'scheduled'::VARCHAR(30) ELSE 'queued'::VARCHAR(30) END,
        v_segment_count, 
        v_total_cost, 
        NULL::TEXT;
        
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 
        NULL::UUID, 
        'failed'::VARCHAR(30), 
        0::INTEGER, 
        0::NUMERIC(10, 4), 
        SQLERRM::TEXT;
END;
$$;

COMMENT ON FUNCTION messaging.send_sms IS 'Send single SMS via Africa\'s Talking';

-- Function: Send bulk SMS
CREATE OR REPLACE FUNCTION messaging.send_bulk_sms(
    p_application_id UUID,
    p_campaign_name VARCHAR(100),
    p_message_text TEXT,
    p_recipients JSONB, -- [{"msisdn": "+254...", "vars": {"name": "John"}}]
    p_template_id UUID DEFAULT NULL,
    p_sender_id VARCHAR(50) DEFAULT NULL,
    p_scheduled_at TIMESTAMPTZ DEFAULT NULL,
    p_rate_limit_per_minute INTEGER DEFAULT 100,
    p_created_by UUID DEFAULT NULL
)
RETURNS TABLE (
    campaign_id UUID,
    recipient_count INTEGER,
    estimated_segments INTEGER,
    estimated_cost NUMERIC(12, 4),
    status VARCHAR(20)
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_campaign_id UUID;
    v_recipient_count INTEGER;
    v_total_segments INTEGER := 0;
    v_cost_per_sms NUMERIC(10, 4) := 0.008;
    v_recipient JSONB;
    v_msisdn VARCHAR(20);
    v_vars JSONB;
    v_segment_count INTEGER;
    v_message_length INTEGER;
BEGIN
    -- Validate recipients
    v_recipient_count := jsonb_array_length(p_recipients);
    
    IF v_recipient_count = 0 THEN
        RETURN QUERY SELECT 
            NULL::UUID, 
            0::INTEGER, 
            0::INTEGER, 
            0::NUMERIC(12, 4), 
            'failed'::VARCHAR(20);
        RETURN;
    END IF;
    
    -- Create campaign
    INSERT INTO messaging.sms_bulk_campaigns (
        campaign_code,
        campaign_name,
        application_id,
        message_text,
        template_id,
        recipient_count,
        rate_limit_per_minute,
        scheduled_at,
        status,
        created_by
    ) VALUES (
        'CAMP-' || EXTRACT(EPOCH FROM NOW())::BIGINT::TEXT,
        p_campaign_name,
        p_application_id,
        p_message_text,
        p_template_id,
        v_recipient_count,
        p_rate_limit_per_minute,
        p_scheduled_at,
        CASE WHEN p_scheduled_at IS NOT NULL THEN 'scheduled' ELSE 'sending' END,
        p_created_by
    )
    RETURNING sms_bulk_campaigns.campaign_id INTO v_campaign_id;
    
    -- Insert recipients
    FOR v_recipient IN SELECT * FROM jsonb_array_elements(p_recipients) LOOP
        v_msisdn := v_recipient->>'msisdn';
        v_vars := v_recipient->'vars';
        
        -- Calculate message length with variables
        IF v_vars IS NOT NULL THEN
            DECLARE
                v_key TEXT;
                v_value TEXT;
                v_temp_message TEXT := p_message_text;
            BEGIN
                FOR v_key, v_value IN SELECT * FROM jsonb_each_text(v_vars) LOOP
                    v_temp_message := REPLACE(v_temp_message, '{{' || v_key || '}}', v_value);
                END LOOP;
                v_message_length := LENGTH(v_temp_message);
            END;
        ELSE
            v_message_length := LENGTH(p_message_text);
        END IF;
        
        -- Calculate segments
        IF p_message_text ~ '[^\x00-\x7F]' THEN
            v_segment_count := CEIL(v_message_length::NUMERIC / 70);
        ELSE
            v_segment_count := CEIL(v_message_length::NUMERIC / 160);
        END IF;
        
        v_total_segments := v_total_segments + v_segment_count;
        
        INSERT INTO messaging.sms_bulk_recipients (
            campaign_id,
            msisdn,
            personalization_data,
            status
        ) VALUES (
            v_campaign_id,
            v_msisdn,
            v_vars,
            'pending'
        );
    END LOOP;
    
    RETURN QUERY SELECT 
        v_campaign_id, 
        v_recipient_count, 
        v_total_segments, 
        (v_total_segments * v_cost_per_sms)::NUMERIC(12, 4),
        CASE WHEN p_scheduled_at IS NOT NULL THEN 'scheduled'::VARCHAR(20) ELSE 'sending'::VARCHAR(20) END;
        
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 
        NULL::UUID, 
        0::INTEGER, 
        0::INTEGER, 
        0::NUMERIC(12, 4), 
        'failed'::VARCHAR(20);
END;
$$;

COMMENT ON FUNCTION messaging.send_bulk_sms IS 'Send bulk SMS campaign via Africa\'s Talking';

-- Function: Process SMS delivery receipt
CREATE OR REPLACE FUNCTION messaging.process_sms_delivery_receipt(
    p_at_message_id VARCHAR(100),
    p_status VARCHAR(30),
    p_network_code VARCHAR(20) DEFAULT NULL,
    p_failure_reason TEXT DEFAULT NULL,
    p_raw_webhook_data JSONB DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_message_id UUID;
BEGIN
    -- Find message by AT message ID
    SELECT message_id INTO v_message_id
    FROM messaging.sms_messages
    WHERE at_message_id = p_at_message_id;
    
    IF v_message_id IS NULL THEN
        -- Message not found - insert receipt anyway for audit
        INSERT INTO messaging.sms_delivery_receipts (
            message_id,
            at_message_id,
            at_status,
            at_network_code,
            at_failure_reason,
            delivery_status,
            raw_webhook_data,
            processed
        ) VALUES (
            NULL,
            p_at_message_id,
            p_status,
            p_network_code,
            p_failure_reason,
            CASE 
                WHEN p_status = 'Delivered' THEN 'delivered'
                WHEN p_status = 'Sent' THEN 'sent'
                WHEN p_status = 'Rejected' THEN 'rejected'
                WHEN p_status = 'Failed' THEN 'failed'
                ELSE 'sent'
            END,
            p_raw_webhook_data,
            FALSE
        );
        RETURN FALSE;
    END IF;
    
    -- Insert delivery receipt
    INSERT INTO messaging.sms_delivery_receipts (
        message_id,
        at_message_id,
        at_status,
        at_network_code,
        at_failure_reason,
        delivery_status,
        delivered_at,
        raw_webhook_data,
        processed
    ) VALUES (
        v_message_id,
        p_at_message_id,
        p_status,
        p_network_code,
        p_failure_reason,
        CASE 
            WHEN p_status = 'Delivered' THEN 'delivered'
            WHEN p_status = 'Sent' THEN 'sent'
            WHEN p_status = 'Rejected' THEN 'rejected'
            WHEN p_status = 'Failed' THEN 'failed'
            ELSE 'sent'
        END,
        CASE WHEN p_status = 'Delivered' THEN NOW() ELSE NULL END,
        p_raw_webhook_data,
        TRUE
    );
    
    -- Update message status
    UPDATE messaging.sms_messages
    SET 
        status = CASE 
            WHEN p_status = 'Delivered' THEN 'delivered'
            WHEN p_status = 'Sent' THEN 'sent'
            WHEN p_status = 'Rejected' THEN 'rejected'
            WHEN p_status = 'Failed' THEN 'failed'
            ELSE status
        END,
        delivered_at = CASE WHEN p_status = 'Delivered' THEN NOW() ELSE delivered_at END,
        failed_at = CASE WHEN p_status IN ('Failed', 'Rejected') THEN NOW() ELSE failed_at END,
        failure_reason = CASE WHEN p_status IN ('Failed', 'Rejected') THEN p_failure_reason ELSE failure_reason END,
        updated_at = NOW()
    WHERE message_id = v_message_id;
    
    RETURN TRUE;
END;
$$;

COMMENT ON FUNCTION messaging.process_sms_delivery_receipt IS 'Process SMS delivery receipt from Africa\'s Talking';

-- =============================================================================
-- WHATSAPP FUNCTIONS
-- =============================================================================

-- Function: Send WhatsApp message
CREATE OR REPLACE FUNCTION messaging.send_whatsapp(
    p_application_id UUID,
    p_recipient_msisdn VARCHAR(20),
    p_message_type VARCHAR(30) DEFAULT 'text',
    p_text_body TEXT DEFAULT NULL,
    p_template_id UUID DEFAULT NULL,
    p_template_parameters JSONB DEFAULT NULL,
    p_media_url TEXT DEFAULT NULL,
    p_media_caption TEXT DEFAULT NULL,
    p_interactive_content JSONB DEFAULT NULL,
    p_session_id UUID DEFAULT NULL,
    p_created_by UUID DEFAULT NULL
)
RETURNS TABLE (
    message_id UUID,
    status VARCHAR(30),
    is_template BOOLEAN,
    estimated_cost NUMERIC(10, 4),
    error_message TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_message_id UUID;
    v_provider_adapter_id UUID;
    v_whatsapp_business_id VARCHAR(100);
    v_phone_number_id VARCHAR(100);
    v_session_expires_at TIMESTAMPTZ;
    v_is_within_session BOOLEAN;
    v_is_template BOOLEAN;
    v_template_name VARCHAR(100);
    v_template_language VARCHAR(10);
    v_pricing_category VARCHAR(20);
    v_cost NUMERIC(10, 4);
BEGIN
    -- Validate MSISDN
    IF p_recipient_msisdn !~ '^\+[1-9][0-9]{7,14}$' THEN
        RETURN QUERY SELECT 
            NULL::UUID, 
            'failed'::VARCHAR(30), 
            FALSE, 
            0::NUMERIC(10, 4), 
            'Invalid MSISDN format'::TEXT;
        RETURN;
    END IF;
    
    -- Get WhatsApp provider config
    SELECT 
        pa.adapter_id,
        pa.provider_config->>'whatsapp'->>'whatsapp_business_id',
        pa.provider_config->>'whatsapp'->>'phone_number_id'
    INTO v_provider_adapter_id, v_whatsapp_business_id, v_phone_number_id
    FROM ussd.provider_adapters pa
    WHERE pa.provider_name = 'africas_talking'
      AND pa.is_active = TRUE
    LIMIT 1;
    
    IF v_whatsapp_business_id IS NULL THEN
        RETURN QUERY SELECT 
            NULL::UUID, 
            'failed'::VARCHAR(30), 
            FALSE, 
            0::NUMERIC(10, 4), 
            'WhatsApp not configured for this provider'::TEXT;
        RETURN;
    END IF;
    
    -- Check for active session (24-hour window)
    SELECT 
        ws.window_expires_at,
        ws.window_expires_at > NOW(),
        ws.session_id
    INTO v_session_expires_at, v_is_within_session, p_session_id
    FROM messaging.whatsapp_sessions ws
    WHERE ws.contact_msisdn = p_recipient_msisdn
      AND ws.whatsapp_business_id = v_whatsapp_business_id
      AND ws.is_window_open = TRUE
    ORDER BY ws.window_expires_at DESC
    LIMIT 1;
    
    -- Determine if template is required
    v_is_template := (v_is_within_session IS NULL OR v_is_within_session = FALSE);
    
    -- If outside session, template is mandatory
    IF v_is_template AND p_template_id IS NULL THEN
        RETURN QUERY SELECT 
            NULL::UUID, 
            'failed'::VARCHAR(30), 
            TRUE, 
            0::NUMERIC(10, 4), 
            'Template required for business-initiated messages outside 24h window'::TEXT;
        RETURN;
    END IF;
    
    -- Get template details if using template
    IF p_template_id IS NOT NULL THEN
        SELECT 
            wa_template_name,
            language_code,
            CASE 
                WHEN category = 'MARKETING' THEN 'business_initiated'
                WHEN category = 'AUTHENTICATION' THEN 'authentication'
                ELSE 'utility'
            END
        INTO v_template_name, v_template_language, v_pricing_category
        FROM messaging.whatsapp_templates
        WHERE template_id = p_template_id
          AND approval_status = 'approved'
          AND is_active = TRUE;
        
        IF v_template_name IS NULL THEN
            RETURN QUERY SELECT 
                NULL::UUID, 
                'failed'::VARCHAR(30), 
                TRUE, 
                0::NUMERIC(10, 4), 
                'Template not found, not approved, or inactive'::TEXT;
            RETURN;
        END IF;
    ELSE
        v_pricing_category := 'user_initiated';
    END IF;
    
    -- Calculate cost based on pricing category
    v_cost := CASE v_pricing_category
        WHEN 'user_initiated' THEN 0.005
        WHEN 'business_initiated' THEN 0.008
        WHEN 'authentication' THEN 0.004
        WHEN 'utility' THEN 0.006
        ELSE 0.008
    END;
    
    -- Insert message
    INSERT INTO messaging.whatsapp_messages (
        direction,
        application_id,
        whatsapp_business_id,
        phone_number_id,
        recipient_msisdn,
        message_type,
        text_body,
        template_id,
        template_name,
        template_language,
        template_parameters,
        media_url,
        media_caption,
        interactive_content,
        session_id,
        session_expires_at,
        is_within_session,
        provider_adapter_id,
        status,
        cost,
        currency,
        pricing_category,
        created_by
    ) VALUES (
        'outbound',
        p_application_id,
        v_whatsapp_business_id,
        v_phone_number_id,
        p_recipient_msisdn,
        p_message_type,
        p_text_body,
        p_template_id,
        v_template_name,
        v_template_language,
        p_template_parameters,
        p_media_url,
        p_media_caption,
        p_interactive_content,
        p_session_id,
        v_session_expires_at,
        COALESCE(v_is_within_session, FALSE),
        v_provider_adapter_id,
        'pending',
        v_cost,
        'USD',
        v_pricing_category,
        p_created_by
    )
    RETURNING whatsapp_messages.message_id INTO v_message_id;
    
    RETURN QUERY SELECT 
        v_message_id, 
        'pending'::VARCHAR(30), 
        v_is_template, 
        v_cost, 
        NULL::TEXT;
        
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 
        NULL::UUID, 
        'failed'::VARCHAR(30), 
        FALSE, 
        0::NUMERIC(10, 4), 
        SQLERRM::TEXT;
END;
$$;

COMMENT ON FUNCTION messaging.send_whatsapp IS 'Send WhatsApp message via Africa\'s Talking';

-- Function: Process WhatsApp webhook
CREATE OR REPLACE FUNCTION messaging.process_whatsapp_webhook(
    p_webhook_type VARCHAR(30),
    p_raw_payload JSONB,
    p_source_ip INET DEFAULT NULL,
    p_signature_valid BOOLEAN DEFAULT NULL
)
RETURNS TABLE (
    webhook_id UUID,
    processed BOOLEAN,
    message_id UUID,
    error_message TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_webhook_id UUID;
    v_message_id UUID;
    v_from_msisdn VARCHAR(20);
    v_wa_message_id VARCHAR(100);
    v_message_type VARCHAR(30);
    v_text_body TEXT;
    v_whatsapp_business_id VARCHAR(100);
    v_phone_number_id VARCHAR(100);
    v_application_id UUID;
    v_session_id UUID;
BEGIN
    -- Insert webhook record
    INSERT INTO messaging.whatsapp_webhooks (
        webhook_type,
        raw_payload,
        source_ip,
        signature_valid
    ) VALUES (
        p_webhook_type,
        p_raw_payload,
        p_source_ip,
        p_signature_valid
    )
    RETURNING whatsapp_webhooks.webhook_id INTO v_webhook_id;
    
    -- Process based on webhook type
    IF p_webhook_type = 'message' THEN
        -- Extract message data
        v_from_msisdn := p_raw_payload->>'from';
        v_wa_message_id := p_raw_payload->>'id';
        v_message_type := COALESCE(p_raw_payload->>'type', 'text');
        v_text_body := p_raw_payload->'text'->>'body';
        v_whatsapp_business_id := p_raw_payload->'metadata'->>'phone_number_id';
        
        -- Find application by WhatsApp business ID
        SELECT pa.provider_config->>'whatsapp'->>'application_id'
        INTO v_application_id
        FROM ussd.provider_adapters pa
        WHERE pa.provider_config->>'whatsapp'->>'phone_number_id' = v_whatsapp_business_id
        LIMIT 1;
        
        IF v_application_id IS NULL THEN
            RETURN QUERY SELECT v_webhook_id, FALSE, NULL::UUID, 'Application not found for WhatsApp business ID'::TEXT;
            RETURN;
        END IF;
        
        -- Update or create session
        INSERT INTO messaging.whatsapp_sessions (
            application_id,
            contact_msisdn,
            contact_msisdn_hash,
            whatsapp_business_id,
            phone_number_id,
            window_opens_at,
            window_expires_at,
            is_window_open,
            last_message_at,
            last_message_direction,
            inbound_count
        ) VALUES (
            v_application_id,
            v_from_msisdn,
            encode(digest(v_from_msisdn, 'sha256'), 'hex'),
            v_whatsapp_business_id,
            v_phone_number_id,
            NOW(),
            NOW() + INTERVAL '24 hours',
            TRUE,
            NOW(),
            'inbound',
            1
        )
        ON CONFLICT (application_id, contact_msisdn, whatsapp_business_id)
        DO UPDATE SET
            window_opens_at = NOW(),
            window_expires_at = NOW() + INTERVAL '24 hours',
            is_window_open = TRUE,
            last_message_at = NOW(),
            last_message_direction = 'inbound',
            inbound_count = whatsapp_sessions.inbound_count + 1,
            updated_at = NOW()
        RETURNING session_id INTO v_session_id;
        
        -- Insert message
        INSERT INTO messaging.whatsapp_messages (
            direction,
            application_id,
            session_id,
            whatsapp_business_id,
            phone_number_id,
            recipient_msisdn,
            sender_msisdn,
            message_type,
            text_body,
            wa_message_id,
            status,
            received_at,
            is_within_session,
            session_expires_at
        ) VALUES (
            'inbound',
            v_application_id,
            v_session_id,
            v_whatsapp_business_id,
            v_phone_number_id,
            v_from_msisdn,
            v_from_msisdn,
            v_message_type,
            v_text_body,
            v_wa_message_id,
            'received',
            NOW(),
            TRUE,
            NOW() + INTERVAL '24 hours'
        )
        RETURNING whatsapp_messages.message_id INTO v_message_id;
        
        -- Update webhook
        UPDATE messaging.whatsapp_webhooks
        SET processed = TRUE,
            processed_at = NOW(),
            message_record_id = v_message_id
        WHERE webhook_id = v_webhook_id;
        
        RETURN QUERY SELECT v_webhook_id, TRUE, v_message_id, NULL::TEXT;
        
    ELSIF p_webhook_type = 'status' THEN
        -- Process status update
        v_wa_message_id := p_raw_payload->>'id';
        
        UPDATE messaging.whatsapp_messages
        SET 
            status = CASE 
                WHEN p_raw_payload->>'status' = 'delivered' THEN 'delivered'
                WHEN p_raw_payload->>'status' = 'read' THEN 'read'
                WHEN p_raw_payload->>'status' = 'sent' THEN 'sent'
                WHEN p_raw_payload->>'status' = 'failed' THEN 'failed'
                ELSE status
            END,
            delivered_at = CASE WHEN p_raw_payload->>'status' = 'delivered' THEN NOW() ELSE delivered_at END,
            read_at = CASE WHEN p_raw_payload->>'status' = 'read' THEN NOW() ELSE read_at END,
            failed_at = CASE WHEN p_raw_payload->>'status' = 'failed' THEN NOW() ELSE failed_at END,
            failure_reason = CASE WHEN p_raw_payload->>'status' = 'failed' THEN p_raw_payload->>'error'->>'message' ELSE failure_reason END,
            updated_at = NOW()
        WHERE wa_message_id = v_wa_message_id
        RETURNING whatsapp_messages.message_id INTO v_message_id;
        
        UPDATE messaging.whatsapp_webhooks
        SET processed = TRUE, processed_at = NOW()
        WHERE webhook_id = v_webhook_id;
        
        RETURN QUERY SELECT v_webhook_id, TRUE, v_message_id, NULL::TEXT;
        
    ELSE
        -- Other webhook types - just log
        UPDATE messaging.whatsapp_webhooks
        SET processed = TRUE, processed_at = NOW()
        WHERE webhook_id = v_webhook_id;
        
        RETURN QUERY SELECT v_webhook_id, TRUE, NULL::UUID, NULL::TEXT;
    END IF;
    
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT v_webhook_id, FALSE, NULL::UUID, SQLERRM::TEXT;
END;
$$;

COMMENT ON FUNCTION messaging.process_whatsapp_webhook IS 'Process incoming WhatsApp webhook from Africa\'s Talking';

-- =============================================================================
-- GRANTS
-- =============================================================================

GRANT EXECUTE ON FUNCTION messaging.send_sms TO ussd_app_user;
GRANT EXECUTE ON FUNCTION messaging.send_bulk_sms TO ussd_app_user;
GRANT EXECUTE ON FUNCTION messaging.process_sms_delivery_receipt TO ussd_gateway_role;
GRANT EXECUTE ON FUNCTION messaging.send_whatsapp TO ussd_app_user;
GRANT EXECUTE ON FUNCTION messaging.process_whatsapp_webhook TO ussd_gateway_role;

COMMIT;
