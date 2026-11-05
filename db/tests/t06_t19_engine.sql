-- Engine tests (handbook Section 24): T06, T07, T08, T14, T16, T17, T18, T19 + refund rule.
-- Uses direct inserts as the owner; Phase 5 procedures will go through the same rules.
-- Runs in one transaction and rolls back: leaves no data.
-- Run: docker compose exec postgres psql -U tracepay_owner -d tracepay -f /db/tests/t06_t19_engine.sql
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

CREATE FUNCTION pg_temp.uid(p_email text) RETURNS bigint LANGUAGE sql AS
  $$ SELECT user_id FROM users WHERE email = p_email $$;
CREATE FUNCTION pg_temp.txn(p_ref text) RETURNS bigint LANGUAGE sql AS
  $$ SELECT txn_id FROM transactions WHERE external_ref = p_ref $$;

CREATE TEMP TABLE results (n serial, line text);

-- T06: bad registrations are rejected and leave nothing behind
INSERT INTO results (line) SELECT pg_temp.expect_error('T06a unknown column',
  $q$SELECT register_invariant('bad_one', 'accounts', 'account_id', 'no_such_col',
                               'account_freezes', 'account_id', 'frozen_amount')$q$, 'P0001');
INSERT INTO results (line) SELECT pg_temp.expect_error('T06b text quantity',
  $q$SELECT register_invariant('bad_two', 'accounts', 'account_id', 'balance',
                               'fraud_cases', 'customer_id', 'narrative')$q$, 'P0001');
INSERT INTO results (line) SELECT pg_temp.expect_error('T06c no foreign key',
  $q$SELECT register_invariant('bad_three', 'accounts', 'account_id', 'balance',
                               'refunds', 'allocation_id', 'amount')$q$, 'P0001');
INSERT INTO results (line) SELECT pg_temp.expect_error('T06d relation >=',
  $q$SELECT register_invariant('bad_four', 'accounts', 'account_id', 'balance',
                               'account_freezes', 'account_id', 'frozen_amount', '>=')$q$, 'P0001');

-- T07: six rules -> 6 definitions, 18 triggers, 24 functions (and no leftovers from T06)
INSERT INTO results (line)
SELECT CASE WHEN d = 6 AND t = 18 AND f = 24 THEN 'PASS' ELSE 'FAIL' END
       || format('  T07 engine objects: %s definitions, %s triggers, %s functions', d, t, f)
FROM (SELECT (SELECT count(*) FROM invariant_definitions) AS d,
             (SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'inv\_%') AS t,
             (SELECT count(*) FROM pg_proc WHERE proname LIKE 'inv\_%') AS f) x;

-- Fixture: C1 (V1 on T1) and C2 (V2 on T6)
INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative) VALUES
  (pg_temp.uid('v1@demo.in'), pg_temp.txn('T1'), 40000, 'Fake courier asked me to pay a customs fee by UPI.'),
  (pg_temp.uid('v2@demo.in'), pg_temp.txn('T6'), 20000, 'A parcel delivery agent said I owe customs duty.');
CREATE TEMP TABLE c AS
  SELECT (SELECT case_id FROM fraud_cases WHERE disputed_txn_id = pg_temp.txn('T1')) AS c1,
         (SELECT case_id FROM fraud_cases WHERE disputed_txn_id = pg_temp.txn('T6')) AS c2;

-- T08 txn_capacity: T4 is 10,000; C1 takes 7,000, C2 tries 4,000 -> excess 1,000
INSERT INTO results (line) SELECT pg_temp.expect_ok('T08a C1 attributes 7,000 of T4',
  format('INSERT INTO trace_nodes (case_id, txn_id, inflow_amount) VALUES (%s, %s, 7000)',
         (SELECT c1 FROM c), pg_temp.txn('T4')));
INSERT INTO results (line) SELECT pg_temp.expect_error('T08b C2 attributes 4,000 of T4',
  format('INSERT INTO trace_nodes (case_id, txn_id, inflow_amount) VALUES (%s, %s, 4000)',
         (SELECT c2 FROM c), pg_temp.txn('T4')), 'TP001');

-- T14 freeze_within_balance: D holds 12,000; freeze 10,000 OK, extra 5,000 rejected
INSERT INTO account_freezes (account_id, requested_for_case, requested_by, approved_by, frozen_amount,
                             status, approved_at, expires_at)
SELECT a.account_id, c.c1, pg_temp.uid('inv@demo.in'), pg_temp.uid('sup1@demo.in'), 10000,
       'ACTIVE', now(), now() + interval '7 days'
