-- 05 recovery (005_recovery.sql): assignment, verification, freezes, allocation, refunds, settlement,
-- release, expiry and hand-back, run through the procedures exactly as the app calls them.
-- Run: docker compose exec postgres psql -U tracepay_owner -d tracepay -f /db/tests/05_recovery.sql
\ir _setup.sql

-- Fixture: C1 (V1 on T1, 40,000) and C2 (V2 on T6, 20,000)
INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative) VALUES
  (pg_temp.uid('v1@demo.in'), pg_temp.txn('T1'), 40000, 'Fake courier asked me to pay a customs fee by UPI.'),
  (pg_temp.uid('v2@demo.in'), pg_temp.txn('T6'), 20000, 'A parcel delivery agent said I owe customs duty.');
SELECT (SELECT case_id FROM fraud_cases WHERE disputed_txn_id = pg_temp.txn('T1')) AS c1,
       (SELECT case_id FROM fraud_cases WHERE disputed_txn_id = pg_temp.txn('T6')) AS c2,
       pg_temp.uid('inv@demo.in') AS inv, pg_temp.acct('TP1000000006') AS acct_d, pg_temp.acct('TP1000000004') AS acct_b \gset

-- Assignment (supervisors only)
SELECT pg_temp.act_as('inv@demo.in');
SELECT pg_temp.fails('an investigator cannot assign cases', format('CALL assign_case(%s, %s, 0)', :c1, :inv), 'TP002');
SELECT pg_temp.act_as('sup1@demo.in');
SELECT pg_temp.fails('the assignee must be an investigator', format('CALL assign_case(%s, %s, 0)', :c1, pg_temp.uid('sup2@demo.in')), 'TP002');
SELECT pg_temp.ok('assign C1 and C2 to the investigator', format('CALL assign_case(%s, %s, 0); CALL assign_case(%s, %s, 0)', :c1, :inv, :c2, :inv));
SELECT pg_temp.act_as('sup2@demo.in');
SELECT pg_temp.ok('reassign C1 (closes the old assignment)', format('CALL assign_case(%s, %s, 0)', :c1, :inv));
SELECT pg_temp.check('C1: one open assignment, 2 in its history, status UNDER_REVIEW',
  (SELECT count(*) FROM case_assignments WHERE case_id = :c1 AND ended_at IS NULL) = 1
  AND (SELECT count(*) FROM case_assignments WHERE case_id = :c1) = 2
  AND (SELECT status FROM fraud_cases WHERE case_id = :c1) = 'UNDER_REVIEW');

-- Investigation: C1 traces 7,000 to D via T2 -> T4; C2 traces 3,000 to D
SELECT pg_temp.act_as('inv@demo.in');
UPDATE fraud_cases SET status = 'INVESTIGATING' WHERE case_id IN (:c1, :c2);
SELECT pg_temp.ok('trace C1 (T1 -> T2 25,000 -> T4 7,000) and C2 (T6 -> T4 3,000)',
  format('CALL start_trace(%1$s); CALL start_trace(%2$s);
          CALL confirm_link(%1$s, %3$s, %4$s, 25000, %6$L, 0); CALL confirm_link(%1$s, %4$s, %5$s, 7000, %6$L, 0);
          CALL confirm_link(%2$s, %7$s, %5$s, 3000, %6$L, 0)',
         :c1, :c2, pg_temp.txn('T1'), pg_temp.txn('T2'), pg_temp.txn('T4'), 'MANUAL', pg_temp.txn('T6')));
SELECT pg_temp.fails('hand-back is refused once links are confirmed',
  format('CALL hand_back_case(%s, %L)', :c1, 'I know the customer personally'), 'TP002');

-- Freezes: requested by the assigned investigator, decided by a supervisor
SELECT pg_temp.fails('a freeze on an account the trace never reached (V2''s)',
  format('SELECT request_freeze(%s, %s, 1000, 0)', :c1, pg_temp.acct('TP1000000002')), 'TP002');
SELECT request_freeze(:c1, :acct_d, 10000, 0) AS f1 \gset
SELECT pg_temp.fails('a second open request for the same case and account',
  format('SELECT request_freeze(%s, %s, 1000, 0)', :c1, :acct_d), 'TP002');
