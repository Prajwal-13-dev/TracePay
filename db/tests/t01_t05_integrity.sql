-- Tests T01-T05 (handbook Section 24). Runs inside one transaction and rolls back: leaves no data.
-- Run: docker compose exec postgres psql -U tracepay_owner -d tracepay -f /db/tests/t01_t05_integrity.sql
\set QUIET on
BEGIN;

CREATE FUNCTION pg_temp.expect_error(label text, stmt text, code text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE stmt;
  RETURN 'FAIL  ' || label || '  (no error raised)';
EXCEPTION WHEN OTHERS THEN
  IF SQLSTATE = code THEN RETURN 'PASS  ' || label || '  [' || SQLSTATE || '] ' || SQLERRM;
  ELSE RETURN 'FAIL  ' || label || '  got [' || SQLSTATE || '] ' || SQLERRM; END IF;
END $$;

CREATE FUNCTION pg_temp.expect_ok(label text, stmt text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE stmt;
  RETURN 'PASS  ' || label;
EXCEPTION WHEN OTHERS THEN
  RETURN 'FAIL  ' || label || '  got [' || SQLSTATE || '] ' || SQLERRM;
END $$;

CREATE FUNCTION pg_temp.act_as(p_email text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.user_id', user_id::text, true), set_config('app.user_role', role::text, true)
  FROM users WHERE email = p_email;
$$;

CREATE TEMP TABLE results (n serial, line text);

-- T01 schema CHECKs
INSERT INTO results (line) SELECT pg_temp.expect_error('T01a negative amount',
  $q$INSERT INTO transactions (external_ref, source_account_id, destination_account_id, amount, channel, occurred_at)
     VALUES ('X1', 1, 2, -5, 'UPI', now())$q$, '23514');
INSERT INTO results (line) SELECT pg_temp.expect_error('T01b source = destination',
  $q$INSERT INTO transactions (external_ref, source_account_id, destination_account_id, amount, channel, occurred_at)
     VALUES ('X2', 1, 1, 5, 'UPI', now())$q$, '23514');

-- T02 transfers are immutable
INSERT INTO results (line) SELECT pg_temp.expect_error('T02a update a transfer',
  $q$UPDATE transactions SET amount = 1 WHERE external_ref = 'T1'$q$, 'TP004');
INSERT INTO results (line) SELECT pg_temp.expect_error('T02b delete a transfer',
  $q$DELETE FROM transactions WHERE external_ref = 'T1'$q$, 'TP004');

-- T03 cannot report someone else's transfer (V2 reports T1, paid by V1)
INSERT INTO results (line) SELECT pg_temp.expect_error('T03 complaint on another person''s transfer',
  $q$INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative)
     VALUES ((SELECT user_id FROM users WHERE email='v2@demo.in'),
             (SELECT txn_id FROM transactions WHERE external_ref='T1'),
             1000, 'Someone else paid this transfer, not me at all.')$q$, 'TP005');

-- T04 amount above transfer; then a valid case; then a duplicate case on the same transfer
INSERT INTO results (line) SELECT pg_temp.expect_error('T04a reported amount > transfer amount',
  $q$INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative)
     VALUES ((SELECT user_id FROM users WHERE email='v1@demo.in'),
             (SELECT txn_id FROM transactions WHERE external_ref='T1'),
             50000, 'Fake courier asked me to pay a customs fee by UPI.')$q$, 'TP005');
INSERT INTO results (line) SELECT pg_temp.expect_ok('T04b valid complaint C1 by V1 on T1',
  $q$INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative)
     VALUES ((SELECT user_id FROM users WHERE email='v1@demo.in'),
             (SELECT txn_id FROM transactions WHERE external_ref='T1'),
             40000, 'Fake courier asked me to pay a customs fee by UPI.')$q$);
INSERT INTO results (line) SELECT pg_temp.expect_error('T04c second case on the same transfer',
  $q$INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative)
     VALUES ((SELECT user_id FROM users WHERE email='v1@demo.in'),
             (SELECT txn_id FROM transactions WHERE external_ref='T1'),
             100, 'Trying to file the same transfer a second time.')$q$, '23505');

-- T05 state machine
SELECT pg_temp.act_as('inv@demo.in');
INSERT INTO results (line) SELECT pg_temp.expect_error('T05a investigator SUBMITTED -> RECOVERY',
  $q$UPDATE fraud_cases SET status = 'RECOVERY'
     WHERE disputed_txn_id = (SELECT txn_id FROM transactions WHERE external_ref='T1')$q$, 'TP003');
SELECT pg_temp.act_as('sup1@demo.in');
INSERT INTO results (line) SELECT pg_temp.expect_ok('T05b supervisor SUBMITTED -> UNDER_REVIEW',
  $q$UPDATE fraud_cases SET status = 'UNDER_REVIEW'
     WHERE disputed_txn_id = (SELECT txn_id FROM transactions WHERE external_ref='T1')$q$);
SELECT pg_temp.act_as('inv@demo.in');
INSERT INTO results (line) SELECT pg_temp.expect_ok('T05c investigator UNDER_REVIEW -> INVESTIGATING',
  $q$UPDATE fraud_cases SET status = 'INVESTIGATING'
     WHERE disputed_txn_id = (SELECT txn_id FROM transactions WHERE external_ref='T1')$q$);
SELECT pg_temp.act_as('sup1@demo.in');
INSERT INTO results (line) SELECT pg_temp.expect_error('T05d supervisor -> RECOVERY with NULL verified loss',
  $q$UPDATE fraud_cases SET status = 'RECOVERY'
     WHERE disputed_txn_id = (SELECT txn_id FROM transactions WHERE external_ref='T1')$q$, 'TP003');

-- Side effects: history and audit rows written; sign-up cannot create staff
INSERT INTO results (line)
SELECT CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'FAIL' END || '  status history has 2 rows (got ' || count(*) || ')'
FROM case_status_history;
INSERT INTO results (line)
SELECT CASE WHEN count(*) >= 3 THEN 'PASS' ELSE 'FAIL' END || '  audit_log recorded case changes (got ' || count(*) || ')'
FROM audit_log WHERE entity_type = 'fraud_cases';
RESET app.allow_staff_insert;
INSERT INTO users (email, full_name, password_hash, role)
VALUES ('hacker@demo.in', 'Hacker', '$2b$12$' || repeat('x', 53), 'SUPERVISOR');
INSERT INTO results (line)
SELECT CASE WHEN role = 'CUSTOMER' THEN 'PASS' ELSE 'FAIL' END || '  sign-up forced to CUSTOMER (got ' || role || ')'
FROM users WHERE email = 'hacker@demo.in';

\set QUIET off
SELECT line AS result FROM results ORDER BY n;
ROLLBACK;
