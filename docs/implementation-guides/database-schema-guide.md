# Database Schema Implementation Guide

**Version**: 1.0.0  
**Status**: Implementation Ready  
**Last Updated**: 2026-04-13  

---

## 1. Schema Overview

The kernel's immutable ledger service consists of **73 migrations** (V001-V073) organized into logical schemas that tenant applications use via the kernel's APIs and SDK:

```
┌─────────────────────────────────────────────────────────────┐
│                    DATABASE SCHEMAS                          │
├─────────────────────────────────────────────────────────────┤
│  core          - Immutable transaction ledger                │
│  events        - Event sourcing tables                       │
│  audit         - Audit trails and compliance                 │
│  integrity     - Hash chains and verification                │
│  ussd          - USSD session management                     │
│  app           - Application registry and config             │
│  mobile_money  - Mobile money integration                    │
│  temporal      - Bitemporal data                             │
│  observability - Metrics and monitoring                      │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Core Schema (Immutable Ledger)

### 2.1 transaction_log (V006)

**Purpose**: Central immutable table for tenant application transactions managed by the kernel

```sql
CREATE TABLE core.transaction_log (
    -- Primary identifiers
    transaction_id BIGSERIAL,
    transaction_uuid UUID NOT NULL DEFAULT gen_random_uuid(),
    idempotency_key VARCHAR(255) NOT NULL,
    
    -- Classification
    transaction_type_id UUID NOT NULL REFERENCES core.transaction_types(type_id),
    application_id UUID,  -- NULL for system transactions
    
    -- Actors
    initiator_account_id UUID NOT NULL,
    on_behalf_of_account_id UUID,
    beneficiary_account_id UUID,
    
    -- Payload
    payload JSONB NOT NULL,
    payload_encrypted BOOLEAN DEFAULT FALSE,
    
    -- Monetary values
    amount NUMERIC(20, 8),
    currency VARCHAR(3) CHECK (currency ~ '^[A-Z]{3}$'),
    
    -- Status tracking
    status VARCHAR(20) DEFAULT 'pending' 
        CHECK (status IN ('pending', 'validated', 'posted', 'completed', 'failed', 'reversed')),
    
    -- Mobile money
    is_mobile_money BOOLEAN DEFAULT FALSE,
    mobile_money_provider VARCHAR(20),
    mobile_money_operation VARCHAR(30),
    mobile_money_wallet_reference VARCHAR(100),
    
    -- Event sourcing
    correlation_id VARCHAR(255),
    causation_id UUID,
    event_sequence BIGINT,
    
    -- Hash chain (IMMUTABLE)
    previous_hash VARCHAR(64),
    record_hash VARCHAR(64),
    chain_sequence BIGINT DEFAULT nextval('core.global_event_sequence'),
    
    -- Partitioning
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE,
    committed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT pk_transaction_log PRIMARY KEY (transaction_id, committed_at)
);

-- Convert to hypertable
SELECT create_hypertable(
    'core.transaction_log',
    'committed_at',
    chunk_time_interval => INTERVAL '1 day'
);
```

**Key Indexes:**
```sql
-- UUID lookup
CREATE UNIQUE INDEX idx_transaction_log_uuid 
    ON core.transaction_log(transaction_uuid, committed_at);

-- Idempotency (critical for preventing duplicates)
CREATE UNIQUE INDEX idx_transaction_log_idempotency 
    ON core.transaction_log(idempotency_key, committed_at);

-- Application queries
CREATE INDEX idx_transaction_log_app_type_time 
    ON core.transaction_log(application_id, transaction_type_id, committed_at DESC);

-- Time-series optimization
CREATE INDEX idx_transaction_log_brin ON core.transaction_log 
    USING BRIN(committed_at);
```

**WORM Triggers:**
```sql
-- Prevent updates
CREATE TRIGGER trg_transaction_log_prevent_update
    BEFORE UPDATE ON core.transaction_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

-- Prevent deletes
CREATE TRIGGER trg_transaction_log_prevent_delete
    BEFORE DELETE ON core.transaction_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

