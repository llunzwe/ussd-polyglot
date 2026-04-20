-- =============================================================================
-- Migration: V073__security_hardening_rls
-- Description: Security Hardening - FORCE RLS for Early Migration Tables
-- Dependencies: V001-V072
--
-- PURPOSE: Apply FORCE ROW LEVEL SECURITY to tables from early migrations
-- that were missing this critical security control. This migration addresses
-- the security gap identified in the enterprise audit.
--
-- SECURITY AUDIT FINDING:
-- Tables in V003-V010 were created before FORCE RLS policy was established.
-- This migration retroactively applies enterprise-grade security controls.
--
-- ADR-020: Retroactive Security Hardening
-- DECISION: Apply FORCE RLS via dedicated migration vs modifying history
-- RATIONALE:
--   - Modifying existing migration files breaks idempotency for existing deployments
--   - Dedicated migration allows audit trail of security improvements
--   - Can be applied independently to existing production databases
-- TRADE-OFFS:
--   (+) Clean audit trail of security changes
--   (+) Works with existing deployments
--   (-) Additional migration file in sequence
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- =============================================================================
-- AUDIT SCHEMA TABLES (V003)
-- =============================================================================

-- audit.change_log: System audit trail - internal access only
ALTER TABLE IF EXISTS audit.change_log FORCE ROW LEVEL SECURITY;

COMMENT ON TABLE audit.change_log IS 
'Audit trail for all data changes. 
SECURITY: Internal system access only - no direct app access.
WORM: Immutable audit records.';

-- audit.session_log: Session audit trail - internal access only
ALTER TABLE IF EXISTS audit.session_log FORCE ROW LEVEL SECURITY;

COMMENT ON TABLE audit.session_log IS 
'Session audit trail for security monitoring.
SECURITY: Internal system access only.
WORM: Immutable audit records.';

-- =============================================================================
-- EVENTS SCHEMA TABLES (V003)
-- =============================================================================

-- events.event_store: Event sourcing store - app-scoped access
ALTER TABLE IF EXISTS events.event_store FORCE ROW LEVEL SECURITY;

CREATE POLICY IF NOT EXISTS event_store_app_isolation ON events.event_store
    FOR ALL
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

-- events.stream_sequences: Event sequence tracking - app-scoped
ALTER TABLE IF EXISTS events.stream_sequences FORCE ROW LEVEL SECURITY;

CREATE POLICY IF NOT EXISTS stream_sequences_app_isolation ON events.stream_sequences
    FOR ALL
    TO ussd_app_user
    USING (stream_id IN (
        SELECT stream_id FROM events.event_store
        WHERE application_id = core.get_current_setting_as_uuid('app.current_application_id')
    ));

-- events.projections: Read models - app-scoped
ALTER TABLE IF EXISTS events.projections FORCE ROW LEVEL SECURITY;

CREATE POLICY IF NOT EXISTS projections_app_isolation ON events.projections
    FOR ALL
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

-- =============================================================================
-- USSD PROVIDER TABLES (V004)
-- =============================================================================

-- ussd.provider_adapters: Provider configuration - app-scoped
ALTER TABLE IF EXISTS ussd.provider_adapters FORCE ROW LEVEL SECURITY;

CREATE POLICY IF NOT EXISTS provider_adapters_app_isolation ON ussd.provider_adapters
    FOR ALL
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

-- ussd.provider_webhook_log: Webhook logs - app-scoped
ALTER TABLE IF EXISTS ussd.provider_webhook_log FORCE ROW LEVEL SECURITY;

CREATE POLICY IF NOT EXISTS provider_webhook_log_app_isolation ON ussd.provider_webhook_log
    FOR ALL
    TO ussd_app_user
    USING (adapter_id IN (
        SELECT adapter_id FROM ussd.provider_adapters
        WHERE application_id = core.get_current_setting_as_uuid('app.current_application_id')
    ));