UPDATE accounts SET status = 'CLOSED' WHERE account_id = :acct_b;
SELECT pg_temp.fails('a freeze on a closed account', format('SELECT request_freeze(%s, %s, 1000, 0)', :c1, :acct_b), 'TP002');
UPDATE accounts SET status = 'ACTIVE' WHERE account_id = :acct_b;
SELECT pg_temp.fails('T15 four-eyes: the requesting investigator cannot approve', format('CALL decide_freeze(%s, true, 0)', :f1), 'TP002');
SELECT pg_temp.act_as('sup1@demo.in');
SELECT pg_temp.ok('a supervisor approves 10,000 at D', format('CALL decide_freeze(%s, true, 0)', :f1));
SELECT pg_temp.act_as('inv@demo.in');
SELECT request_freeze(:c2, :acct_d, 5000, 0) AS f2 \gset
SELECT pg_temp.act_as('sup1@demo.in');
SELECT pg_temp.fails('T14 approving 5,000 more at D (balance 12,000)', format('CALL decide_freeze(%s, true, 0)', :f2), 'TP001');
SELECT pg_temp.ok('decline that request instead', format('CALL decide_freeze(%s, false, 0)', :f2));
SELECT pg_temp.check('D cannot spend the frozen money',
  (SELECT balance FROM accounts WHERE account_id = :acct_d) = 12000);
SELECT pg_temp.fails('D tries to send 3,000 (12,000 held 10,000)',
  $$INSERT INTO transactions (external_ref, source_account_id, destination_account_id, amount, channel, occurred_at)
    VALUES ('ESCAPE', 6, 7, 3000, 'UPI', now())$$, 'TP002');

-- Verify losses and move to RECOVERY
SELECT pg_temp.fails('allocation before the case is in RECOVERY', format('SELECT allocate_recovery(%s, %s, 1000, 0)', :f1, :c1), 'TP002');
SELECT pg_temp.act_as('inv@demo.in');
SELECT pg_temp.fails('an investigator cannot verify a loss', format('CALL verify_loss(%s, 40000, 0)', :c1), 'TP002');
SELECT pg_temp.act_as('sup1@demo.in');
SELECT pg_temp.ok('verify C1 at 40,000 and C2 at 2,000', format('CALL verify_loss(%s, 40000, 0); CALL verify_loss(%s, 2000, 0)', :c1, :c2));
UPDATE fraud_cases SET status = 'RECOVERY' WHERE case_id IN (:c1, :c2);

-- Allocation: capped by the freeze, the verified loss, and what the case traced into the account
SELECT pg_temp.fails('allocate 8,000 to C1 (only 7,000 traced to D)', format('SELECT allocate_recovery(%s, %s, 8000, 0)', :f1, :c1), 'TP001');
SELECT pg_temp.fails('T17 allocate 3,000 to C2 (verified loss 2,000)', format('SELECT allocate_recovery(%s, %s, 3000, 0)', :f1, :c2), 'TP001');
SELECT allocate_recovery(:f1, :c1, 7000, 0) AS a1 \gset
SELECT allocate_recovery(:f1, :c2, 2000, 0) AS a2 \gset
SELECT pg_temp.check('allocated 7,000 to C1 and 2,000 to C2 (9,000 of 10,000)',
  (SELECT sum(amount) FROM recovery_allocations WHERE freeze_id = :f1) = 9000);
SELECT pg_temp.fails('release is refused once money is allocated', format('CALL release_freeze(%s)', :f1), 'TP002');

-- T21 exactly-once refunds
SELECT process_refund(:a1, 7000, 'aaaaaaaa-0000-0000-0000-000000000001', 0) AS r1 \gset
SELECT process_refund(:a1, 7000, 'aaaaaaaa-0000-0000-0000-000000000001', 0) AS r1_again \gset
SELECT pg_temp.check('T21 the same idempotency key twice -> one refund, the same id',
  :r1 = :r1_again AND (SELECT count(*) FROM refunds) = 1, 'ids ' || :r1 || ', ' || :r1_again);
SELECT pg_temp.fails('the same key with a different amount is refused',
  format('SELECT process_refund(%s, 500, %L, 0)', :a1, 'aaaaaaaa-0000-0000-0000-000000000001'), 'TP002');
SELECT pg_temp.check('a fully refunded allocation becomes PAID', status = 'PAID') FROM recovery_allocations WHERE allocation_id = :a1;
SELECT pg_temp.fails('refund 2,500 on a 2,000 allocation', format('SELECT process_refund(%s, 2500, gen_random_uuid(), 0)', :a2), 'TP001');
SELECT pg_temp.ok('partial refund of 500 to C2', format('SELECT process_refund(%s, 500, gen_random_uuid(), 0)', :a2));

-- Settlement pays the victims: C2's allocation shrinks to the 500 paid; D pays 7,500 in total
SELECT pg_temp.bal('TP1000000001') AS v1_before, pg_temp.bal('TP1000000002') AS v2_before \gset
SELECT settle_freeze(:f1, 0) AS paid \gset
SELECT pg_temp.check('T20 settle pays out 7,500, freeze SETTLED, C2 allocation shrinks to 500',
  :paid = 7500 AND (SELECT status FROM account_freezes WHERE freeze_id = :f1) = 'SETTLED'
  AND (SELECT amount FROM recovery_allocations WHERE allocation_id = :a2) = 500, 'paid ' || :paid);