FROM accounts a, c WHERE a.account_ref = 'TP1000000006';
INSERT INTO results (line) VALUES ('PASS  T14a freeze 10,000 at D (balance 12,000)');
INSERT INTO results (line) SELECT pg_temp.expect_error('T14b second freeze 5,000 at D',
  format($q$INSERT INTO account_freezes (account_id, requested_for_case, requested_by, approved_by,
            frozen_amount, status, approved_at, expires_at)
            VALUES (%s, %s, %s, %s, 5000, 'ACTIVE', now(), now() + interval '7 days')$q$,
         (SELECT account_id FROM accounts WHERE account_ref = 'TP1000000006'), (SELECT c2 FROM c),
         pg_temp.uid('inv@demo.in'), pg_temp.uid('sup2@demo.in')), 'TP001');
CREATE TEMP TABLE f AS SELECT freeze_id FROM account_freezes;

-- T17a allocation_within_loss: C2 has NULL verified loss -> zero capacity
INSERT INTO results (line) SELECT pg_temp.expect_error('T17a allocate to C2 with NULL verified loss',
  format('INSERT INTO recovery_allocations (freeze_id, case_id, amount, allocated_by) VALUES (%s, %s, 1000, %s)',
         (SELECT freeze_id FROM f), (SELECT c2 FROM c), pg_temp.uid('sup1@demo.in')), 'TP001');

-- Verify losses: C1 40,000, C2 3,000
UPDATE fraud_cases SET verified_loss = 40000, verified_by = pg_temp.uid('sup1@demo.in') WHERE case_id = (SELECT c1 FROM c);
UPDATE fraud_cases SET verified_loss = 3000,  verified_by = pg_temp.uid('sup1@demo.in') WHERE case_id = (SELECT c2 FROM c);

-- T16 allocation_within_freeze: freeze 10,000; C1 6,000 OK; C2 6,000 -> excess 2,000 (the race outcome)
INSERT INTO results (line) SELECT pg_temp.expect_ok('T16a allocate 6,000 to C1',
  format('INSERT INTO recovery_allocations (freeze_id, case_id, amount, allocated_by) VALUES (%s, %s, 6000, %s)',
         (SELECT freeze_id FROM f), (SELECT c1 FROM c), pg_temp.uid('sup1@demo.in')));
INSERT INTO results (line) SELECT pg_temp.expect_error('T16b allocate 6,000 more (freeze is 10,000)',
  format('INSERT INTO recovery_allocations (freeze_id, case_id, amount, allocated_by) VALUES (%s, %s, 6000, %s)',
         (SELECT freeze_id FROM f), (SELECT c2 FROM c), pg_temp.uid('sup1@demo.in')), 'TP001');

-- T17b: 4,000 fits the freeze (4,000 left) but exceeds C2's verified loss of 3,000
INSERT INTO results (line) SELECT pg_temp.expect_error('T17b allocate 4,000 to C2 (loss 3,000)',
  format('INSERT INTO recovery_allocations (freeze_id, case_id, amount, allocated_by) VALUES (%s, %s, 4000, %s)',
         (SELECT freeze_id FROM f), (SELECT c2 FROM c), pg_temp.uid('sup1@demo.in')), 'TP001');

-- T18: lowering a freeze below its allocations is rejected
INSERT INTO results (line) SELECT pg_temp.expect_error('T18 lower freeze to 5,000 (6,000 allocated)',
  format('UPDATE account_freezes SET frozen_amount = 5000 WHERE freeze_id = %s', (SELECT freeze_id FROM f)), 'TP001');

-- refund_within_allocation: refund 7,000 on a 6,000 allocation
INSERT INTO results (line) SELECT pg_temp.expect_error('Refund 7,000 on a 6,000 allocation',
  format($q$INSERT INTO refunds (allocation_id, amount, idempotency_key, processed_by)
            VALUES ((SELECT allocation_id FROM recovery_allocations WHERE case_id = %s), 7000,
                    gen_random_uuid(), %s)$q$, (SELECT c1 FROM c), pg_temp.uid('sup1@demo.in')), 'TP001');

-- T19 verify_invariant: sneak in a bad row with triggers off, then find it
ALTER TABLE recovery_allocations DISABLE TRIGGER USER;
INSERT INTO recovery_allocations (freeze_id, case_id, amount, allocated_by)
SELECT freeze_id, (SELECT c2 FROM c), 9000, pg_temp.uid('sup1@demo.in') FROM f;
ALTER TABLE recovery_allocations ENABLE TRIGGER USER;
INSERT INTO results (line)
SELECT CASE WHEN v.limit_qty = 10000 AND v.child_total = 15000 AND v.excess = 5000 THEN 'PASS' ELSE 'FAIL' END
       || format('  T19 verify_invariant found freeze %s: limit %s, total %s, excess %s',
                 v.parent_key, v.limit_qty, v.child_total, v.excess)
FROM verify_invariant('allocation_within_freeze') v;

\set QUIET off
SELECT line AS result FROM results ORDER BY n;
ROLLBACK;
