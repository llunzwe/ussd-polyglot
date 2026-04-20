-- =============================================================================
-- Migration: V015__simplified_encryption
-- Description: Simplified 2-Level Encryption (replaces 4-level hierarchy)
-- Dependencies: V001-V014
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- KEY ENCRYPTION KEYS (KEK) - Level 1
-- =============================================================================

CREATE TABLE IF NOT EXISTS app.encryption_keys (
    key_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Key identification
    key_name VARCHAR(100) NOT NULL UNIQUE,
    key_purpose VARCHAR(50) NOT NULL 
        CHECK (key_purpose IN ('field_encryption', 'token_encryption', 'backup_encryption')),
    
    -- Key material (encrypted by master key)
    key_material_encrypted TEXT NOT NULL,
    key_algorithm VARCHAR(20) DEFAULT 'AES-256-GCM',
    key_size_bits INTEGER DEFAULT 256,
    
    -- Key versioning
    key_version INTEGER DEFAULT 1,
    replaces_key_id UUID REFERENCES app.encryption_keys(key_id),
    
    -- Lifecycle
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    rotates_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,
    rotated_to_key_id UUID REFERENCES app.encryption_keys(key_id),
    
    -- Usage tracking
    encrypt_count INTEGER DEFAULT 0,
    decrypt_count INTEGER DEFAULT 0,
    last_used_at TIMESTAMPTZ,
    
    -- Audit
    created_by UUID,
    rotated_by UUID
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_encryption_keys_purpose 
    ON app.encryption_keys(key_purpose, is_active);

CREATE INDEX IF NOT EXISTS idx_encryption_keys_expiry 
    ON app.encryption_keys(expires_at) 
    WHERE is_active = TRUE AND expires_at IS NOT NULL;

COMMENT ON TABLE app.encryption_keys IS 'Key Encryption Keys (KEK) - Level 1 of 2-level hierarchy';

-- =============================================================================
-- DATA ENCRYPTION KEYS (DEK) - Level 2
-- Per-record encryption keys
-- =============================================================================

CREATE TABLE IF NOT EXISTS app.data_encryption_keys (
    dek_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Parent KEK
    kek_id UUID NOT NULL REFERENCES app.encryption_keys(key_id),
    
    -- Resource being encrypted
    resource_type VARCHAR(50) NOT NULL 
        CHECK (resource_type IN ('session', 'transaction', 'user_data', 'api_key')),
    resource_id UUID NOT NULL,
    
    -- Encrypted DEK (encrypted by KEK)
    dek_encrypted TEXT NOT NULL,
    
    -- Metadata
    key_algorithm VARCHAR(20) DEFAULT 'AES-256-GCM',
    
    -- Lifecycle
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ,
    
    -- Constraints
    UNIQUE (resource_type, resource_id, kek_id)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_dek_resource 
    ON app.data_encryption_keys(resource_type, resource_id, is_active);

CREATE INDEX IF NOT EXISTS idx_dek_kek 
    ON app.data_encryption_keys(kek_id, is_active);

COMMENT ON TABLE app.data_encryption_keys IS 'Data Encryption Keys (DEK) - Level 2 of 2-level hierarchy';

-- =============================================================================
-- ENCRYPTED FIELD REGISTRY
-- Tracks which fields are encrypted
-- =============================================================================

CREATE TABLE IF NOT EXISTS app.encrypted_field_registry (
    registry_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Field identification
    table_name VARCHAR(100) NOT NULL,
    column_name VARCHAR(100) NOT NULL,
    
    -- Encryption config
    encryption_type VARCHAR(20) DEFAULT 'deterministic' 
        CHECK (encryption_type IN ('deterministic', 'randomized', 'searchable')),
    kek_id UUID NOT NULL REFERENCES app.encryption_keys(key_id),
    
    -- Searchable encryption (for like queries)
    blind_index_enabled BOOLEAN DEFAULT FALSE,
    blind_index_bits INTEGER DEFAULT 32,
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    UNIQUE (table_name, column_name)
);

CREATE INDEX IF NOT EXISTS idx_encrypted_fields_table 
    ON app.encrypted_field_registry(table_name, is_active);

COMMENT ON TABLE app.encrypted_field_registry IS 'Registry of encrypted fields and their encryption configuration';

-- =============================================================================
-- ENCRYPTION AUDIT LOG
-- =============================================================================

CREATE TABLE IF NOT EXISTS app.encryption_audit_log (
    log_id UUID DEFAULT gen_random_uuid(),
    
    -- Operation details
    operation VARCHAR(20) NOT NULL 
        CHECK (operation IN ('encrypt', 'decrypt', 'rotate', 'key_create', 'key_revoke')),
    
    -- Key references
    kek_id UUID REFERENCES app.encryption_keys(key_id),
    dek_id UUID REFERENCES app.data_encryption_keys(dek_id),
    
    -- Resource
    resource_type VARCHAR(50),
    resource_id UUID,
    
    -- Context
    application_id UUID,
    user_id UUID,
    ip_address INET,
    
    -- Success/failure
    is_success BOOLEAN DEFAULT TRUE,
    error_message TEXT,
    
    -- Performance
    duration_ms INTEGER,
    
    -- Timestamp
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Partition key
    partition_date DATE NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT pk_app_encryption_audit_log_log_id_created_at PRIMARY KEY (log_id, created_at));

-- Convert to hypertable
SELECT create_hypertable(
    'app.encryption_audit_log',
    'created_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_encryption_audit_operation 
    ON app.encryption_audit_log(operation, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_encryption_audit_key 
    ON app.encryption_audit_log(kek_id, created_at DESC);

COMMENT ON TABLE app.encryption_audit_log IS 'Audit log for encryption operations';

-- =============================================================================
-- TRIGGERS (Mixed: Audit log is WORM, key tables need rotation capability)
-- =============================================================================

-- PRODUCTION FIX (SEC-004): Encryption keys need rotation capability.
-- Replaced blanket WORM with selective update trigger allowing only rotation fields.

CREATE OR REPLACE FUNCTION app.encryption_keys_update_check()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_allowed_fields TEXT[] := ARRAY['is_active', 'rotated_to_key_id', 'rotated_by', 'last_used_at', 'encrypt_count', 'decrypt_count'];
    v_field TEXT;
    v_old_json JSONB;
    v_new_json JSONB;
BEGIN
    v_old_json := to_jsonb(OLD);
    v_new_json := to_jsonb(NEW);
    
    -- Check if any non-allowed fields changed
    FOR v_field IN SELECT jsonb_object_keys(v_new_json)
    LOOP
        IF v_old_json->v_field IS DISTINCT FROM v_new_json->v_field THEN
            IF NOT (v_field = ANY(v_allowed_fields)) THEN
                RAISE EXCEPTION 'ENCRYPTION_KEY_IMMUTABLE: Field % cannot be modified. Only rotation and usage tracking fields are mutable.', v_field;
            END IF;
        END IF;
    END LOOP;
    
    -- Log key rotation to audit
    IF OLD.is_active = TRUE AND NEW.is_active = FALSE THEN
        INSERT INTO app.encryption_audit_log (
            operation, kek_id, resource_type, is_success
        ) VALUES ('rotate', NEW.key_id, 'key_encryption', TRUE);
    END IF;
    
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_encryption_keys_update_check ON app.encryption_keys;
CREATE TRIGGER trg_encryption_keys_update_check
    BEFORE UPDATE ON app.encryption_keys
    FOR EACH ROW
    EXECUTE FUNCTION app.encryption_keys_update_check();

CREATE TRIGGER trg_encryption_keys_prevent_delete
    BEFORE DELETE ON app.encryption_keys
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

-- DEK rotation trigger (similar pattern)
CREATE OR REPLACE FUNCTION app.data_encryption_keys_update_check()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_allowed_fields TEXT[] := ARRAY['is_active', 'expires_at', 'last_used_at'];
    v_field TEXT;
    v_old_json JSONB;
    v_new_json JSONB;
BEGIN
    v_old_json := to_jsonb(OLD);
    v_new_json := to_jsonb(NEW);
    
    FOR v_field IN SELECT jsonb_object_keys(v_new_json)
    LOOP
        IF v_old_json->v_field IS DISTINCT FROM v_new_json->v_field THEN
            IF NOT (v_field = ANY(v_allowed_fields)) THEN
                RAISE EXCEPTION 'DEK_IMMUTABLE: Field % cannot be modified. Only lifecycle fields are mutable.', v_field;
            END IF;
        END IF;
    END LOOP;
    
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_data_encryption_keys_update_check ON app.data_encryption_keys;
CREATE TRIGGER trg_data_encryption_keys_update_check
    BEFORE UPDATE ON app.data_encryption_keys
    FOR EACH ROW
    EXECUTE FUNCTION app.data_encryption_keys_update_check();

CREATE TRIGGER trg_data_encryption_keys_prevent_delete
    BEFORE DELETE ON app.data_encryption_keys
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

-- Encrypted field registry - operational table, needs updates for activation/deactivation
DROP TRIGGER IF EXISTS trg_encrypted_field_registry_timestamp ON app.encrypted_field_registry;
CREATE TRIGGER trg_encrypted_field_registry_timestamp
    BEFORE UPDATE ON app.encrypted_field_registry
    FOR EACH ROW
    EXECUTE FUNCTION core.update_timestamp();

-- Encryption audit log is immutable
CREATE TRIGGER trg_encryption_audit_log_prevent_update
    BEFORE UPDATE ON app.encryption_audit_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_encryption_audit_log_prevent_delete
    BEFORE DELETE ON app.encryption_audit_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

CREATE TRIGGER trg_encryption_audit_log_prevent_truncate
    BEFORE TRUNCATE ON app.encryption_audit_log
    FOR EACH STATEMENT
    EXECUTE FUNCTION core.prevent_truncate();

COMMIT;
