#!/bin/bash
# =============================================================================
# USSD Kernel Engine Immutable Ledger - Database Deployment Script
# =============================================================================
# This script deploys all 73 SQL migration files to a PostgreSQL database
# with TimescaleDB extension.
#
# Usage: ./deploy.sh <database_url>
# Example: ./deploy.sh postgres://user:pass@localhost:5432/ussd_ledger
# =============================================================================

set -e

DB_URL="${1:-postgres://postgres:postgres@localhost:5432/ussd_ledger}"
MIGRATIONS_DIR="$(dirname "$0")"

echo "============================================================================="
echo "USSD Kernel Engine Immutable Ledger - Database Deployment"
echo "============================================================================="
echo "Database: $DB_URL"
echo "Migrations: $MIGRATIONS_DIR"
echo "============================================================================="
echo ""

# Check if psql is available
if ! command -v psql &> /dev/null; then
    echo "ERROR: psql is not installed or not in PATH"
    exit 1
fi

# Check database connection
echo "Checking database connection..."
if ! psql "$DB_URL" -c "SELECT 1;" > /dev/null 2>&1; then
    echo "ERROR: Cannot connect to database"
    exit 1
fi
echo "Database connection successful!"
echo ""

# Create extensions
echo "Creating extensions..."
psql "$DB_URL" -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"
psql "$DB_URL" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
psql "$DB_URL" -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"
echo "Extensions created successfully!"
echo ""

# Run migrations in order
echo "Running migrations..."
echo "============================================================================="

for migration in "$MIGRATIONS_DIR"/V*.sql; do
    filename=$(basename "$migration")
    echo "Applying: $filename"

    if psql "$DB_URL" -f "$migration" > /dev/null 2>&1; then
        echo "  ✓ Success"
    else
        echo "  ✗ Failed"
        echo "ERROR: Migration $filename failed"
        exit 1
    fi
done

echo "============================================================================="
echo ""
echo "All migrations applied successfully!"
echo ""
echo "============================================================================="
echo "Post-Deployment Verification"
echo "============================================================================="

# Verify schemas
psql "$DB_URL" -c "\dn"

# Verify RLS status
echo ""
echo "RLS Status (should all be SECURED):"
psql "$DB_URL" -c "
SELECT 
    schemaname,
    tablename,
    CASE 
        WHEN forcerowsecurity THEN '✓ SECURED'
        WHEN rowsecurity THEN '⚠ ENABLED NOT FORCED'
        ELSE '✗ NO RLS'
    END as rls_status
FROM pg_tables t
JOIN pg_class c ON c.relname = t.tablename
JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = t.schemaname
WHERE schemaname IN ('core', 'app', 'ussd', 'messaging', 'audit', 'events', 'sdk', 'api', 'integrity', 'reconciliation', 'ops')
ORDER BY schemaname, tablename;
"

echo ""
echo "============================================================================="
echo "Deployment Complete!"
echo "============================================================================="