-- Prevent truncate
CREATE TRIGGER trg_transaction_log_prevent_truncate
    BEFORE TRUNCATE ON core.transaction_log
    FOR EACH STATEMENT
    EXECUTE FUNCTION core.prevent_truncate();
```

### 2.2 Hash Chain Computation

```sql
-- Function to compute transaction hash
CREATE OR REPLACE FUNCTION core.compute_transaction_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_previous_hash VARCHAR(64);
    v_lock_obtained BOOLEAN;
BEGIN
    -- Use advisory lock to prevent race conditions
    SELECT pg_try_advisory_lock(998) INTO v_lock_obtained;
    
    IF NOT v_lock_obtained THEN
        PERFORM pg_advisory_lock(998);
    END IF;
    
    BEGIN
        -- Get previous hash in chain
        SELECT record_hash INTO v_previous_hash
        FROM core.transaction_log
        ORDER BY chain_sequence DESC NULLS LAST
        LIMIT 1;
        
        NEW.previous_hash := v_previous_hash;
        
        -- Compute SHA-256 hash of critical fields
        NEW.record_hash := core.generate_row_hash(
            'core.transaction_log',
            NEW.transaction_uuid,
            jsonb_build_object(
                'transaction_type_id', NEW.transaction_type_id,
                'initiator_account_id', NEW.initiator_account_id,
                'amount', NEW.amount,
                'status', NEW.status,
                'idempotency_key', NEW.idempotency_key
            ),
            NEW.committed_at,
            v_previous_hash
        );
        
        PERFORM pg_advisory_unlock(998);
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_advisory_unlock(998);
        RAISE;
    END;
    
    RETURN NEW;
END;
$$;

-- Apply trigger
CREATE TRIGGER trg_transaction_log_compute_hash
    BEFORE INSERT ON core.transaction_log
    FOR EACH ROW
    EXECUTE FUNCTION core.compute_transaction_hash();
```

### 2.3 Idempotency Enforcement

```sql
CREATE OR REPLACE FUNCTION core.check_idempotency()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_existing_id BIGINT;
    v_existing_uuid UUID;
    v_existing_status VARCHAR(20);
BEGIN
    -- Validate key format
    IF NEW.idempotency_key IS NULL OR length(trim(NEW.idempotency_key)) < 8 THEN
        RAISE EXCEPTION 'INVALID_IDEMPOTENCY_KEY: Key must be at least 8 characters',
            USING ERRCODE = 'check_violation';
    END IF;
    
    -- Check for existing key
    SELECT transaction_id, transaction_uuid, status 
    INTO v_existing_id, v_existing_uuid, v_existing_status
    FROM core.transaction_log
    WHERE idempotency_key = NEW.idempotency_key
    LIMIT 1;
    
    IF FOUND THEN
        RAISE EXCEPTION 'IDEMPOTENCY_VIOLATION: Transaction with key % already exists (ID: %, UUID: %, Status: %)',
            NEW.idempotency_key, v_existing_id, v_existing_uuid, v_existing_status
            USING ERRCODE = 'P0002';
    END IF;
    
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_transaction_log_check_idempotency
    BEFORE INSERT ON core.transaction_log
    FOR EACH ROW
    EXECUTE FUNCTION core.check_idempotency();
```

---

## 3. Events Schema (Event Sourcing)

### 3.1 event_store (V003)

```sql
CREATE TABLE events.event_store (
    event_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Event identification
    event_type VARCHAR(100) NOT NULL,
    event_version INTEGER DEFAULT 1,
    
    -- Stream (aggregate root)
    stream_id UUID NOT NULL,
    stream_type VARCHAR(100) NOT NULL,
    
    -- Ordering
    sequence_number BIGINT NOT NULL,
    
    -- Payload
    payload JSONB NOT NULL,
    metadata JSONB DEFAULT '{}',
    
    -- Causation and correlation
    correlation_id VARCHAR(255),
    causation_id UUID,
    
    -- Actor
    triggered_by VARCHAR(255),
    
    -- Timing
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE,
    
    -- Constraints
    UNIQUE (stream_id, sequence_number)
);

