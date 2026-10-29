-- Assertion helpers for the test database. A failed assertion raises an
-- exception; with ON_ERROR_STOP=1 psql then exits with a non-zero code.

CREATE OR REPLACE FUNCTION assert_eq(label TEXT, actual NUMERIC, expected NUMERIC)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'FAIL [%]: expected %, got %', label, expected, actual;
    END IF;
END $$;

CREATE OR REPLACE FUNCTION assert_text(label TEXT, actual TEXT, expected TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'FAIL [%]: expected %, got %', label, expected, actual;
    END IF;
END $$;

CREATE OR REPLACE FUNCTION assert_true(label TEXT, condition BOOLEAN)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF condition IS NOT TRUE THEN
        RAISE EXCEPTION 'FAIL [%]: condition is %', label, COALESCE(condition::TEXT, 'NULL');
    END IF;
END $$;

-- Runs a statement that must be rejected with the given SQLSTATE. The
-- statement runs in a subtransaction that is always rolled back, so a
-- wrongly accepted row never stays in the test database.
CREATE OR REPLACE FUNCTION assert_rejected(label TEXT, stmt TEXT, expected_sqlstate TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE stmt;
        RAISE EXCEPTION USING ERRCODE = 'P0099', MESSAGE = 'accepted';
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = expected_sqlstate THEN
            RETURN;
        ELSIF SQLSTATE = 'P0099' THEN
            RAISE EXCEPTION 'FAIL [%]: statement was accepted: %', label, stmt;
        END IF;
        RAISE EXCEPTION 'FAIL [%]: expected SQLSTATE %, got % (%)',
            label, expected_sqlstate, SQLSTATE, SQLERRM;
    END;
END $$;
