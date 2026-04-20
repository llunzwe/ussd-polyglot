-- =============================================================================
-- Migration: V004__audit_event_sourcing
-- Description: Comprehensive Audit Trail and Event Sourcing
-- Dependencies: V001-V003
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- AUDIT CHANGE LOG (Row-Level Change Tracking)
-- =============================================================================

CREATE TABLE IF NOT EXISTS audit.change_log (
    audit_id UUID DEFAULT gen_random_uuid(),
    
    -- Table and operation
    table_schema VARCHAR(100) NOT NULL,
    table_name VARCHAR(100) NOT NULL,
    operation VARCHAR(10) NOT NULL 
        CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    
    -- Record identification
    record_id UUID NOT NULL,
    record_id_text TEXT, -- For non-UUID primary keys
    
    -- Change data
    old_data JSONB,
    new_data JSONB,
    changed_columns TEXT[], -- For UPDATE, list of changed column names
    
    -- Actor information
    changed_by VARCHAR(255) NOT NULL,
    changed_by_type VARCHAR(20) DEFAULT 'user' 
        CHECK (changed_by_type IN ('user', 'system', 'api', 'batch')),
    
    -- Context
    application_id UUID,
    session_id UUID,
    correlation_id VARCHAR(255),
    transaction_id BIGINT,
    
    -- Client info
    client_ip INET,
    user_agent TEXT,
    
    -- Timing
    changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Hash chain for audit integrity
    previous_hash VARCHAR(64),
    record_hash VARCHAR(64) NOT NULL,
    chain_sequence BIGINT DEFAULT nextval('core.global_event_sequence'),
    
    -- Partition key
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT pk_audit_change_log_audit_id_changed_at PRIMARY KEY (audit_id, changed_at));