-- Convert to hypertable
SELECT create_hypertable(
    'events.event_store',
    'recorded_at',
    chunk_time_interval => INTERVAL '1 day'
);

-- Critical indexes
CREATE INDEX idx_event_store_stream 
    ON events.event_store(stream_id, sequence_number DESC);

CREATE INDEX idx_event_store_type 
    ON events.event_store(event_type, recorded_at DESC);

CREATE INDEX idx_event_store_correlation 
    ON events.event_store(correlation_id) 
    WHERE correlation_id IS NOT NULL;
```

### 3.2 Stream Sequences

```sql
CREATE TABLE events.stream_sequences (
    stream_id UUID PRIMARY KEY,
    stream_type VARCHAR(100) NOT NULL,
    last_sequence BIGINT DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Function to get next sequence
CREATE OR REPLACE FUNCTION events.next_sequence(p_stream_id UUID)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_next_seq BIGINT;
BEGIN
    INSERT INTO events.stream_sequences (stream_id, last_sequence)
    VALUES (p_stream_id, 1)
    ON CONFLICT (stream_id) DO UPDATE
    SET last_sequence = events.stream_sequences.last_sequence + 1,
        updated_at = NOW()
    RETURNING last_sequence INTO v_next_seq;
    
    RETURN v_next_seq;
END;
$$;
```

---

## 4. USSD Schema

### 4.1 ussd_sessions (V043)

```sql
CREATE TABLE ussd.ussd_sessions (
    session_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_code VARCHAR(100) UNIQUE NOT NULL,
    
    -- User (PII - ENCRYPTED)
    msisdn VARCHAR(20) NOT NULL,
    msisdn_encrypted BYTEA NOT NULL,
    msisdn_hash VARCHAR(64),
    account_id UUID REFERENCES core.account_registry(account_id),
    
    -- Application context
    application_id UUID,
    current_role_id UUID,
    
    -- Session state
    menu_state VARCHAR(100) DEFAULT 'START',
    previous_menu VARCHAR(100),
    menu_stack TEXT[] DEFAULT '{}',
    context_data JSONB DEFAULT '{}',
    context_data_encrypted BYTEA,
    input_history TEXT[] DEFAULT '{}',
    
    -- Language
    language_code VARCHAR(10) DEFAULT 'en',
    
    -- Multi-layer timeouts
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_activity_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    network_timeout_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '2 minutes'),
    application_timeout_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '5 minutes'),
    absolute_timeout_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '15 minutes'),
    
    -- Status
    status VARCHAR(20) DEFAULT 'ACTIVE' 
        CHECK (status IN ('ACTIVE', 'SUSPENDED', 'ENDED', 'TIMEOUT', 'ERROR')),
    
    -- Security
    session_hash VARCHAR(64) NOT NULL,
    previous_session_hash VARCHAR(64),
    fraud_score INTEGER DEFAULT 0 CHECK (fraud_score >= 0 AND fraud_score <= 100),
    
    -- Constraints
    CONSTRAINT valid_msisdn_format CHECK (msisdn ~ '^\+[1-9][0-9]{7,14}$')
);

-- PII encryption trigger
CREATE OR REPLACE FUNCTION ussd.trigger_encrypt_msisdn()
RETURNS TRIGGER AS $$
BEGIN
    -- Generate hash for lookups
    NEW.msisdn_hash := encode(digest(NEW.msisdn, 'sha256'), 'hex');
    
    -- Encrypt the MSISDN
    NEW.msisdn_encrypted := ussd.encrypt_msisdn(NEW.msisdn);
    
    -- Generate session hash
    NEW.session_hash := encode(
        digest(
            NEW.session_id::text || '|' || NEW.msisdn || '|' || extract(epoch from NEW.created_at)::text,
            'sha256'
        ),
        'hex'
    );
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_ussd_sessions_encrypt
    BEFORE INSERT ON ussd.ussd_sessions
    FOR EACH ROW
    EXECUTE FUNCTION ussd.trigger_encrypt_msisdn();
