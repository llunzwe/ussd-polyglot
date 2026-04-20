-- =============================================================================
-- Migration: V160__functions_balance_ops
-- Description: functions: balance_ops
-- Dependencies: V159
-- Generated: 2026-04-02 16:56:48 UTC
-- =============================================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET check_function_bodies = false;

BEGIN;

-- ============================================================================
-- Balance Operations and Calculations
-- ============================================================================

-- Function: Calculate account balance as of date
CREATE OR REPLACE FUNCTION core.get_balance_as_of(
    p_account_id UUID,
    p_as_of_date DATE
)
RETURNS DECIMAL(19,4)
LANGUAGE plpgsql
STABLE
SET search_path = core, public
AS $$
DECLARE
    v_balance DECIMAL(19,4);
BEGIN
    SELECT COALESCE(SUM(
        CASE 
            WHEN mp.side = 'CREDIT' THEN mp.amount
            WHEN mp.side = 'DEBIT' THEN -mp.amount
            ELSE 0
        END
    ), 0) INTO v_balance
    FROM core.movement_postings mp
    WHERE mp.account_id = p_account_id
    AND mp.value_date <= p_as_of_date;

    RETURN v_balance;
END;
$$;

COMMENT ON FUNCTION core.get_balance_as_of IS 'Calculates account balance as of specific date';

-- Function: Get period-end balance
CREATE OR REPLACE FUNCTION core.get_period_balance(
    p_account_id UUID,
    p_fiscal_period_id UUID
)
RETURNS TABLE (
    opening_balance DECIMAL(19,4),
    total_credits DECIMAL(19,4),
    total_debits DECIMAL(19,4),
    closing_balance DECIMAL(19,4)
)
LANGUAGE plpgsql
STABLE
SET search_path = core, public
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        peb.opening_balance,
        peb.total_credits,
        peb.total_debits,
        peb.closing_balance
    FROM core.period_end_balances peb
    WHERE peb.account_id = p_account_id
    AND peb.fiscal_period_id = p_fiscal_period_id;
END;
$$;

COMMENT ON FUNCTION core.get_period_balance IS 'Gets fiscal period balance for an account';

-- Function: Calculate daily balances
CREATE OR REPLACE FUNCTION core.calculate_daily_balances(
    p_account_id UUID,
    p_from_date DATE,
    p_to_date DATE
)
RETURNS TABLE (
    balance_date DATE,
    opening_balance DECIMAL(19,4),
    daily_credits DECIMAL(19,4),
    daily_debits DECIMAL(19,4),
    closing_balance DECIMAL(19,4)
)
LANGUAGE plpgsql
STABLE
SET search_path = core, public
AS $$
BEGIN
    RETURN QUERY
    WITH date_range AS (
        SELECT generate_series(p_from_date, p_to_date, '1 day'::interval)::date AS d
    ),
    daily_movements AS (
        SELECT 
            mp.value_date,
            SUM(CASE WHEN mp.side = 'CREDIT' THEN mp.amount ELSE 0 END) AS credits,
            SUM(CASE WHEN mp.side = 'DEBIT' THEN mp.amount ELSE 0 END) AS debits
        FROM core.movement_postings mp
        WHERE mp.account_id = p_account_id
        AND mp.value_date BETWEEN p_from_date AND p_to_date
        GROUP BY mp.value_date
    ),
    balance_calc AS (
        SELECT 
            dr.d,
            core.get_balance_as_of(p_account_id, dr.d - 1) AS opening,
            COALESCE(dm.credits, 0) AS day_credits,
            COALESCE(dm.debits, 0) AS day_debits
        FROM date_range dr
        LEFT JOIN daily_movements dm ON dr.d = dm.value_date
    )
    SELECT 
        d,
        opening,
        day_credits,
        day_debits,
        opening + day_credits - day_debits
    FROM balance_calc
    ORDER BY d;
END;
$$;

COMMENT ON FUNCTION core.calculate_daily_balances IS 'Calculates daily balance movements for date range';

-- Function: Update period-end balances
CREATE OR REPLACE FUNCTION core.close_fiscal_period(
    p_fiscal_period_id UUID,
    p_application_id UUID DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_closed_count INTEGER := 0;
    v_account RECORD;
    v_opening DECIMAL(19,4);
    v_credits DECIMAL(19,4);
    v_debits DECIMAL(19,4);
    v_closing DECIMAL(19,4);
BEGIN
    FOR v_account IN
        SELECT account_id, currency_code
        FROM core.account_registry
        WHERE is_current = TRUE
        AND application_id = COALESCE(p_application_id, current_setting('app.current_account_id', true)::UUID)
    LOOP
        -- Calculate period totals
        SELECT 
            COALESCE(SUM(CASE WHEN mp.side = 'CREDIT' THEN mp.amount ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN mp.side = 'DEBIT' THEN mp.amount ELSE 0 END), 0)
        INTO v_credits, v_debits
        FROM core.movement_postings mp
        JOIN core.fiscal_periods fp ON mp.value_date BETWEEN fp.period_start AND fp.period_end
        WHERE mp.account_id = v_account.account_id
        AND fp.fiscal_period_id = p_fiscal_period_id;

        -- Get opening balance from previous period
        SELECT closing_balance INTO v_opening
        FROM core.period_end_balances
        WHERE account_id = v_account.account_id
        AND fiscal_period_id = (
            SELECT fiscal_period_id FROM core.fiscal_periods
            WHERE period_end < (SELECT period_start FROM core.fiscal_periods WHERE fiscal_period_id = p_fiscal_period_id)
            ORDER BY period_end DESC
            LIMIT 1
        );

        v_opening := COALESCE(v_opening, 0);
        v_closing := v_opening + v_credits - v_debits;

        -- Insert or update period balance
        INSERT INTO core.period_end_balances (
            balance_id, account_id, fiscal_period_id, opening_balance,
            closing_balance, total_credits, total_debits, currency_code,
            reconciliation_status, ifrs_compliant, record_hash, application_id,
            created_at, created_by
        ) VALUES (
            gen_random_uuid(),
            v_account.account_id,
            p_fiscal_period_id,
            v_opening,
            v_closing,
            v_credits,
            v_debits,
            v_account.currency_code,
            'PENDING',
            TRUE,
            encode(digest(v_account.account_id::text || now()::text, 'sha256'), 'hex'),
            COALESCE(p_application_id, current_setting('app.current_account_id', true)::UUID),
            now(),
            current_user
        )
        ON CONFLICT (account_id, fiscal_period_id) DO UPDATE SET
            closing_balance = EXCLUDED.closing_balance,
            total_credits = EXCLUDED.total_credits,
            total_debits = EXCLUDED.total_debits,
            updated_at = now();

        v_closed_count := v_closed_count + 1;
    END LOOP;

    RETURN v_closed_count;
END;
$$;

COMMENT ON FUNCTION core.close_fiscal_period IS 'Calculates and stores period-end balances for all accounts';

COMMIT;
