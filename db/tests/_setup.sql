-- Shared test harness. Every test file starts with  \ir _setup.sql  and ends with  \ir _report.sql.
-- Everything runs in ONE transaction that is rolled back at the end: a test run leaves no data behind.
-- A broken statement (a typo in a test) is reported as ERROR and counted as a failure by the runner,
-- without aborting the rest of the file (ON_ERROR_ROLLBACK).
--
-- Helpers (all record a PASS/FAIL line in the results table):
--   pg_temp.ok(label, sql)            the statement must succeed
--   pg_temp.fails(label, sql, code)   the statement must fail with this SQLSTATE (e.g. TP001, 23514)
--   pg_temp.check(label, cond, info)  the condition must be true; info is printed next to it
--   pg_temp.act_as(email)             later statements act as this user (sets app.user_id, like the API)
--   pg_temp.uid(email) / txn(ref) / acct(ref) / bal(ref)   look up ids and balances
-- Fixture ids are kept in psql variables with \gset (e.g. :c1) and passed into format(...).
\set QUIET on
\set ON_ERROR_ROLLBACK on
\o /dev/null
BEGIN;
CREATE TEMP TABLE results (n serial, line text);

CREATE FUNCTION pg_temp.ok(label text, stmt text) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  BEGIN
    EXECUTE stmt;
    INSERT INTO results (line) VALUES ('PASS  ' || label);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO results (line) VALUES ('FAIL  ' || label || '  got [' || SQLSTATE || '] ' || SQLERRM);
  END;
END $f$;

CREATE FUNCTION pg_temp.fails(label text, stmt text, code text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v_detail text;
BEGIN
  BEGIN
    EXECUTE stmt;
    INSERT INTO results (line) VALUES ('FAIL  ' || label || '  (no error raised)');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
    INSERT INTO results (line)
    VALUES (CASE WHEN SQLSTATE = code THEN 'PASS  ' ELSE 'FAIL  ' END || label || '  [' || SQLSTATE || '] ' || SQLERRM
            || CASE WHEN SQLSTATE = code THEN '' ELSE ' (expected ' || code || ')' END
            || CASE WHEN SQLSTATE LIKE 'TP%' THEN coalesce('  | ' || NULLIF(v_detail, ''), '') ELSE '' END);
  END;
END $f$;

CREATE FUNCTION pg_temp.check(label text, cond boolean, info text DEFAULT '') RETURNS void LANGUAGE sql AS $f$
  INSERT INTO results (line)
  VALUES (CASE WHEN coalesce(cond, false) THEN 'PASS  ' ELSE 'FAIL  ' END || label
          || CASE WHEN coalesce(info, '') <> '' THEN '  (' || info || ')' ELSE '' END);
$f$;

CREATE FUNCTION pg_temp.act_as(p_email text) RETURNS void LANGUAGE sql AS $f$
  SELECT set_config('app.user_id', coalesce((SELECT user_id::text FROM users WHERE email = p_email), ''), true);
  SELECT set_config('app.user_role', '', true);
$f$;
CREATE FUNCTION pg_temp.uid(p_email text) RETURNS bigint LANGUAGE sql AS $f$ SELECT user_id FROM users WHERE email = p_email $f$;
CREATE FUNCTION pg_temp.txn(p_ref text) RETURNS bigint LANGUAGE sql AS $f$ SELECT txn_id FROM transactions WHERE external_ref = p_ref $f$;
CREATE FUNCTION pg_temp.acct(p_ref text) RETURNS bigint LANGUAGE sql AS $f$ SELECT account_id FROM accounts WHERE account_ref = p_ref $f$;
CREATE FUNCTION pg_temp.bal(p_ref text) RETURNS numeric LANGUAGE sql AS $f$ SELECT balance FROM accounts WHERE account_ref = p_ref $f$;

-- Demo scenario (db/seed/010_scenario.sql), used by every file:
--   V1 TP1000000001, V2 ...02, A ...03, B ...04, C ...05, D ...06 (balance 12,000), E ...07
--   T1 V1->A 40,000 10:00 · T2 A->B 25,000 10:20 · T3 A->C 15,000 10:25 · T4 B->D 10,000 11:00
--   T5 B->A 8,000 11:10 · T6 V2->B 20,000 10:40 · T7 A->E 5,000 11:30 · T8 V1->mule01 3,000 (no case)