SELECT pg_temp.check('victims credited (V1 +7,000, V2 +500) and D debited to 4,500',
  pg_temp.bal('TP1000000001') = :v1_before + 7000 AND pg_temp.bal('TP1000000002') = :v2_before + 500
  AND pg_temp.bal('TP1000000006') = 4500, 'D ' || pg_temp.bal('TP1000000006'));
SELECT pg_temp.check('each paid allocation points at its RECOVERY transfer',
  count(*) = 2 AND bool_and(t.channel = 'RECOVERY' AND t.amount = ra.amount))
FROM recovery_allocations ra JOIN transactions t ON t.txn_id = ra.credit_txn_id WHERE ra.freeze_id = :f1;

-- Release: an active freeze with nothing allocated just ends
SELECT pg_temp.act_as('inv@demo.in');
SELECT request_freeze(:c1, :acct_d, 1000, 0) AS f3 \gset
SELECT pg_temp.act_as('sup2@demo.in');
CALL decide_freeze(:f3, true, 0);
SELECT pg_temp.ok('release an active freeze with nothing allocated', format('CALL release_freeze(%s)', :f3));
SELECT pg_temp.check('the released freeze no longer holds money', status = 'RELEASED') FROM account_freezes WHERE freeze_id = :f3;

-- T22 lazy expiry, and what was refunded before expiry is still paid
SELECT pg_temp.act_as('inv@demo.in');
SELECT request_freeze(:c1, :acct_b, 3000, 0) AS f4 \gset
SELECT pg_temp.act_as('sup2@demo.in');
CALL decide_freeze(:f4, true, 0);
SELECT allocate_recovery(:f4, :c1, 3000, 0) AS a4 \gset
SELECT process_refund(:a4, 1000, gen_random_uuid(), 0);
UPDATE account_freezes SET approved_at = now() - interval '8 days', expires_at = now() - interval '1 day' WHERE freeze_id = :f4;
SELECT pg_temp.fails('T22a an expired freeze cannot be settled', format('SELECT settle_freeze(%s, 0)', :f4), 'TP002');
SELECT pg_temp.fails('T22b nothing more can be allocated from it', format('SELECT allocate_recovery(%s, %s, 100, 0)', :f4, :c1), 'TP002');
CALL expire_freezes();
SELECT pg_temp.check('T22c the sweep marks it EXPIRED and pays the 1,000 refunded to the victim',
  f.status = 'EXPIRED' AND ra.status = 'PAID' AND ra.amount = 1000 AND t.channel = 'RECOVERY',
  f.status || ', allocation ' || ra.status || ' ' || ra.amount)
FROM account_freezes f JOIN recovery_allocations ra ON ra.freeze_id = f.freeze_id
LEFT JOIN transactions t ON t.txn_id = ra.credit_txn_id WHERE f.freeze_id = :f4;

-- Hand-back: a case with nothing confirmed goes back to the supervisors, with the reason
SELECT pg_temp.act_as('v1@demo.in');
INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative)
VALUES (pg_temp.uid('v1@demo.in'), pg_temp.txn('T8'), 3000, 'A recruiter asked me to pay a registration fee for a job.');
SELECT case_id AS c3 FROM fraud_cases WHERE disputed_txn_id = pg_temp.txn('T8') \gset
SELECT pg_temp.act_as('sup1@demo.in');
CALL assign_case(:c3, :inv, 0);
SELECT pg_temp.act_as('inv@demo.in');
UPDATE fraud_cases SET status = 'INVESTIGATING' WHERE case_id = :c3;
CALL start_trace(:c3);
SELECT pg_temp.fails('a hand-back needs a reason', format('CALL hand_back_case(%s, %L)', :c3, ''), 'TP002');
SELECT pg_temp.ok('the investigator hands back C3', format('CALL hand_back_case(%s, %L)', :c3, 'I know the customer personally'));
SELECT pg_temp.check('C3 is UNDER_REVIEW, unassigned, trace cleared, reason in its history',
  fc.status = 'UNDER_REVIEW'
  AND NOT EXISTS (SELECT 1 FROM case_assignments WHERE case_id = :c3 AND ended_at IS NULL)
  AND NOT EXISTS (SELECT 1 FROM trace_nodes WHERE case_id = :c3)
  AND EXISTS (SELECT 1 FROM case_status_history WHERE case_id = :c3 AND note LIKE 'Handed back%personally'), fc.status)
FROM fraud_cases fc WHERE fc.case_id = :c3;

-- After the whole workflow
SELECT pg_temp.check('all six money rules still hold',
  NOT EXISTS (SELECT 1 FROM invariant_definitions d, verify_invariant(d.name)));
SELECT pg_temp.check('the audit trail recorded the workflow', count(*) > 20, count(*) || ' rows')
FROM audit_log WHERE entity_type IN ('account_freezes', 'recovery_allocations', 'refunds', 'case_assignments', 'trace_nodes', 'fund_flow_links');

\ir _report.sql