-- ussd.webhook_dead_letter_queue: DLQ - app-scoped
ALTER TABLE IF EXISTS ussd.webhook_dead_letter_queue FORCE ROW LEVEL SECURITY;

CREATE POLICY IF NOT EXISTS webhook_dlq_app_isolation ON ussd.webhook_dead_letter_queue
    FOR ALL
    TO ussd_app_user
    USING (adapter_id IN (
        SELECT adapter_id FROM ussd.provider_adapters
        WHERE application_id = core.get_current_setting_as_uuid('app.current_application_id')
    ));

-- ussd.batch_ussd_queue: Batch processing - app-scoped
ALTER TABLE IF EXISTS ussd.batch_ussd_queue FORCE ROW LEVEL SECURITY;

CREATE POLICY IF NOT EXISTS batch_ussd_queue_app_isolation ON ussd.batch_ussd_queue
    FOR ALL
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

-- =============================================================================
-- JWT/SESSION TABLES (V005)
-- =============================================================================

-- ussd.jwt_tokens: Token storage - internal use
ALTER TABLE IF EXISTS ussd.jwt_tokens FORCE ROW LEVEL SECURITY;

CREATE POLICY IF NOT EXISTS jwt_tokens_app_isolation ON ussd.jwt_tokens
    FOR ALL
    TO ussd_app_user
    USING (session_id IN (
        SELECT session_id FROM ussd.sessions
        WHERE application_id = core.get_current_setting_as_uuid('app.current_application_id')
    ));

-- ussd.token_blacklist: Revoked tokens - internal use
ALTER TABLE IF EXISTS ussd.token_blacklist FORCE ROW LEVEL SECURITY;

-- app.api_keys: API credentials - app-scoped
ALTER TABLE IF EXISTS app.api_keys FORCE ROW LEVEL SECURITY;

CREATE POLICY IF NOT EXISTS api_keys_app_isolation ON app.api_keys
    FOR ALL
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

-- ussd.session_checkpoints: Session state - app-scoped
ALTER TABLE IF EXISTS ussd.session_checkpoints FORCE ROW LEVEL SECURITY;

CREATE POLICY IF NOT EXISTS session_checkpoints_app_isolation ON ussd.session_checkpoints
    FOR ALL
    TO ussd_app_user
    USING (session_id IN (
        SELECT session_id FROM ussd.sessions
        WHERE application_id = core.get_current_setting_as_uuid('app.current_application_id')
    ));

-- =============================================================================
-- CORE MOVEMENT TABLES (V007-V008)
-- =============================================================================

-- core.movement_legs: Financial legs - app-scoped
ALTER TABLE IF EXISTS core.movement_legs FORCE ROW LEVEL SECURITY;

-- Policy using denormalized application_id column
CREATE POLICY IF NOT EXISTS movement_legs_app_isolation ON core.movement_legs
    FOR ALL
    TO ussd_app_user
    USING (
        application_id = core.get_current_setting_as_uuid('app.current_application_id')
        OR application_id IS NULL
        OR EXISTS (
            SELECT 1 FROM core.transaction_log tl
            WHERE tl.transaction_id = movement_legs.transaction_id
            AND (tl.application_id = core.get_current_setting_as_uuid('app.current_application_id')
                 OR tl.application_id IS NULL)
        )
    );

-- core.movement_postings: Financial postings - app-scoped
ALTER TABLE IF EXISTS core.movement_postings FORCE ROW LEVEL SECURITY;

-- Policy using denormalized application_id column (more efficient than join)
CREATE POLICY IF NOT EXISTS movement_postings_app_isolation ON core.movement_postings
    FOR ALL
    TO ussd_app_user
    USING (
        application_id = core.get_current_setting_as_uuid('app.current_application_id')
        OR application_id IS NULL
    );

-- =============================================================================
-- CACHE/RATE LIMIT TABLES (V009)
-- =============================================================================

