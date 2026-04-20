-- =============================================================================
-- Migration: V001__extensions_and_schemas
-- Description: Extensions and Schemas
-- Dependencies: None
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- EXTENSIONS
-- =============================================================================

-- Cryptographic functions
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- UUID generation
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Text search and fuzzy matching
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Time-series optimization
DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS timescaledb;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TimescaleDB not available: %', SQLERRM;
END $$;

-- Temporal tables (for bitemporal support)
DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS temporal_tables;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'temporal_tables extension not available: %', SQLERRM;
END $$;

-- =============================================================================
-- SCHEMAS
-- =============================================================================

-- Core schema for immutable ledger tables
CREATE SCHEMA IF NOT EXISTS core;
COMMENT ON SCHEMA core IS 'Core immutable ledger tables with WORM guarantees';

-- Application schema for app-related data
CREATE SCHEMA IF NOT EXISTS app;
COMMENT ON SCHEMA app IS 'Application data and configuration';

-- Audit schema for compliance
CREATE SCHEMA IF NOT EXISTS audit;
COMMENT ON SCHEMA audit IS 'Audit trail and compliance logging with hash chaining';

-- USSD session schema
CREATE SCHEMA IF NOT EXISTS ussd;
COMMENT ON SCHEMA ussd IS 'USSD session and routing data';

-- USSD Gateway schema
CREATE SCHEMA IF NOT EXISTS ussd_gateway;
COMMENT ON SCHEMA ussd_gateway IS 'USSD gateway and provider integrations';

-- Observability schema
CREATE SCHEMA IF NOT EXISTS observability;
COMMENT ON SCHEMA observability IS 'Metrics, tracing, and alerting';

-- Mobile Money schema
CREATE SCHEMA IF NOT EXISTS mobile_money;
COMMENT ON SCHEMA mobile_money IS 'Mobile money wallet integrations (EcoCash, TeleCash, OneMoney)';

-- Event sourcing schema
CREATE SCHEMA IF NOT EXISTS events;
COMMENT ON SCHEMA events IS 'Event sourcing and append-only event store';

-- Temporal schema for bitemporal data
CREATE SCHEMA IF NOT EXISTS temporal;
COMMENT ON SCHEMA temporal IS 'Bitemporal data versioning and history';

COMMIT;