```

---

## 5. Audit Schema

### 5.1 change_log (V003)

```sql
CREATE TABLE audit.change_log (
    audit_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Table and operation
    table_schema VARCHAR(100) NOT NULL,
    table_name VARCHAR(100) NOT NULL,
    operation VARCHAR(10) NOT NULL 
        CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    
    -- Record identification
    record_id UUID NOT NULL,
    record_id_text TEXT,
    
    -- Change data
    old_data JSONB,
    new_data JSONB,
    changed_columns TEXT[],
    
    -- Actor
    changed_by VARCHAR(255) NOT NULL,
    changed_by_type VARCHAR(20) DEFAULT 'user',
    
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
    
    -- Hash chain
    previous_hash VARCHAR(64),
    record_hash VARCHAR(64) NOT NULL,
    chain_sequence BIGINT DEFAULT nextval('core.global_event_sequence'),
    
    -- Partition key
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE
);

-- Convert to hypertable
SELECT create_hypertable(
    'audit.change_log',
    'changed_at',
    chunk_time_interval => INTERVAL '1 day'
);
```

---

## 6. Integrity Schema

### 6.1 batch_hashes (V067)

```sql
CREATE TABLE integrity.batch_hashes (
    batch_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Period identification
    batch_date DATE NOT NULL UNIQUE,
    period_type VARCHAR(20) DEFAULT 'daily' 
        CHECK (period_type IN ('hourly', 'daily', 'weekly', 'monthly')),
    
    -- Batch hash
    batch_hash VARCHAR(64) NOT NULL,
    
    -- Metadata
    record_count INTEGER NOT NULL,
    source_data_hash VARCHAR(64) NOT NULL,
    
    -- Computation
    computed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    computed_by UUID,
    
    -- Verification
    is_verified BOOLEAN DEFAULT FALSE,
    verified_at TIMESTAMPTZ,
    verified_by UUID,
    
    -- Chain linking
    previous_batch_hash VARCHAR(64),
    
    -- Signature
    signature BYTEA,
    signature_algorithm VARCHAR(20) DEFAULT 'ed25519',
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Function to compute batch hash
CREATE OR REPLACE FUNCTION integrity.compute_batch_hash(
    p_date DATE,
    p_period_type VARCHAR(20) DEFAULT 'daily'
)
RETURNS VARCHAR(64) AS $$
DECLARE
    v_batch_hash VARCHAR(64);
    v_record_count INTEGER;
    v_source_hash VARCHAR(64);
BEGIN
    -- Get all transaction hashes for the date
    SELECT 
        COUNT(*),
        encode(
            digest(
                string_agg(record_hash, '' ORDER BY chain_sequence),
                'sha256'
            ),
            'hex'
        )
    INTO v_record_count, v_source_hash
    FROM core.transaction_log
    WHERE date_trunc('day', committed_at)::date = p_date;
    
    -- Compute batch hash
    v_batch_hash := encode(
        digest(
            p_date::text || ':' || v_source_hash,
            'sha256'
        ),
        'hex'
    );
    
    -- Insert or update batch record
    INSERT INTO integrity.batch_hashes (
        batch_date, period_type, batch_hash, record_count, source_data_hash
    ) VALUES (
        p_date, p_period_type, v_batch_hash, v_record_count, v_source_hash
    )
    ON CONFLICT (batch_date) DO UPDATE SET
        batch_hash = EXCLUDED.batch_hash,
        record_count = EXCLUDED.record_count,
        source_data_hash = EXCLUDED.source_data_hash,
        computed_at = NOW();
    
    RETURN v_batch_hash;
END;
$$ LANGUAGE plpgsql;
```

---

## 7. RLS Policies

### 7.1 Transaction Log

```sql
-- Enable RLS
ALTER TABLE core.transaction_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.transaction_log FORCE ROW LEVEL SECURITY;

-- Application-scoped access
CREATE POLICY transaction_log_app_access ON core.transaction_log
    FOR SELECT
    TO ussd_app_user
    USING (
        application_id = core.get_current_setting_as_uuid('app.current_application_id')
        OR application_id IS NULL
    );

-- Account-scoped access
CREATE POLICY transaction_log_self_access ON core.transaction_log
    FOR SELECT
    TO ussd_app_user
    USING (
        initiator_account_id = core.get_current_setting_as_uuid('app.current_account_id')
        OR on_behalf_of_account_id = core.get_current_setting_as_uuid('app.current_account_id')
        OR beneficiary_account_id = core.get_current_setting_as_uuid('app.current_account_id')
    );

-- Kernel full access
CREATE POLICY transaction_log_kernel_access ON core.transaction_log
    FOR ALL
    TO ussd_kernel_role
    USING (true);
```

---

## 8. Performance Optimization

### 8.1 TimescaleDB Configuration

```sql
-- Enable compression on transaction_log
ALTER TABLE core.transaction_log SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'application_id, transaction_type_id'
);