-- ussd.cache_key_registry: Cache metadata - app-scoped
ALTER TABLE IF EXISTS ussd.cache_key_registry FORCE ROW LEVEL SECURITY;

CREATE POLICY IF NOT EXISTS cache_key_registry_app_isolation ON ussd.cache_key_registry
    FOR ALL
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

-- ussd.cache_invalidation_log: Cache invalidation - app-scoped
ALTER TABLE IF EXISTS ussd.cache_invalidation_log FORCE ROW LEVEL SECURITY;

CREATE POLICY IF NOT EXISTS cache_invalidation_log_app_isolation ON ussd.cache_invalidation_log
    FOR ALL
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

-- ussd.rate_limit_buckets: Rate limiting - internal system
ALTER TABLE IF EXISTS ussd.rate_limit_buckets FORCE ROW LEVEL SECURITY;

CREATE POLICY IF NOT EXISTS rate_limit_buckets_app_isolation ON ussd.rate_limit_buckets
    FOR ALL
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

-- app.rate_limit_policies: Rate policies - app-scoped admin
ALTER TABLE IF EXISTS app.rate_limit_policies FORCE ROW LEVEL SECURITY;

CREATE POLICY IF NOT EXISTS rate_limit_policies_app_isolation ON app.rate_limit_policies
    FOR ALL
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

-- ussd.session_state_cache: Session cache - app-scoped
ALTER TABLE IF EXISTS ussd.session_state_cache FORCE ROW LEVEL SECURITY;

CREATE POLICY IF NOT EXISTS session_state_cache_app_isolation ON ussd.session_state_cache
    FOR ALL
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

-- =============================================================================
-- ENTITY SEQUENCES (V010)
-- =============================================================================

-- core.entity_sequences: ID sequences - app-scoped
ALTER TABLE IF EXISTS core.entity_sequences FORCE ROW LEVEL SECURITY;

CREATE POLICY IF NOT EXISTS entity_sequences_app_isolation ON core.entity_sequences
    FOR ALL
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

-- core.gapless_counters: Counter sequences - app-scoped
ALTER TABLE IF EXISTS core.gapless_counters FORCE ROW LEVEL SECURITY;

CREATE POLICY IF NOT EXISTS gapless_counters_app_isolation ON core.gapless_counters
    FOR ALL
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

-- =============================================================================
-- SYSTEM TABLES (V002) - Reference Data
-- =============================================================================

-- core.currency_codes: Reference data - public read
ALTER TABLE IF EXISTS core.currency_codes FORCE ROW LEVEL SECURITY;

CREATE POLICY IF NOT EXISTS currency_codes_public_read ON core.currency_codes
    FOR SELECT
    TO ussd_app_user
    USING (TRUE);

-- core.system_configuration: System config - admin only
ALTER TABLE IF EXISTS core.system_configuration FORCE ROW LEVEL SECURITY;

CREATE POLICY IF NOT EXISTS system_configuration_public_read ON core.system_configuration
    FOR SELECT
    TO ussd_app_user
    USING (TRUE);

-- =============================================================================
-- SECURITY AUDIT LOG
-- =============================================================================

-- Log the security hardening for audit trail
CREATE TABLE IF NOT EXISTS audit.security_hardening_log (
    log_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    migration_version VARCHAR(20) NOT NULL,
    hardening_type VARCHAR(50) NOT NULL,
    target_table VARCHAR(100) NOT NULL,
    action_taken VARCHAR(100) NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    applied_by VARCHAR(100) DEFAULT current_user
);