-- Convert to hypertable
SELECT create_hypertable(
    'audit.change_log',
    'changed_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_audit_table 
    ON audit.change_log(table_schema, table_name, changed_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_record 
    ON audit.change_log(record_id, changed_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_operation 
    ON audit.change_log(operation, changed_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_user 
    ON audit.change_log(changed_by, changed_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_correlation 
    ON audit.change_log(correlation_id) 
    WHERE correlation_id IS NOT NULL;

COMMENT ON TABLE audit.change_log IS 'Comprehensive audit trail of all database changes';

-- =============================================================================
-- AUDIT SESSION LOG
-- =============================================================================

CREATE TABLE IF NOT EXISTS audit.session_log (
    session_log_id UUID DEFAULT gen_random_uuid(),
    
    -- Session identification
    session_id UUID NOT NULL,
    user_id UUID,
    application_id UUID,
    
    -- Session type
    session_type VARCHAR(20) NOT NULL 
        CHECK (session_type IN ('interactive', 'api', 'batch', 'system')),
    
    -- Authentication
    auth_method VARCHAR(50), -- 'password', 'api_key', 'jwt', 'oauth2'
    auth_successful BOOLEAN,
    failure_reason TEXT,
    
    -- Session timing
    session_started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    session_ended_at TIMESTAMPTZ,
    session_duration_seconds INTEGER,
    
    -- Activity summary
    total_queries INTEGER DEFAULT 0,
    total_transactions INTEGER DEFAULT 0,
    total_changes INTEGER DEFAULT 0,
    
    -- Client info
    client_ip INET,
    user_agent TEXT,
    client_application VARCHAR(100),
    
    -- Status
    session_status VARCHAR(20) DEFAULT 'active' 
        CHECK (session_status IN ('active', 'closed', 'expired', 'terminated')),
    termination_reason TEXT,
    
    -- Security
    suspicious_activity_detected BOOLEAN DEFAULT FALSE,
    suspicious_activity_details JSONB,
    
    -- Hash chain
    previous_hash VARCHAR(64),
    record_hash VARCHAR(64) NOT NULL,
    chain_sequence BIGINT DEFAULT nextval('core.global_event_sequence'),
    
    -- Partition key
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT pk_audit_session_log_session_log_id_session_started_at PRIMARY KEY (session_log_id, session_started_at));

-- Convert to hypertable
SELECT create_hypertable(
    'audit.session_log',
    'session_started_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_session_log_user 
    ON audit.session_log(user_id, session_started_at DESC);

CREATE INDEX IF NOT EXISTS idx_session_log_app 
    ON audit.session_log(application_id, session_started_at DESC);

CREATE INDEX IF NOT EXISTS idx_session_log_ip 
    ON audit.session_log(client_ip, session_started_at DESC);

COMMENT ON TABLE audit.session_log IS 'Audit log of database sessions';

-- =============================================================================
-- EVENT STORE (Event Sourcing Pattern)
-- =============================================================================

CREATE TABLE IF NOT EXISTS events.event_store (
    event_id UUID DEFAULT gen_random_uuid(),
    
    -- Event identification
    event_type VARCHAR(100) NOT NULL,
    event_version INTEGER DEFAULT 1,
    
    -- Stream identification (aggregate root)
    stream_id UUID NOT NULL,
    stream_type VARCHAR(100) NOT NULL,
    
    -- Event sequence (monotonic within stream)
    sequence_number BIGINT NOT NULL,
    
    -- Event data
    payload JSONB NOT NULL,
    metadata JSONB DEFAULT '{}',
    
    -- Causation and correlation
    correlation_id VARCHAR(255),
    causation_id UUID, -- Parent event that caused this event
    
    -- Actor
    triggered_by VARCHAR(255),
    
    -- Timing
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Optimistic concurrency
    aggregate_version BIGINT NOT NULL,
    
    -- Partition key
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE,
    
    -- Constraints
    UNIQUE (stream_id, sequence_number, recorded_at),
    CONSTRAINT pk_events_event_store_event_id_recorded_at PRIMARY KEY (event_id, recorded_at));

-- Convert to hypertable
SELECT create_hypertable(
    'events.event_store',
    'recorded_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_event_store_stream 
    ON events.event_store(stream_id, sequence_number DESC);

CREATE INDEX IF NOT EXISTS idx_event_store_type 
    ON events.event_store(event_type, recorded_at DESC);

CREATE INDEX IF NOT EXISTS idx_event_store_correlation 
    ON events.event_store(correlation_id) 
    WHERE correlation_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_event_store_causation 
    ON events.event_store(causation_id) 
    WHERE causation_id IS NOT NULL;

COMMENT ON TABLE events.event_store IS 'Event store for event sourcing pattern';

-- =============================================================================
-- STREAM SEQUENCES (For monotonic event ordering)
-- =============================================================================

CREATE TABLE IF NOT EXISTS events.stream_sequences (
    stream_id UUID PRIMARY KEY,
    stream_type VARCHAR(100) NOT NULL,
    last_sequence BIGINT DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stream_sequences_type 
    ON events.stream_sequences(stream_type);

COMMENT ON TABLE events.stream_sequences IS 'Sequence counters for event streams';

-- =============================================================================
-- EVENT PROJECTIONS (Read models)
-- =============================================================================

CREATE TABLE IF NOT EXISTS events.projections (
    projection_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Projection identification
    projection_name VARCHAR(100) NOT NULL UNIQUE,
    projection_type VARCHAR(50) NOT NULL,
    
    -- Status
    status VARCHAR(20) DEFAULT 'active' 
        CHECK (status IN ('active', 'paused', 'rebuilding', 'failed')),
    
    -- Event processing position
    last_processed_event_id UUID,
    last_processed_sequence BIGINT DEFAULT 0,
    last_processed_at TIMESTAMPTZ,
    
    -- Statistics
    total_events_processed INTEGER DEFAULT 0,
    total_failures INTEGER DEFAULT 0,
    
    -- Configuration
    handler_configuration JSONB DEFAULT '{}',
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE events.projections IS 'Event projection tracking for read models';

-- =============================================================================
-- HASH COMPUTATION TRIGGERS
-- =============================================================================

CREATE OR REPLACE FUNCTION audit.compute_change_log_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.record_hash := core.generate_row_hash(
        'audit.change_log',
        NEW.audit_id,
        jsonb_build_object(
            'table_schema', NEW.table_schema,
            'table_name', NEW.table_name,
            'operation', NEW.operation,
            'record_id', NEW.record_id
        ),
        NEW.changed_at,
        NEW.previous_hash
    );
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_change_log_compute_hash
    BEFORE INSERT ON audit.change_log
    FOR EACH ROW
    EXECUTE FUNCTION audit.compute_change_log_hash();

CREATE OR REPLACE FUNCTION audit.compute_session_log_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.record_hash := core.generate_row_hash(
        'audit.session_log',
        NEW.session_log_id,
        jsonb_build_object(
            'session_id', NEW.session_id,
            'user_id', NEW.user_id,
            'session_type', NEW.session_type
        ),
        NEW.session_started_at,
        NEW.previous_hash
    );
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_session_log_compute_hash
    BEFORE INSERT ON audit.session_log
    FOR EACH ROW
    EXECUTE FUNCTION audit.compute_session_log_hash();

-- =============================================================================
-- WORM TRIGGERS (with TRUNCATE protection)
-- =============================================================================

CREATE TRIGGER trg_change_log_prevent_update
    BEFORE UPDATE ON audit.change_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_change_log_prevent_delete
    BEFORE DELETE ON audit.change_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

CREATE TRIGGER trg_change_log_prevent_truncate
    BEFORE TRUNCATE ON audit.change_log
    FOR EACH STATEMENT
    EXECUTE FUNCTION core.prevent_truncate();

CREATE TRIGGER trg_session_log_prevent_update
    BEFORE UPDATE ON audit.session_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_session_log_prevent_delete
    BEFORE DELETE ON audit.session_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

CREATE TRIGGER trg_session_log_prevent_truncate
    BEFORE TRUNCATE ON audit.session_log
    FOR EACH STATEMENT
    EXECUTE FUNCTION core.prevent_truncate();

CREATE TRIGGER trg_event_store_prevent_update
    BEFORE UPDATE ON events.event_store
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_event_store_prevent_delete
    BEFORE DELETE ON events.event_store
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

CREATE TRIGGER trg_event_store_prevent_truncate
    BEFORE TRUNCATE ON events.event_store
    FOR EACH STATEMENT
    EXECUTE FUNCTION core.prevent_truncate();

-- =============================================================================
-- AUDIT CAPTURE TRIGGER FUNCTION
-- =============================================================================

CREATE OR REPLACE FUNCTION audit.auto_capture_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_old_data JSONB;
    v_new_data JSONB;
    v_changed_columns TEXT[] := ARRAY[]::TEXT[];
    v_column TEXT;
    v_audit_id UUID;
BEGIN
    -- Determine changed data based on operation
    IF TG_OP = 'DELETE' THEN
        v_old_data := TO_JSONB(OLD);
        v_new_data := NULL;
    ELSIF TG_OP = 'INSERT' THEN
        v_old_data := NULL;
        v_new_data := TO_JSONB(NEW);
    ELSIF TG_OP = 'UPDATE' THEN
        v_old_data := TO_JSONB(OLD);
        v_new_data := TO_JSONB(NEW);
        
        -- Determine changed columns
        FOR v_column IN 
            SELECT jsonb_object_keys(v_new_data)
        LOOP
            IF v_old_data->v_column IS DISTINCT FROM v_new_data->v_column THEN
                v_changed_columns := array_append(v_changed_columns, v_column);
            END IF;
        END LOOP;
    END IF;
    
    -- Insert audit record
    INSERT INTO audit.change_log (
        table_schema,
        table_name,
        operation,
        record_id,
        old_data,
        new_data,
        changed_columns,
        changed_by,
        changed_by_type,
        application_id,
        session_id,
        correlation_id,
        transaction_id,
        client_ip,
        user_agent
    ) VALUES (
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME,
        TG_OP,
        COALESCE(NEW.id, OLD.id),
        COALESCE(NEW.id, OLD.id)::TEXT,
        v_old_data,
        v_new_data,
        v_changed_columns,
        COALESCE(current_setting('app.current_user_id', TRUE), 'system'),
        COALESCE(current_setting('app.user_type', TRUE), 'system'),
        NULLIF(current_setting('app.application_id', TRUE), '')::UUID,
        NULLIF(current_setting('app.session_id', TRUE), '')::UUID,
        current_setting('app.correlation_id', TRUE),
        txid_current(),
        NULLIF(current_setting('app.client_ip', TRUE), '')::INET,
        current_setting('app.user_agent', TRUE)
    );
    
    -- Continue with original operation
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$;

COMMIT;
