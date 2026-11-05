-- Recovery tests (handbook Section 24): full workflow through the procedures.
-- T14, T15, T16-T17 (via allocate_recovery), T21, T22 + assignment, traced cap, settlement.
-- Runs in one transaction and rolls back.
-- Run: docker compose exec postgres psql -U tracepay_owner -d tracepay -f /db/tests/t14_t22_recovery.sql
\set QUIET on
BEGIN;

CREATE FUNCTION pg_temp.expect_error(label text, stmt text, code text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v_detail text;
BEGIN
  EXECUTE stmt;
  RETURN 'FAIL  ' || label || '  (no error raised)';
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
  RETURN CASE WHEN SQLSTATE = code THEN 'PASS  ' ELSE 'FAIL  ' END || label
         || '  [' || SQLSTATE || '] ' || SQLERRM || coalesce('  | ' || NULLIF(v_detail, ''), '');
END $$;
CREATE FUNCTION pg_temp.expect_ok(label text, stmt text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE stmt;
  RETURN 'PASS  ' || label;
EXCEPTION WHEN OTHERS THEN
  RETURN 'FAIL  ' || label || '  got [' || SQLSTATE || '] ' || SQLERRM;
END $$;
CREATE FUNCTION pg_temp.check(label text, ok boolean, info text DEFAULT '') RETURNS text LANGUAGE sql AS
  $$ SELECT CASE WHEN ok THEN 'PASS  ' ELSE 'FAIL  ' END || label || CASE WHEN info <> '' THEN '  (' || info || ')' ELSE '' END $$;
CREATE FUNCTION pg_temp.act_as(p_email text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.user_id', user_id::text, true), set_config('app.user_role', role::text, true)
  FROM users WHERE email = p_email;
$$;
CREATE FUNCTION pg_temp.uid(p_email text) RETURNS bigint LANGUAGE sql AS
  $$ SELECT user_id FROM users WHERE email = p_email $$;
CREATE FUNCTION pg_temp.txn(p_ref text) RETURNS bigint LANGUAGE sql AS
  $$ SELECT txn_id FROM transactions WHERE external_ref = p_ref $$;
CREATE FUNCTION pg_temp.acct(p_ref text) RETURNS bigint LANGUAGE sql AS
  $$ SELECT account_id FROM accounts WHERE account_ref = p_ref $$;
CREATE TEMP TABLE results (n serial, line text);

-- Customers file C1 (V1 on T1) and C2 (V2 on T6)
INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative) VALUES
  (pg_temp.uid('v1@demo.in'), pg_temp.txn('T1'), 40000, 'Fake courier asked me to pay a customs fee by UPI.'),
  (pg_temp.uid('v2@demo.in'), pg_temp.txn('T6'), 20000, 'A parcel delivery agent said I owe customs duty.');
CREATE TEMP TABLE c AS
  SELECT (SELECT case_id FROM fraud_cases WHERE disputed_txn_id = pg_temp.txn('T1')) AS c1,
         (SELECT case_id FROM fraud_cases WHERE disputed_txn_id = pg_temp.txn('T6')) AS c2;

-- Assignment
SELECT pg_temp.act_as('sup1@demo.in') \g /dev/null
INSERT INTO results (line) SELECT pg_temp.expect_error('assign_case to a non-investigator',
  format('CALL assign_case(%s, %s, %s)', c1, pg_temp.uid('sup2@demo.in'), pg_temp.uid('sup1@demo.in')), 'TP002') FROM c;
INSERT INTO results (line) SELECT pg_temp.expect_ok('assign_case C1 and C2 to the investigator',
  format('CALL assign_case(%s, %s, %s); CALL assign_case(%s, %s, %s)',
         c1, pg_temp.uid('inv@demo.in'), pg_temp.uid('sup1@demo.in'),
         c2, pg_temp.uid('inv@demo.in'), pg_temp.uid('sup1@demo.in'))) FROM c;
INSERT INTO results (line) SELECT pg_temp.expect_ok('reassign C1 (closes the old assignment)',
  format('CALL assign_case(%s, %s, %s)', c1, pg_temp.uid('inv@demo.in'), pg_temp.uid('sup2@demo.in'))) FROM c;
INSERT INTO results (line)
SELECT pg_temp.check('one open assignment, 2 in history, status UNDER_REVIEW',
  (SELECT count(*) FROM case_assignments WHERE case_id = c1 AND ended_at IS NULL) = 1
  AND (SELECT count(*) FROM case_assignments WHERE case_id = c1) = 2
  AND (SELECT status FROM fraud_cases WHERE case_id = c1) = 'UNDER_REVIEW') FROM c;

-- Investigation and trace: C1 traces 7,000 to D via T4; C2 traces 3,000 to D
SELECT pg_temp.act_as('inv@demo.in') \g /dev/null
UPDATE fraud_cases SET status = 'INVESTIGATING' WHERE case_id IN (SELECT c1 FROM c UNION SELECT c2 FROM c);
DO $$ DECLARE c1 bigint; c2 bigint; inv bigint := pg_temp.uid('inv@demo.in');
BEGIN
  SELECT x.c1, x.c2 INTO c1, c2 FROM c x;
  CALL start_trace(c1); CALL start_trace(c2);
  CALL confirm_link(c1, pg_temp.txn('T1'), pg_temp.txn('T2'), 25000, 'MANUAL', inv);
  CALL confirm_link(c1, pg_temp.txn('T2'), pg_temp.txn('T4'), 7000,  'MANUAL', inv);
  CALL confirm_link(c2, pg_temp.txn('T6'), pg_temp.txn('T4'), 3000,  'MANUAL', inv);
END $$;

-- Freezes
INSERT INTO results (line) SELECT pg_temp.expect_error('request_freeze on an account not on the trace',
  format('SELECT request_freeze(%s, %s, 1000, %s)', c1, pg_temp.acct('TP1000000002'), pg_temp.uid('inv@demo.in')), 'TP002') FROM c;
CREATE TEMP TABLE fz AS SELECT request_freeze(c1, pg_temp.acct('TP1000000006'), 10000, pg_temp.uid('inv@demo.in')) AS f1 FROM c;
INSERT INTO results (line) SELECT pg_temp.expect_error('T15 four-eyes: requester approves own freeze',
  format('CALL decide_freeze(%s, true, %s)', f1, pg_temp.uid('inv@demo.in')), '23514') FROM fz;
SELECT pg_temp.act_as('sup1@demo.in') \g /dev/null
INSERT INTO results (line) SELECT pg_temp.expect_ok('supervisor approves 10,000 freeze at D',
  format('CALL decide_freeze(%s, true, %s)', f1, pg_temp.uid('sup1@demo.in'))) FROM fz;
INSERT INTO fz (f1) SELECT request_freeze(c2, pg_temp.acct('TP1000000006'), 5000, pg_temp.uid('inv@demo.in')) FROM c;
INSERT INTO results (line) SELECT pg_temp.expect_error('T14 approve a further 5,000 at D (balance 12,000)',
  format('CALL decide_freeze(%s, true, %s)', max(f1), pg_temp.uid('sup1@demo.in')), 'TP001') FROM fz;
INSERT INTO results (line) SELECT pg_temp.expect_ok('decline that request instead',
  format('CALL decide_freeze(%s, false, %s)', max(f1), pg_temp.uid('sup1@demo.in'))) FROM fz;
DELETE FROM fz WHERE f1 = (SELECT max(f1) FROM fz);

-- Verify loss, move to RECOVERY
INSERT INTO results (line) SELECT pg_temp.expect_error('allocate before RECOVERY',
  format('SELECT allocate_recovery(%s, %s, 1000, %s)', f1, c1, pg_temp.uid('sup1@demo.in')), 'TP002') FROM fz, c;
DO $$ DECLARE c1 bigint; c2 bigint; s bigint := pg_temp.uid('sup1@demo.in');
BEGIN
  SELECT x.c1, x.c2 INTO c1, c2 FROM c x;
  CALL verify_loss(c1, 40000, s); CALL verify_loss(c2, 2000, s);
END $$;
UPDATE fraud_cases SET status = 'RECOVERY' WHERE case_id IN (SELECT c1 FROM c UNION SELECT c2 FROM c);

-- Allocation
INSERT INTO results (line) SELECT pg_temp.expect_error('allocate 8,000 to C1 (only 7,000 traced to D)',
  format('SELECT allocate_recovery(%s, %s, 8000, %s)', f1, c1, pg_temp.uid('sup1@demo.in')), 'TP001') FROM fz, c;
INSERT INTO results (line) SELECT pg_temp.expect_error('T17 allocate 3,000 to C2 (verified loss 2,000)',
  format('SELECT allocate_recovery(%s, %s, 3000, %s)', f1, c2, pg_temp.uid('sup1@demo.in')), 'TP001') FROM fz, c;
CREATE TEMP TABLE al AS
  SELECT allocate_recovery(f1, c1, 7000, pg_temp.uid('sup1@demo.in')) AS a1,
         allocate_recovery(f1, c2, 2000, pg_temp.uid('sup1@demo.in')) AS a2 FROM fz, c;
INSERT INTO results (line) VALUES ('PASS  allocate 7,000 to C1 and 2,000 to C2 (9,000 of 10,000)');

-- T21 idempotent refund
CREATE TEMP TABLE r AS
  SELECT process_refund(a1, 7000, 'aaaaaaaa-0000-0000-0000-000000000001', pg_temp.uid('sup1@demo.in')) AS first,
         process_refund(a1, 7000, 'aaaaaaaa-0000-0000-0000-000000000001', pg_temp.uid('sup1@demo.in')) AS replay
  FROM al;
INSERT INTO results (line)
SELECT pg_temp.check('T21 same idempotency key twice -> one refund, same id',
  first = replay AND (SELECT count(*) FROM refunds) = 1, 'ids ' || first || ', ' || replay) FROM r;
INSERT INTO results (line)
SELECT pg_temp.check('fully refunded allocation becomes PAID',
  (SELECT status FROM recovery_allocations WHERE allocation_id = a1) = 'PAID') FROM al;
INSERT INTO results (line) SELECT pg_temp.expect_error('refund 2,500 on a 2,000 allocation',
  format('SELECT process_refund(%s, 2500, gen_random_uuid(), %s)', a2, pg_temp.uid('sup1@demo.in')), 'TP001') FROM al;
INSERT INTO results (line) SELECT pg_temp.expect_ok('partial refund 500 to C2',
  format('SELECT process_refund(%s, 500, gen_random_uuid(), %s)', a2, pg_temp.uid('sup1@demo.in'))) FROM al;

-- Settlement: C2's allocation shrinks to 500 paid; freeze SETTLED; D debited 7,500
CREATE TEMP TABLE st AS SELECT settle_freeze(f1, pg_temp.uid('sup1@demo.in')) AS paid FROM fz;
INSERT INTO results (line)
SELECT pg_temp.check('settle_freeze pays out 7,500 and debits D to 4,500',
  st.paid = 7500
  AND (SELECT balance FROM accounts WHERE account_ref = 'TP1000000006') = 4500
  AND (SELECT status FROM account_freezes WHERE freeze_id = f1) = 'SETTLED'
  AND (SELECT amount FROM recovery_allocations WHERE allocation_id = a2) = 500,
  'paid ' || st.paid || ', D balance ' || (SELECT balance FROM accounts WHERE account_ref = 'TP1000000006'))
FROM st, fz, al;

-- T22 lazy expiry: an ACTIVE freeze whose expires_at has passed
INSERT INTO account_freezes (account_id, requested_for_case, requested_by, approved_by, frozen_amount,
                             status, approved_at, expires_at)
SELECT pg_temp.acct('TP1000000004'), c1, pg_temp.uid('inv@demo.in'), pg_temp.uid('sup1@demo.in'), 5000,
       'ACTIVE', now() - interval '2 days', now() - interval '1 day' FROM c;
CREATE TEMP TABLE fx AS SELECT max(freeze_id) AS f FROM account_freezes;
INSERT INTO results (line) SELECT pg_temp.expect_error('T22a allocate on an expired freeze',
  format('SELECT allocate_recovery(%s, %s, 1000, %s)', f, c1, pg_temp.uid('sup1@demo.in')), 'TP002') FROM fx, c;
CALL expire_freezes();
INSERT INTO results (line)
SELECT pg_temp.check('T22b sweep marks it EXPIRED', (SELECT status FROM account_freezes WHERE freeze_id = f) = 'EXPIRED') FROM fx;

-- Every engine rule still holds after the whole workflow
INSERT INTO results (line)
SELECT pg_temp.check('all six invariants verify clean',
  NOT EXISTS (SELECT 1 FROM invariant_definitions d, verify_invariant(d.name)));
INSERT INTO results (line)
SELECT pg_temp.check('audit trail recorded the workflow', count(*) > 10, count(*) || ' audit rows') FROM audit_log;

\set QUIET off
SELECT line AS result FROM results ORDER BY n;
ROLLBACK;