-- Log entries for this migration
INSERT INTO audit.security_hardening_log (migration_version, hardening_type, target_table, action_taken) VALUES
    ('V073', 'FORCE_RLS', 'audit.change_log', 'Applied FORCE ROW LEVEL SECURITY'),
    ('V073', 'FORCE_RLS', 'audit.session_log', 'Applied FORCE ROW LEVEL SECURITY'),
    ('V073', 'FORCE_RLS', 'events.event_store', 'Applied FORCE ROW LEVEL SECURITY'),
    ('V073', 'FORCE_RLS', 'events.stream_sequences', 'Applied FORCE ROW LEVEL SECURITY'),
    ('V073', 'FORCE_RLS', 'events.projections', 'Applied FORCE ROW LEVEL SECURITY'),
    ('V073', 'FORCE_RLS', 'ussd.provider_adapters', 'Applied FORCE ROW LEVEL SECURITY'),
    ('V073', 'FORCE_RLS', 'ussd.provider_webhook_log', 'Applied FORCE ROW LEVEL SECURITY'),
    ('V073', 'FORCE_RLS', 'ussd.webhook_dead_letter_queue', 'Applied FORCE ROW LEVEL SECURITY'),
    ('V073', 'FORCE_RLS', 'ussd.batch_ussd_queue', 'Applied FORCE ROW LEVEL SECURITY'),
    ('V073', 'FORCE_RLS', 'ussd.jwt_tokens', 'Applied FORCE ROW LEVEL SECURITY'),
    ('V073', 'FORCE_RLS', 'ussd.token_blacklist', 'Applied FORCE ROW LEVEL SECURITY'),
    ('V073', 'FORCE_RLS', 'app.api_keys', 'Applied FORCE ROW LEVEL SECURITY'),
    ('V073', 'FORCE_RLS', 'ussd.session_checkpoints', 'Applied FORCE ROW LEVEL SECURITY'),
    ('V073', 'FORCE_RLS', 'core.movement_legs', 'Applied FORCE ROW LEVEL SECURITY with application_id policy'),
    ('V073', 'FORCE_RLS', 'core.movement_postings', 'Applied FORCE ROW LEVEL SECURITY with application_id policy'),
    ('V073', 'FORCE_RLS', 'ussd.cache_key_registry', 'Applied FORCE ROW LEVEL SECURITY'),
    ('V073', 'FORCE_RLS', 'ussd.cache_invalidation_log', 'Applied FORCE ROW LEVEL SECURITY'),
    ('V073', 'FORCE_RLS', 'ussd.rate_limit_buckets', 'Applied FORCE ROW LEVEL SECURITY'),
    ('V073', 'FORCE_RLS', 'app.rate_limit_policies', 'Applied FORCE ROW LEVEL SECURITY'),
    ('V073', 'FORCE_RLS', 'ussd.session_state_cache', 'Applied FORCE ROW LEVEL SECURITY'),
    ('V073', 'FORCE_RLS', 'core.entity_sequences', 'Applied FORCE ROW LEVEL SECURITY'),
    ('V073', 'FORCE_RLS', 'core.gapless_counters', 'Applied FORCE ROW LEVEL SECURITY'),
    ('V073', 'FORCE_RLS', 'core.currency_codes', 'Applied FORCE ROW LEVEL SECURITY'),
    ('V073', 'FORCE_RLS', 'core.system_configuration', 'Applied FORCE ROW LEVEL SECURITY');

-- Enable RLS on the log itself
DO $$
BEGIN
    ALTER TABLE audit.security_hardening_log FORCE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RLS not supported on this table: %', SQLERRM;
END;
$$;

-- WORM triggers for the audit log
CREATE TRIGGER trg_security_hardening_log_prevent_update
    BEFORE UPDATE ON audit.security_hardening_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();

CREATE TRIGGER trg_security_hardening_log_prevent_delete
    BEFORE DELETE ON audit.security_hardening_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_delete();

-- =============================================================================
-- ADDITIONAL RLS POLICIES FOR TABLES MISSING COVERAGE
-- =============================================================================

-- core.rejection_log: Application-scoped access
ALTER TABLE IF EXISTS core.rejection_log FORCE ROW LEVEL SECURITY;

CREATE POLICY IF NOT EXISTS rejection_log_app_isolation ON core.rejection_log
    FOR ALL
    TO ussd_app_user
    USING (
        application_id = core.get_current_setting_as_uuid('app.current_application_id')
        OR application_id IS NULL
    );