-- Add compression policy (compress after 90 days)
SELECT add_compression_policy('core.transaction_log', INTERVAL '90 days');

-- Add retention policy (optional - retain 7 years)
-- SELECT add_retention_policy('core.transaction_log', INTERVAL '7 years');
```

### 8.2 Connection Pooling

```yaml
# pgBouncer configuration
[databases]
ussd_kernel = host=postgres port=5432 dbname=ussd_kernel

[pgbouncer]
listen_port = 6432
listen_addr = 0.0.0.0
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt

# Pool settings
pool_mode = transaction
max_client_conn = 10000
default_pool_size = 25
reserve_pool_size = 5
reserve_pool_timeout = 3
```

---

## 9. Backup & Recovery

### 9.1 Continuous Archiving

```sql
-- postgresql.conf
wal_level = replica
archive_mode = on
archive_command = 'cp %p /var/lib/postgresql/archive/%f'
max_wal_senders = 3
```

### 9.2 Logical Backup

```bash
#!/bin/bash
# backup.sh

BACKUP_DIR="/backups/$(date +%Y%m%d)"
mkdir -p $BACKUP_DIR

# Schema-only backup
pg_dump --schema-only -U postgres ussd_kernel > $BACKUP_DIR/schema.sql

# Data backup (compressed)
pg_dump -U postgres -Fc ussd_kernel > $BACKUP_DIR/ussd_kernel.dump

# Specific tables (immutable data)
pg_dump -U postgres --data-only -t core.transaction_log ussd_kernel > $BACKUP_DIR/transaction_log.sql

# Upload to S3
aws s3 sync $BACKUP_DIR s3://ussd-kernel-backups/$(date +%Y%m%d)/
```

---

## 10. Monitoring Queries

### 10.1 Transaction Volume

```sql
-- Daily transaction count
SELECT 
    date_trunc('day', committed_at) as day,
    COUNT(*) as transaction_count,
    SUM(amount) as total_amount
FROM core.transaction_log
WHERE committed_at > NOW() - INTERVAL '30 days'
GROUP BY 1
ORDER BY 1 DESC;
```

### 10.2 Hash Chain Verification

```sql
-- Verify hash chain integrity
WITH RECURSIVE hash_chain AS (
    SELECT 
        transaction_id,
        record_hash,
        previous_hash,
        1 as depth
    FROM core.transaction_log
    WHERE previous_hash IS NULL  -- Genesis
    
    UNION ALL
    
    SELECT 
        t.transaction_id,
        t.record_hash,
        t.previous_hash,
        c.depth + 1
    FROM core.transaction_log t
    JOIN hash_chain c ON t.previous_hash = c.record_hash
    WHERE c.depth < 1000
)
SELECT COUNT(*) as chain_length FROM hash_chain;
```

---

**Status**: Implementation Ready  
**Next Steps**:
1. Apply migrations in order (V001-V073)
2. Configure TimescaleDB compression
3. Set up pgBouncer connection pooling
4. Configure backups
5. Set up monitoring
