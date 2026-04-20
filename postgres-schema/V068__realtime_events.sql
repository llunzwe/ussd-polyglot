-- =============================================================================
-- Migration: V068__realtime_events
-- Description: Real-time Event Streaming & Webhook Management
-- Dependencies: V001-V067
--
-- PURPOSE: Enable real-time notifications for business apps via webhooks,
-- Server-Sent Events (SSE), and CDC streams. Includes dead-letter queue
-- management and event subscription configuration.
--
-- ADR-013: Webhook Delivery Architecture
-- DECISION: At-least-once delivery with idempotency keys
-- RATIONALE:
--   - Business apps need reliable notifications for ledger events
--   - Network failures are inevitable
--   - Idempotency keys prevent duplicate processing
--   - Dead-letter queue enables manual replay
-- TRADE-OFFS:
--   (+) Reliable delivery guarantees
--   (+) Automatic retry with exponential backoff
--   (-) Apps must implement idempotency handling
--   (-) Slightly higher latency for delivery confirmation
--
-- ADR-014: Event Stream vs Webhook Selection
-- DECISION: Support both - webhooks for push, SSE for streaming
-- RATIONALE:
--   - Webhooks: Good for async processing, guaranteed delivery
--   - SSE: Good for real-time dashboards, lower overhead
--   - CDC: Good for data replication, analytics pipelines
-- TRADE-OFFS:
--   (+) Flexibility for different use cases
--   (-) More components to maintain
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- SCHEMA: events (extends existing events schema)
-- PURPOSE: Event streaming, webhooks, and CDC configuration
-- =============================================================================

-- Note: events schema created in earlier migration, add new tables