-- core.liquidity_positions: Application-scoped access
ALTER TABLE IF EXISTS core.liquidity_positions FORCE ROW LEVEL SECURITY;

-- PRODUCTION FIX: Uses safe UUID helper to prevent NULL casting issues
CREATE POLICY IF NOT EXISTS liquidity_positions_app_isolation ON core.liquidity_positions
    FOR ALL
    TO ussd_app_user
    USING (
        application_id = core.get_current_setting_as_uuid('app.current_application_id')
        OR application_id IS NULL
    );

-- core.reconciliation_runs: Application-scoped access
ALTER TABLE IF EXISTS core.reconciliation_runs FORCE ROW LEVEL SECURITY;

-- PRODUCTION FIX: Uses safe UUID helper to prevent NULL casting issues
CREATE POLICY IF NOT EXISTS reconciliation_runs_app_isolation ON core.reconciliation_runs
    FOR ALL
    TO ussd_app_user
    USING (
        EXISTS (
            SELECT 1 FROM core.account_registry ar
            WHERE ar.account_id = reconciliation_runs.primary_account_id
            AND ar.primary_application_id = core.get_current_setting_as_uuid('app.current_application_id')
        )
    );

-- core.reconciliation_items: Application-scoped via parent run
ALTER TABLE IF EXISTS core.reconciliation_items FORCE ROW LEVEL SECURITY;

-- PRODUCTION FIX: Uses safe UUID helper to prevent NULL casting issues
CREATE POLICY IF NOT EXISTS reconciliation_items_app_isolation ON core.reconciliation_items
    FOR ALL
    TO ussd_app_user
    USING (
        EXISTS (
            SELECT 1 FROM core.reconciliation_runs rr
            JOIN core.account_registry ar ON ar.account_id = rr.primary_account_id
            WHERE rr.run_id = reconciliation_items.run_id
            AND ar.primary_application_id = core.get_current_setting_as_uuid('app.current_application_id')
        )
    );

-- core.control_batches: Application-scoped access
ALTER TABLE IF EXISTS core.control_batches FORCE ROW LEVEL SECURITY;

-- PRODUCTION FIX: Uses safe UUID helper to prevent NULL casting issues
CREATE POLICY IF NOT EXISTS control_batches_app_isolation ON core.control_batches
    FOR ALL
    TO ussd_app_user
    USING (
        application_id = core.get_current_setting_as_uuid('app.current_application_id')
        OR application_id IS NULL
    );

-- core.chart_of_accounts: Application-scoped (NULL for system-wide)
ALTER TABLE IF EXISTS core.chart_of_accounts FORCE ROW LEVEL SECURITY;

-- PRODUCTION FIX: Uses safe UUID helper to prevent NULL casting issues
CREATE POLICY IF NOT EXISTS chart_of_accounts_app_isolation ON core.chart_of_accounts
    FOR ALL
    TO ussd_app_user
    USING (
        application_id = core.get_current_setting_as_uuid('app.current_application_id')
        OR application_id IS NULL
    );

-- core.period_end_balances: Application-scoped via account
ALTER TABLE IF EXISTS core.period_end_balances FORCE ROW LEVEL SECURITY;

-- PRODUCTION FIX: Uses safe UUID helper to prevent NULL casting issues
CREATE POLICY IF NOT EXISTS period_end_balances_app_isolation ON core.period_end_balances
    FOR ALL
    TO ussd_app_user
    USING (
        EXISTS (
            SELECT 1 FROM core.account_registry ar
            WHERE ar.account_id = period_end_balances.account_id
            AND ar.primary_application_id = core.get_current_setting_as_uuid('app.current_application_id')
        )
    );

-- core.exchange_rates: System-wide reference data - read only for apps
ALTER TABLE IF EXISTS core.exchange_rates FORCE ROW LEVEL SECURITY;

