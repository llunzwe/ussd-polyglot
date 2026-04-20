-- =============================================================================
-- Migration: V012__observability_metrics
-- Description: Prometheus Metrics and Distributed Tracing
-- Dependencies: V001-V008
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- METRICS STORE (Prometheus-compatible)
-- =============================================================================

CREATE TABLE IF NOT EXISTS observability.metrics (
    metric_id UUID DEFAULT gen_random_uuid(),
    
    -- Metric identification
    metric_name VARCHAR(255) NOT NULL,
    metric_type VARCHAR(20) NOT NULL 
        CHECK (metric_type IN ('counter', 'gauge', 'histogram', 'summary')),
    
    -- Labels (dimensions)
    labels JSONB DEFAULT '{}',
    
    -- Metric value
    metric_value NUMERIC(20, 8) NOT NULL,
    
    -- For histograms
    bucket_le VARCHAR(50), -- Less than or equal bucket boundary
    
    -- Source
    application_id UUID,
    service_name VARCHAR(100),
    instance_id VARCHAR(100),
    
    -- Timestamp
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Partition key
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT pk_observability_metrics_metric_id_recorded_at PRIMARY KEY (metric_id, recorded_at));

-- Convert to hypertable for time-series
SELECT create_hypertable(
    'observability.metrics',
    'recorded_at',
    chunk_time_interval => INTERVAL '1 hour',
    if_not_exists => TRUE
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_metrics_name_time 
    ON observability.metrics(metric_name, recorded_at DESC);

CREATE INDEX IF NOT EXISTS idx_metrics_app 
    ON observability.metrics(application_id, metric_name, recorded_at DESC);

CREATE INDEX IF NOT EXISTS idx_metrics_labels 
    ON observability.metrics USING GIN(labels);

COMMENT ON TABLE observability.metrics IS 'Prometheus-compatible metrics storage';

-- =============================================================================
-- DISTRIBUTED TRACING (OpenTelemetry-compatible)
-- =============================================================================

CREATE TABLE IF NOT EXISTS observability.trace_spans (
    span_id UUID DEFAULT gen_random_uuid(),
    
    -- Trace context
    trace_id UUID NOT NULL,
    parent_span_id UUID,
    
    -- Span identification
    span_name VARCHAR(255) NOT NULL,
    span_kind VARCHAR(20) DEFAULT 'internal' 
        CHECK (span_kind IN ('internal', 'server', 'client', 'producer', 'consumer')),
    
    -- Service info
    service_name VARCHAR(100) NOT NULL,
    service_version VARCHAR(50),
    
    -- Timing
    start_time TIMESTAMPTZ NOT NULL,
    end_time TIMESTAMPTZ,
    duration_ms INTEGER,
    
    -- Status
    status_code VARCHAR(20) DEFAULT 'unset' 
        CHECK (status_code IN ('unset', 'ok', 'error')),
    status_message TEXT,
    
    -- Attributes
    attributes JSONB DEFAULT '{}',
    
    -- Events (span events as JSON array)
    events JSONB DEFAULT '[]',
    
    -- Links to other spans
    links JSONB DEFAULT '[]',
    
    -- Application context
    application_id UUID,
    session_id UUID,
    user_id UUID,
    
    -- Correlation
    correlation_id VARCHAR(255),
    request_id VARCHAR(255),
    
    -- Partition key
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT pk_observability_trace_spans_span_id_start_time PRIMARY KEY (span_id, start_time));

-- Convert to hypertable
SELECT create_hypertable(
    'observability.trace_spans',
    'start_time',
    chunk_time_interval => INTERVAL '1 hour',
    if_not_exists => TRUE
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_trace_spans_trace 
    ON observability.trace_spans(trace_id, start_time);

CREATE INDEX IF NOT EXISTS idx_trace_spans_service 
    ON observability.trace_spans(service_name, start_time DESC);

CREATE INDEX IF NOT EXISTS idx_trace_spans_correlation 
    ON observability.trace_spans(correlation_id) 
    WHERE correlation_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_trace_spans_session 
    ON observability.trace_spans(session_id) 
    WHERE session_id IS NOT NULL;

COMMENT ON TABLE observability.trace_spans IS 'Distributed tracing spans (OpenTelemetry-compatible)';

-- =============================================================================
-- ALERTS AND NOTIFICATIONS
-- =============================================================================

CREATE TABLE IF NOT EXISTS observability.alerts (
    alert_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Alert identification
    alert_name VARCHAR(255) NOT NULL,
    alert_severity VARCHAR(20) NOT NULL 
        CHECK (alert_severity IN ('info', 'warning', 'critical', 'emergency')),
    
    -- Alert condition
    metric_name VARCHAR(255) NOT NULL,
    condition_operator VARCHAR(10) NOT NULL 
        CHECK (condition_operator IN ('>', '<', '>=', '<=', '=', '!=')),
    threshold_value NUMERIC(20, 8) NOT NULL,
    duration_minutes INTEGER DEFAULT 5,
    
    -- Alert state
    status VARCHAR(20) DEFAULT 'firing' 
        CHECK (status IN ('firing', 'acknowledged', 'resolved', 'suppressed')),
    
    -- Alert data
    alert_value NUMERIC(20, 8) NOT NULL,
    alert_labels JSONB DEFAULT '{}',
    alert_annotations JSONB DEFAULT '{}',
    
    -- Source
    application_id UUID,
    service_name VARCHAR(100),
    
    -- Notification
    notification_channels TEXT[] DEFAULT ARRAY['email'],
    notification_sent BOOLEAN DEFAULT FALSE,
    notification_sent_at TIMESTAMPTZ,
    
    -- Acknowledgment
    acknowledged_by UUID,
    acknowledged_at TIMESTAMPTZ,
    acknowledged_note TEXT,
    
    -- Resolution
    resolved_at TIMESTAMPTZ,
    resolved_by UUID,
    resolution_note TEXT,
    
    -- Lifecycle
    starts_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ends_at TIMESTAMPTZ,
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_alerts_status 
    ON observability.alerts(status, alert_severity);

CREATE INDEX IF NOT EXISTS idx_alerts_app 
    ON observability.alerts(application_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_alerts_metric 
    ON observability.alerts(metric_name, starts_at DESC);

COMMENT ON TABLE observability.alerts IS 'Alert rules and firing alerts';

-- =============================================================================
-- ALERT RULES (Configuration)
-- =============================================================================

CREATE TABLE IF NOT EXISTS observability.alert_rules (
    rule_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Rule identification
    rule_name VARCHAR(255) NOT NULL UNIQUE,
    rule_description TEXT,
    
    -- Alert condition
    metric_name VARCHAR(255) NOT NULL,
    metric_labels JSONB DEFAULT '{}', -- Label selectors
    condition_operator VARCHAR(10) NOT NULL,
    threshold_value NUMERIC(20, 8) NOT NULL,
    duration_minutes INTEGER DEFAULT 5,
    
    -- Severity
    alert_severity VARCHAR(20) NOT NULL DEFAULT 'warning',
    
    -- Scope
    application_id UUID, -- NULL = all applications
    service_name VARCHAR(100), -- NULL = all services
    environment VARCHAR(20) DEFAULT 'production',
    
    -- Notification
    notification_channels TEXT[] DEFAULT ARRAY['email'],
    notification_template VARCHAR(100) DEFAULT 'default',
    
    -- Throttling
    repeat_interval_minutes INTEGER DEFAULT 60,
    group_by_labels TEXT[],
    
    -- Status
    is_enabled BOOLEAN DEFAULT TRUE,
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_alert_rules_metric 
    ON observability.alert_rules(metric_name, is_enabled);

CREATE INDEX IF NOT EXISTS idx_alert_rules_app 
    ON observability.alert_rules(application_id, is_enabled);

COMMENT ON TABLE observability.alert_rules IS 'Alert rule configurations';

-- =============================================================================
-- SLA TRACKING
-- =============================================================================

CREATE TABLE IF NOT EXISTS observability.sla_tracking (
    sla_id UUID DEFAULT gen_random_uuid(),
    
    -- Scope
    application_id UUID NOT NULL,
    service_name VARCHAR(100) NOT NULL,
    metric_type VARCHAR(50) NOT NULL 
        CHECK (metric_type IN ('uptime', 'latency', 'error_rate', 'availability')),
    
    -- Time window
    window_start TIMESTAMPTZ NOT NULL,
    window_end TIMESTAMPTZ NOT NULL,
    window_duration VARCHAR(20) NOT NULL, -- '1h', '1d', '1w', '1m'
    
    -- SLA targets
    target_value NUMERIC(5, 4) NOT NULL, -- e.g., 0.9995 for 99.95%
    actual_value NUMERIC(5, 4) NOT NULL,
    
    -- Status
    is_compliant BOOLEAN GENERATED ALWAYS AS (
        CASE WHEN actual_value >= target_value THEN TRUE ELSE FALSE END
    ) STORED,
    
    -- Details
    total_requests INTEGER,
    failed_requests INTEGER,
    avg_latency_ms INTEGER,
    p95_latency_ms INTEGER,
    p99_latency_ms INTEGER,
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_observability_sla_tracking_sla_id_window_start PRIMARY KEY (sla_id, window_start));

-- Convert to hypertable
SELECT create_hypertable(
    'observability.sla_tracking',
    'window_start',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_sla_tracking_app 
    ON observability.sla_tracking(application_id, service_name, window_start DESC);

CREATE INDEX IF NOT EXISTS idx_sla_tracking_compliance 
    ON observability.sla_tracking(application_id, is_compliant, window_start DESC);

COMMENT ON TABLE observability.sla_tracking IS 'SLA compliance tracking per tenant';

-- =============================================================================
-- TRIGGERS (Mixed: Audit trails are WORM, operational tables need updates)
-- =============================================================================

-- Metrics and trace spans are immutable audit data
CREATE TRIGGER trg_metrics_prevent_update
    BEFORE UPDATE ON observability.metrics
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_metrics_prevent_delete
    BEFORE DELETE ON observability.metrics
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

CREATE TRIGGER trg_metrics_prevent_truncate
    BEFORE TRUNCATE ON observability.metrics
    FOR EACH STATEMENT
    EXECUTE FUNCTION core.prevent_truncate();

CREATE TRIGGER trg_trace_spans_prevent_update
    BEFORE UPDATE ON observability.trace_spans
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_trace_spans_prevent_delete
    BEFORE DELETE ON observability.trace_spans
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

CREATE TRIGGER trg_trace_spans_prevent_truncate
    BEFORE TRUNCATE ON observability.trace_spans
    FOR EACH STATEMENT
    EXECUTE FUNCTION core.prevent_truncate();

-- SLA tracking is immutable compliance data
CREATE TRIGGER trg_sla_tracking_prevent_update
    BEFORE UPDATE ON observability.sla_tracking
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_sla_tracking_prevent_delete
    BEFORE DELETE ON observability.sla_tracking
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

CREATE TRIGGER trg_sla_tracking_prevent_truncate
    BEFORE TRUNCATE ON observability.sla_tracking
    FOR EACH STATEMENT
    EXECUTE FUNCTION core.prevent_truncate();

-- Alerts need status updates (acknowledged, resolved) - use timestamp trigger
DROP TRIGGER IF EXISTS trg_alerts_timestamp ON observability.alerts;
CREATE TRIGGER trg_alerts_timestamp
    BEFORE UPDATE ON observability.alerts
    FOR EACH ROW
    EXECUTE FUNCTION core.update_timestamp();

-- Alert rules need updates for enable/disable - use timestamp trigger  
DROP TRIGGER IF EXISTS trg_alert_rules_timestamp ON observability.alert_rules;
CREATE TRIGGER trg_alert_rules_timestamp
    BEFORE UPDATE ON observability.alert_rules
    FOR EACH ROW
    EXECUTE FUNCTION core.update_timestamp();

COMMIT;
