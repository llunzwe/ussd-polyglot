-- =============================================================================
-- TimescaleDB Compatibility Shim
-- Description: Creates a no-op create_hypertable for environments where
--              TimescaleDB extension is not available (e.g., integration tests)
-- =============================================================================

DO $$
BEGIN
    -- Try to create TimescaleDB extension if available
    CREATE EXTENSION IF NOT EXISTS timescaledb WITH SCHEMA public;
EXCEPTION
    WHEN undefined_file THEN
        NULL;  -- TimescaleDB not installed, will create shim below
    WHEN others THEN
        NULL;  -- Some other issue, will create shim below
END;
$$;

-- If TimescaleDB is NOT installed, create a compatibility shim that
-- silently ignores hypertable creation (tables remain regular PostgreSQL tables).
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_extension WHERE extname = 'timescaledb'
    ) THEN
        CREATE OR REPLACE FUNCTION create_hypertable(
            relation REGCLASS,
            time_column_name NAME,
            partitioning_column NAME DEFAULT NULL,
            number_partitions INTEGER DEFAULT NULL,
            associated_schema_name NAME DEFAULT NULL,
            associated_table_prefix NAME DEFAULT NULL,
            migration_table_name NAME DEFAULT NULL,
            time_column_name_2 NAME DEFAULT NULL,
            created_at TIMESTAMPTZ DEFAULT NULL,
            chunk_time_interval ANYELEMENT DEFAULT NULL::INTERVAL,
            if_not_exists BOOLEAN DEFAULT FALSE
        )
        RETURNS TABLE(hypertable_id INT, schema_name NAME, table_name NAME, created BOOL)
        LANGUAGE plpgsql AS $func$
        BEGIN
            RETURN QUERY SELECT 1::INT, 'public'::NAME, relation::NAME, false::BOOL;
        END;
        $func$;
    END IF;
END;
$$;