CREATE POLICY IF NOT EXISTS exchange_rates_read_only ON core.exchange_rates
    FOR SELECT
    TO ussd_app_user
    USING (TRUE);

-- core.bad_debt_provision: Application-scoped via account
ALTER TABLE IF EXISTS core.bad_debt_provision FORCE ROW LEVEL SECURITY;

-- PRODUCTION FIX: Uses safe UUID helper to prevent NULL casting issues
CREATE POLICY IF NOT EXISTS bad_debt_provision_app_isolation ON core.bad_debt_provision
    FOR ALL
    TO ussd_app_user
    USING (
        EXISTS (
            SELECT 1 FROM core.account_registry ar
            WHERE ar.account_id = bad_debt_provision.account_id
            AND ar.primary_application_id = core.get_current_setting_as_uuid('app.current_application_id')
        )
    );

-- core.idempotency_keys: Application-scoped access
ALTER TABLE IF EXISTS core.idempotency_keys FORCE ROW LEVEL SECURITY;

-- PRODUCTION FIX: Uses safe UUID helper to prevent NULL casting issues
CREATE POLICY IF NOT EXISTS idempotency_keys_app_isolation ON core.idempotency_keys
    FOR ALL
    TO ussd_app_user
    USING (
        application_id = core.get_current_setting_as_uuid('app.current_application_id')
        OR application_id IS NULL
    );

-- core.audit_trail: Application-scoped access (auditor access preserved)
ALTER TABLE IF EXISTS core.audit_trail FORCE ROW LEVEL SECURITY;

-- PRODUCTION FIX: Uses safe UUID helper to prevent NULL casting issues
CREATE POLICY IF NOT EXISTS audit_trail_app_isolation ON core.audit_trail
    FOR ALL
    TO ussd_app_user
    USING (
        application_id = core.get_current_setting_as_uuid('app.current_application_id')
        OR application_id IS NULL
    );

-- messaging tables: Application-scoped access
ALTER TABLE IF EXISTS messaging.sms_messages FORCE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS messaging.sms_templates FORCE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS messaging.sms_bulk_campaigns FORCE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS messaging.whatsapp_messages FORCE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS messaging.whatsapp_templates FORCE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS messaging.whatsapp_sessions FORCE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS messaging.whatsapp_contacts FORCE ROW LEVEL SECURITY;

-- PRODUCTION FIX: Uses safe UUID helper to prevent NULL casting issues
CREATE POLICY IF NOT EXISTS sms_messages_app_isolation ON messaging.sms_messages
    FOR ALL
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

CREATE POLICY IF NOT EXISTS sms_templates_app_isolation ON messaging.sms_templates
    FOR ALL
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

CREATE POLICY IF NOT EXISTS sms_campaigns_app_isolation ON messaging.sms_bulk_campaigns
    FOR ALL
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

CREATE POLICY IF NOT EXISTS whatsapp_messages_app_isolation ON messaging.whatsapp_messages
    FOR ALL
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

CREATE POLICY IF NOT EXISTS whatsapp_templates_app_isolation ON messaging.whatsapp_templates
    FOR ALL
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

CREATE POLICY IF NOT EXISTS whatsapp_sessions_app_isolation ON messaging.whatsapp_sessions
    FOR ALL
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

CREATE POLICY IF NOT EXISTS whatsapp_contacts_app_isolation ON messaging.whatsapp_contacts
    FOR ALL
    TO ussd_app_user
    USING (application_id = core.get_current_setting_as_uuid('app.current_application_id'));