-- =============================================================================
-- TABLE: events.webhook_subscriptions
-- PURPOSE: Business app webhook endpoint configuration
-- SECURITY: Application-scoped via RLS
-- =============================================================================
CREATE TABLE IF NOT EXISTS events.webhook_subscriptions (
    subscription_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Application context
    application_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    
    -- Endpoint configuration
    endpoint_url VARCHAR(500) NOT NULL,
    endpoint_secret VARCHAR(255) NOT NULL, -- For HMAC signature
    
    -- Event filtering
    event_types TEXT[] NOT NULL DEFAULT ARRAY['transaction.completed'], -- Subscribed events
    
    -- Delivery configuration
    http_method VARCHAR(10) DEFAULT 'POST' CHECK (http_method IN ('POST', 'PUT')),
    headers JSONB DEFAULT '{}', -- Custom headers to include
    
    -- Retry configuration
    max_retries INTEGER DEFAULT 3,
    retry_backoff_seconds INTEGER[] DEFAULT ARRAY[5, 25, 125], -- Exponential backoff
    timeout_seconds INTEGER DEFAULT 30,
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    deactivated_at TIMESTAMPTZ,
    deactivation_reason TEXT,
    
    -- Health tracking
    last_success_at TIMESTAMPTZ,
    last_failure_at TIMESTAMPTZ,
    failure_count INTEGER DEFAULT 0,
    consecutive_failures INTEGER DEFAULT 0,
    
    -- Rate limiting
    rate_limit_rps INTEGER DEFAULT 10, -- Requests per second
    
    -- Audit
    created_by UUID REFERENCES core.account_registry(account_id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_webhook_subscriptions_app ON events.webhook_subscriptions(application_id, is_active);
CREATE INDEX IF NOT EXISTS idx_webhook_subscriptions_events ON events.webhook_subscriptions USING GIN(event_types);

COMMENT ON TABLE events.webhook_subscriptions IS 
'Business app webhook endpoint subscriptions for ledger event notifications';

-- =============================================================================
-- TABLE: events.webhook_deliveries
-- PURPOSE: Delivery attempt log for webhooks
-- SECURITY: Application-scoped via RLS
-- =============================================================================
CREATE TABLE IF NOT EXISTS events.webhook_deliveries (
    delivery_id UUID DEFAULT gen_random_uuid(),
    
    -- References
    subscription_id UUID NOT NULL REFERENCES events.webhook_subscriptions(subscription_id),
    
    -- Event data
    event_type VARCHAR(100) NOT NULL,
    event_id UUID NOT NULL, -- Reference to triggering record
    event_data JSONB NOT NULL, -- Payload sent
    
    -- Idempotency
    idempotency_key VARCHAR(100) NOT NULL,
    
    -- Delivery attempt
    attempt_number INTEGER DEFAULT 1,
    
    -- Request details
    request_body JSONB,
    request_headers JSONB,
    
    -- Response details
    response_status INTEGER,
    response_body TEXT,
    response_headers JSONB,
    response_time_ms INTEGER,
    
    -- Status
    status VARCHAR(20) NOT NULL 
        CHECK (status IN ('pending', 'delivered', 'failed', 'retrying')),
    
    -- Timing
    scheduled_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    sent_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    
    -- Error handling
    error_message TEXT,
    will_retry BOOLEAN DEFAULT FALSE,
    next_retry_at TIMESTAMPTZ,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_events_webhook_deliveries_delivery_id_created_at PRIMARY KEY (delivery_id, created_at));

-- Convert to hypertable
SELECT create_hypertable(
    'events.webhook_deliveries',
    'created_at',
    chunk_time_interval => INTERVAL '7 days',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_subscription ON events.webhook_deliveries(subscription_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_status ON events.webhook_deliveries(status, next_retry_at) 
    WHERE status IN ('pending', 'retrying');
CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_event ON events.webhook_deliveries(event_id, event_type);
CREATE UNIQUE INDEX IF NOT EXISTS idx_webhook_deliveries_idempotent 
    ON events.webhook_deliveries(subscription_id, idempotency_key);

COMMENT ON TABLE events.webhook_deliveries IS 
'Webhook delivery attempt log with retry tracking and idempotency';

-- =============================================================================
-- TABLE: events.dead_letter_queue (extends existing DLQ in V004)
-- PURPOSE: Failed webhook events requiring manual intervention
-- SECURITY: Application-scoped via RLS
-- =============================================================================
CREATE TABLE IF NOT EXISTS events.webhook_dlq (
    dlq_id UUID DEFAULT gen_random_uuid(),
    
    -- Original delivery reference
    delivery_id UUID,
    subscription_id UUID NOT NULL REFERENCES events.webhook_subscriptions(subscription_id),
    
    -- Event data (preserved for replay)
    event_type VARCHAR(100) NOT NULL,
    event_id UUID NOT NULL,
    event_data JSONB NOT NULL,
    idempotency_key VARCHAR(100) NOT NULL,
    
    -- Failure context
    failure_reason TEXT NOT NULL,
    failure_count INTEGER DEFAULT 1,
    last_error TEXT,
    
    -- Replay tracking
    replay_count INTEGER DEFAULT 0,
    last_replay_at TIMESTAMPTZ,
    
    -- Resolution
    status VARCHAR(20) DEFAULT 'failed' 
        CHECK (status IN ('failed', 'replaying', 'discarded', 'resolved')),
    resolved_at TIMESTAMPTZ,
    resolved_by UUID REFERENCES core.account_registry(account_id),
    resolution_notes TEXT,
    
    -- Audit
    failed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_events_webhook_dlq_dlq_id_failed_at PRIMARY KEY (dlq_id, failed_at));

-- Convert to hypertable
SELECT create_hypertable(
    'events.webhook_dlq',
    'failed_at',
    chunk_time_interval => INTERVAL '30 days',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_webhook_dlq_subscription ON events.webhook_dlq(subscription_id, status);
CREATE INDEX IF NOT EXISTS idx_webhook_dlq_failed ON events.webhook_dlq(status, failed_at) 
    WHERE status = 'failed';
CREATE INDEX IF NOT EXISTS idx_webhook_dlq_event ON events.webhook_dlq(event_id, event_type);

COMMENT ON TABLE events.webhook_dlq IS 
'Dead-letter queue for failed webhook deliveries with manual replay capability';

-- =============================================================================
-- TABLE: events.event_stream_subscriptions
-- PURPOSE: Server-Sent Events (SSE) subscription management
-- SECURITY: Application-scoped via RLS
-- =============================================================================
CREATE TABLE IF NOT EXISTS events.event_stream_subscriptions (
    stream_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Application context
    application_id UUID NOT NULL REFERENCES app.application_registry(application_id),
    
    -- Connection info
    client_id VARCHAR(255) NOT NULL, -- SDK client identifier
    connection_token VARCHAR(255) NOT NULL UNIQUE, -- For connection auth
    
    -- Event filtering
    event_types TEXT[] NOT NULL DEFAULT ARRAY['*'], -- ['*'] for all
    filters JSONB, -- {account_id, transaction_type, min_amount}
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    connected_at TIMESTAMPTZ DEFAULT NOW(),
    last_heartbeat_at TIMESTAMPTZ DEFAULT NOW(),
    disconnected_at TIMESTAMPTZ,
    
    -- Rate limiting
    events_per_second INTEGER DEFAULT 100,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_event_streams_app ON events.event_stream_subscriptions(application_id, is_active);
CREATE INDEX IF NOT EXISTS idx_event_streams_token ON events.event_stream_subscriptions(connection_token);
CREATE INDEX IF NOT EXISTS idx_event_streams_heartbeat ON events.event_stream_subscriptions(last_heartbeat_at) 
    WHERE is_active = TRUE;

COMMENT ON TABLE events.event_stream_subscriptions IS 
'Server-Sent Events (SSE) connection management for real-time streaming';

-- =============================================================================
-- TABLE: events.cdc_topics
-- PURPOSE: Change Data Capture topic configuration for Kafka/RabbitMQ
-- SECURITY: Admin only
-- =============================================================================
CREATE TABLE IF NOT EXISTS events.cdc_topics (
    topic_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Topic configuration
    topic_name VARCHAR(100) UNIQUE NOT NULL,
    broker_type VARCHAR(20) NOT NULL CHECK (broker_type IN ('kafka', 'rabbitmq', 'sqs')),
    broker_config JSONB NOT NULL, -- {host, port, topic, credentials_ref}
    
    -- Event filtering
    table_filter VARCHAR(100)[] NOT NULL, -- ['core.transactions', 'core.accounts']
    operation_filter VARCHAR(20)[] DEFAULT ARRAY['INSERT', 'UPDATE'], -- Skip DELETE
    
    -- Transformation
    message_format VARCHAR(20) DEFAULT 'json' CHECK (message_format IN ('json', 'avro', 'protobuf')),
    transformation_rules JSONB, -- Field mapping, masking
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    
    -- Health
    last_published_at TIMESTAMPTZ,
    message_count BIGINT DEFAULT 0,
    error_count INTEGER DEFAULT 0,
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cdc_topics_name ON events.cdc_topics(topic_name);
CREATE INDEX IF NOT EXISTS idx_cdc_topics_active ON events.cdc_topics(is_active, broker_type);

COMMENT ON TABLE events.cdc_topics IS 
'Change Data Capture topic configuration for external message brokers';

-- =============================================================================
-- TABLE: events.cdc_outbox
-- PURPOSE: Outbox pattern for reliable CDC publishing
-- SECURITY: Internal only
-- =============================================================================
CREATE TABLE IF NOT EXISTS events.cdc_outbox (
    outbox_id UUID DEFAULT gen_random_uuid(),
    
    -- Event data
    topic_id UUID NOT NULL REFERENCES events.cdc_topics(topic_id),
    
    -- Payload
    aggregate_type VARCHAR(100) NOT NULL, -- e.g., 'transaction'
    aggregate_id UUID NOT NULL,
    event_type VARCHAR(100) NOT NULL, -- e.g., 'TransactionCompleted'
    payload JSONB NOT NULL,
    headers JSONB, -- Metadata
    
    -- Publishing
    sequence_number BIGINT, -- For ordering
    published BOOLEAN DEFAULT FALSE,
    published_at TIMESTAMPTZ,
    publish_error TEXT,
    
    -- Retry
    retry_count INTEGER DEFAULT 0,
    next_retry_at TIMESTAMPTZ,
    
    -- Partitioning
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_events_cdc_outbox_outbox_id_created_at PRIMARY KEY (outbox_id, created_at));

-- Convert to hypertable
SELECT create_hypertable(
    'events.cdc_outbox',
    'created_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_cdc_outbox_unpublished ON events.cdc_outbox(published, next_retry_at) 
    WHERE published = FALSE;
CREATE INDEX IF NOT EXISTS idx_cdc_outbox_aggregate ON events.cdc_outbox(aggregate_type, aggregate_id);

COMMENT ON TABLE events.cdc_outbox IS 
'Outbox table for reliable CDC event publishing (outbox pattern)';

-- =============================================================================
-- FUNCTIONS: Event Processing
-- =============================================================================

-- Function: Queue webhook delivery
CREATE OR REPLACE FUNCTION events.queue_webhook_delivery(
    p_subscription_id UUID,
    p_event_type VARCHAR,
    p_event_id UUID,
    p_event_data JSONB
)
RETURNS UUID AS $$
DECLARE
    v_delivery_id UUID;
    v_idempotency_key VARCHAR(100);
BEGIN
    -- Generate idempotency key
    v_idempotency_key := encode(gen_random_bytes(16), 'hex');
    
    INSERT INTO events.webhook_deliveries (
        subscription_id,
        event_type,
        event_id,
        event_data,
        idempotency_key,
        status
    ) VALUES (
        p_subscription_id,
        p_event_type,
        p_event_id,
        p_event_data,
        v_idempotency_key,
        'pending'
    )
    RETURNING delivery_id INTO v_delivery_id;
    
    RETURN v_delivery_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION events.queue_webhook_delivery(UUID, VARCHAR, UUID, JSONB) IS 
'Queues a webhook delivery for async processing';

-- Function: Move failed delivery to DLQ
CREATE OR REPLACE FUNCTION events.move_to_dlq(
    p_delivery_id UUID,
    p_failure_reason TEXT
)
RETURNS UUID AS $$
DECLARE
    v_dlq_id UUID;
    v_delivery RECORD;
BEGIN
    -- Get delivery details
    SELECT * INTO v_delivery
    FROM events.webhook_deliveries
    WHERE delivery_id = p_delivery_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Delivery % not found', p_delivery_id;
    END IF;
    
    -- Insert to DLQ
    INSERT INTO events.webhook_dlq (
        delivery_id,
        subscription_id,
        event_type,
        event_id,
        event_data,
        idempotency_key,
        failure_reason,
        last_error
    ) VALUES (
        p_delivery_id,
        v_delivery.subscription_id,
        v_delivery.event_type,
        v_delivery.event_id,
        v_delivery.event_data,
        v_delivery.idempotency_key,
        p_failure_reason,
        v_delivery.error_message
    )
    RETURNING dlq_id INTO v_dlq_id;
    
    -- Update delivery status
    UPDATE events.webhook_deliveries
    SET status = 'failed',
        completed_at = NOW()
    WHERE delivery_id = p_delivery_id;
    
    RETURN v_dlq_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION events.move_to_dlq(UUID, TEXT) IS 
'Moves a failed webhook delivery to the dead-letter queue';

-- Function: Replay DLQ item
CREATE OR REPLACE FUNCTION events.replay_dlq_item(
    p_dlq_id UUID,
    p_resolved_by UUID
)
RETURNS UUID AS $$
DECLARE
    v_new_delivery_id UUID;
    v_dlq RECORD;
BEGIN
    -- Get DLQ item
    SELECT * INTO v_dlq
    FROM events.webhook_dlq
    WHERE dlq_id = p_dlq_id AND status = 'failed';
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DLQ item % not found or not in failed state', p_dlq_id;
    END IF;
    
    -- Create new delivery
    v_new_delivery_id := events.queue_webhook_delivery(
        v_dlq.subscription_id,
        v_dlq.event_type,
        v_dlq.event_id,
        v_dlq.event_data
    );
    
    -- Update DLQ status
    UPDATE events.webhook_dlq
    SET status = 'replaying',
        replay_count = replay_count + 1,
        last_replay_at = NOW()
    WHERE dlq_id = p_dlq_id;
    
    RETURN v_new_delivery_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION events.replay_dlq_item(UUID, UUID) IS 
'Replays a failed webhook delivery from the dead-letter queue';

-- Function: Record CDC outbox event
CREATE OR REPLACE FUNCTION events.record_cdc_event()
RETURNS TRIGGER AS $$
DECLARE
    v_topic_id UUID;
    v_event_type VARCHAR(100);
    v_payload JSONB;
BEGIN
    -- Determine event type
    v_event_type := TG_TABLE_NAME || CASE TG_OP 
        WHEN 'INSERT' THEN 'Created'
        WHEN 'UPDATE' THEN 'Updated'
        WHEN 'DELETE' THEN 'Deleted'
    END;
    
    -- Build payload
    IF TG_OP = 'DELETE' THEN
        v_payload := to_jsonb(OLD);
    ELSE
        v_payload := to_jsonb(NEW);
    END IF;
    
    -- Insert to outbox for each matching topic
    FOR v_topic_id IN 
        SELECT topic_id FROM events.cdc_topics
        WHERE is_active = TRUE
          AND TG_TABLE_NAME = ANY(table_filter)
          AND (operation_filter IS NULL OR TG_OP = ANY(operation_filter))
    LOOP
        INSERT INTO events.cdc_outbox (
            topic_id,
            aggregate_type,
            aggregate_id,
            event_type,
            payload
        ) VALUES (
            v_topic_id,
            TG_TABLE_NAME,
            CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END,
            v_event_type,
            v_payload
        );
    END LOOP;
    
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION events.record_cdc_event() IS 
'Trigger function to record CDC events to outbox table';

-- =============================================================================
-- RLS POLICIES
-- =============================================================================

DO $$
BEGIN
    ALTER TABLE events.webhook_subscriptions ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE events.webhook_subscriptions FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE events.webhook_deliveries ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE events.webhook_deliveries FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE events.webhook_dlq ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE events.webhook_dlq FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE events.event_stream_subscriptions ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE events.event_stream_subscriptions FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE events.cdc_topics ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;
DO $$
BEGIN
    ALTER TABLE events.cdc_outbox ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- Application isolation
CREATE POLICY webhook_subscriptions_app_isolation ON events.webhook_subscriptions
    FOR ALL
    TO ussd_app_user
    USING (application_id = current_setting('app.current_application_id', true)::UUID);

CREATE POLICY webhook_deliveries_app_isolation ON events.webhook_deliveries
    FOR ALL
    TO ussd_app_user
    USING (subscription_id IN (
        SELECT subscription_id FROM events.webhook_subscriptions
        WHERE application_id = current_setting('app.current_application_id', true)::UUID
    ));

CREATE POLICY webhook_dlq_app_isolation ON events.webhook_dlq
    FOR ALL
    TO ussd_app_user
    USING (subscription_id IN (
        SELECT subscription_id FROM events.webhook_subscriptions
        WHERE application_id = current_setting('app.current_application_id', true)::UUID
    ));

CREATE POLICY event_streams_app_isolation ON events.event_stream_subscriptions
    FOR ALL
    TO ussd_app_user
    USING (application_id = current_setting('app.current_application_id', true)::UUID);

-- CDC is admin only
CREATE POLICY cdc_topics_admin ON events.cdc_topics
    FOR ALL
    TO ussd_app_user
    USING (FALSE);

CREATE POLICY cdc_outbox_internal ON events.cdc_outbox
    FOR ALL
    TO ussd_app_user
    USING (FALSE);

-- =============================================================================
-- WORM TRIGGERS (Immutability for delivery records)
-- =============================================================================

CREATE TRIGGER trg_webhook_deliveries_prevent_update_delivered
    BEFORE UPDATE ON events.webhook_deliveries
    FOR EACH ROW
    WHEN (OLD.status = 'delivered')
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_webhook_dlq_prevent_update_resolved
    BEFORE UPDATE ON events.webhook_dlq
    FOR EACH ROW
    WHEN (OLD.status = 'resolved')
    EXECUTE FUNCTION core.prevent_update();

-- =============================================================================
-- GRANTS
-- =============================================================================

GRANT SELECT, INSERT, UPDATE ON events.webhook_subscriptions TO ussd_app_user;
GRANT SELECT ON events.webhook_deliveries TO ussd_app_user;
GRANT SELECT, UPDATE ON events.webhook_dlq TO ussd_app_user;
GRANT SELECT, INSERT, DELETE ON events.event_stream_subscriptions TO ussd_app_user;

COMMIT;