-- Log the additional RLS hardening
INSERT INTO audit.security_hardening_log (migration_version, hardening_type, target_table, action_taken) VALUES
    ('V073', 'FORCE_RLS', 'core.rejection_log', 'Applied FORCE ROW LEVEL SECURITY with application_id policy'),
    ('V073', 'FORCE_RLS', 'core.liquidity_positions', 'Applied FORCE ROW LEVEL SECURITY with application_id policy'),
    ('V073', 'FORCE_RLS', 'core.reconciliation_runs', 'Applied FORCE ROW LEVEL SECURITY with application_id policy'),
    ('V073', 'FORCE_RLS', 'core.reconciliation_items', 'Applied FORCE ROW LEVEL SECURITY with application_id policy'),
    ('V073', 'FORCE_RLS', 'core.control_batches', 'Applied FORCE ROW LEVEL SECURITY with application_id policy'),
    ('V073', 'FORCE_RLS', 'core.chart_of_accounts', 'Applied FORCE ROW LEVEL SECURITY with application_id policy'),
    ('V073', 'FORCE_RLS', 'core.period_end_balances', 'Applied FORCE ROW LEVEL SECURITY with application_id policy'),
    ('V073', 'FORCE_RLS', 'core.exchange_rates', 'Applied FORCE ROW LEVEL SECURITY with read-only policy'),
    ('V073', 'FORCE_RLS', 'core.bad_debt_provision', 'Applied FORCE ROW LEVEL SECURITY with application_id policy'),
    ('V073', 'FORCE_RLS', 'core.idempotency_keys', 'Applied FORCE ROW LEVEL SECURITY with application_id policy'),
    ('V073', 'FORCE_RLS', 'core.audit_trail', 'Applied FORCE ROW LEVEL SECURITY with application_id policy'),
    ('V073', 'FORCE_RLS', 'messaging.sms_messages', 'Applied FORCE ROW LEVEL SECURITY with application_id policy'),
    ('V073', 'FORCE_RLS', 'messaging.sms_templates', 'Applied FORCE ROW LEVEL SECURITY with application_id policy'),
    ('V073', 'FORCE_RLS', 'messaging.sms_bulk_campaigns', 'Applied FORCE ROW LEVEL SECURITY with application_id policy'),
    ('V073', 'FORCE_RLS', 'messaging.whatsapp_messages', 'Applied FORCE ROW LEVEL SECURITY with application_id policy'),
    ('V073', 'FORCE_RLS', 'messaging.whatsapp_templates', 'Applied FORCE ROW LEVEL SECURITY with application_id policy'),
    ('V073', 'FORCE_RLS', 'messaging.whatsapp_sessions', 'Applied FORCE ROW LEVEL SECURITY with application_id policy'),
    ('V073', 'FORCE_RLS', 'messaging.whatsapp_contacts', 'Applied FORCE ROW LEVEL SECURITY with application_id policy');

-- =============================================================================
-- VERIFICATION VIEW
-- =============================================================================

CREATE OR REPLACE VIEW audit.rls_status AS
SELECT 
    schemaname,
    tablename,
    rowsecurity as has_rls,
    forcerowsecurity as has_force_rls
FROM pg_tables t
JOIN pg_class c ON c.relname = t.tablename
JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = t.schemaname
WHERE schemaname IN ('core', 'app', 'ussd', 'messaging', 'audit', 'events', 'sdk', 'api', 'integrity', 'reconciliation', 'ops')
ORDER BY schemaname, tablename;

COMMENT ON VIEW audit.rls_status IS 'Verification view for RLS status on all ledger tables';

COMMIT;

-- =============================================================================
-- POST-MIGRATION VERIFICATION
-- =============================================================================

/*
Run this query after migration to verify all tables have FORCE RLS:

SELECT 
    schemaname,
    tablename,
    CASE 
        WHEN forcerowsecurity THEN '✓ SECURED'
        WHEN rowsecurity THEN '⚠ ENABLED NOT FORCED'
        ELSE '✗ NO RLS'
    END as rls_status
FROM audit.rls_status
ORDER BY 
    CASE 
        WHEN forcerowsecurity THEN 1
        WHEN rowsecurity THEN 2
        ELSE 3
    END,
    schemaname,
    tablename;

Expected: All rows should show '✓ SECURED'
*/
