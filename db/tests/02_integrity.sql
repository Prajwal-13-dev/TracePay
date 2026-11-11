-- 02 integrity (002_integrity.sql): complaint and draft rules, the case state machine, user rules, audit log.
-- Run: docker compose exec postgres psql -U tracepay_owner -d tracepay -f /db/tests/02_integrity.sql
\ir _setup.sql

-- T03-T04 complaints: own transfer, amount within the transfer, one case per transfer, starts SUBMITTED
SELECT pg_temp.fails('T03 a customer cannot report someone else''s transfer (V2 reports T1)',
  format($$INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative)
           VALUES (%s, %s, 1000, 'Someone else paid this transfer, not me at all.')$$, pg_temp.uid('v2@demo.in'), pg_temp.txn('T1')), 'TP005');
SELECT pg_temp.fails('T04a the reported amount cannot exceed the transfer (50,000 of 40,000)',
  format($$INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative)
           VALUES (%s, %s, 50000, 'Fake courier asked me to pay a customs fee by UPI.')$$, pg_temp.uid('v1@demo.in'), pg_temp.txn('T1')), 'TP005');
SELECT pg_temp.ok('T04b V1 files a valid complaint on T1',
  format($$INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative)
           VALUES (%s, %s, 40000, 'Fake courier asked me to pay a customs fee by UPI.')$$, pg_temp.uid('v1@demo.in'), pg_temp.txn('T1')));
SELECT pg_temp.fails('T04c a second complaint on the same transfer',
  format($$INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative)
           VALUES (%s, %s, 100, 'Trying to file the same transfer a second time.')$$, pg_temp.uid('v1@demo.in'), pg_temp.txn('T1')), '23505');
SELECT pg_temp.fails('T04d a new complaint must start as SUBMITTED',
  format($$INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative, status)
           VALUES (%s, %s, 1000, 'A parcel delivery agent said I owe customs duty.', 'CLOSED')$$, pg_temp.uid('v2@demo.in'), pg_temp.txn('T6')), 'TP005');
SELECT case_id AS c1 FROM fraud_cases WHERE disputed_txn_id = pg_temp.txn('T1') \gset

-- A refund payment (RECOVERY) can never be disputed by the account it was taken from
INSERT INTO transactions (external_ref, source_account_id, destination_account_id, amount, channel, occurred_at)
VALUES ('RC-TEST', pg_temp.acct('TP1000000006'), pg_temp.acct('TP1000000001'), 100, 'RECOVERY', now());
SELECT pg_temp.fails('a RECOVERY payment cannot be disputed',
  format($$INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative)
           VALUES (%s, %s, 100, 'They took money back from my account and I want it returned.')$$,
         pg_temp.uid('d@demo.in'), pg_temp.txn('RC-TEST')), 'TP005');

-- Drafts: only the customer's own transfers
SELECT pg_temp.fails('a draft cannot point at someone else''s transfer (V1 drafts T6)',
  format($$INSERT INTO draft_complaints (customer_id, disputed_txn_id) VALUES (%s, %s)$$, pg_temp.uid('v1@demo.in'), pg_temp.txn('T6')), 'TP005');
SELECT pg_temp.ok('a draft on the customer''s own transfer, with amount and scam type',
  format($$INSERT INTO draft_complaints (customer_id, disputed_txn_id, reported_amount, scam_type, narrative)
           VALUES (%s, %s, 3000, 'Fake job or task', 'started writing')$$, pg_temp.uid('v1@demo.in'), pg_temp.txn('T8')));

-- T05 case state machine: the move must be allowed for the actor's CURRENT role
SELECT pg_temp.act_as('inv@demo.in');
SELECT pg_temp.fails('T05a investigator cannot move SUBMITTED -> RECOVERY',
  format($$UPDATE fraud_cases SET status = 'RECOVERY' WHERE case_id = %s$$, :c1), 'TP003');
SELECT pg_temp.act_as('sup1@demo.in');
SELECT pg_temp.ok('T05b supervisor SUBMITTED -> UNDER_REVIEW',
  format($$UPDATE fraud_cases SET status = 'UNDER_REVIEW' WHERE case_id = %s$$, :c1));
SELECT pg_temp.act_as('inv@demo.in');
SELECT pg_temp.ok('T05c investigator UNDER_REVIEW -> INVESTIGATING',
  format($$UPDATE fraud_cases SET status = 'INVESTIGATING' WHERE case_id = %s$$, :c1));
SELECT pg_temp.act_as('sup1@demo.in');
SELECT pg_temp.fails('T05d RECOVERY needs a verified loss first',
  format($$UPDATE fraud_cases SET status = 'RECOVERY' WHERE case_id = %s$$, :c1), 'TP003');
SELECT set_config('app.status_note', 'The payment was authorised by you and is not a fraud.', true);
SELECT pg_temp.ok('T05e supervisor rejects with a message to the customer',
  format($$UPDATE fraud_cases SET status = 'REJECTED' WHERE case_id = %s$$, :c1));
SELECT set_config('app.status_note', '', true);
SELECT pg_temp.check('T05f history holds 3 moves, the rejection with its note',
  (SELECT count(*) FROM case_status_history WHERE case_id = :c1) = 3
  AND (SELECT note FROM case_status_history WHERE case_id = :c1 AND to_status = 'REJECTED') LIKE 'The payment was authorised%',
  (SELECT count(*) FROM case_status_history WHERE case_id = :c1) || ' moves');
SELECT pg_temp.fails('T05g a closed or rejected case cannot move again',
  format($$UPDATE fraud_cases SET status = 'UNDER_REVIEW' WHERE case_id = %s$$, :c1), 'TP003');
SELECT pg_temp.fails('T05h case history is append-only',
  format($$DELETE FROM case_status_history WHERE case_id = %s$$, :c1), 'TP004');

-- The role comes from the users table: a customer who sets app.user_role = SUPERVISOR gains nothing
INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative)
VALUES (pg_temp.uid('v2@demo.in'), pg_temp.txn('T6'), 20000, 'A parcel delivery agent said I owe customs duty.');
SELECT case_id AS c2 FROM fraud_cases WHERE disputed_txn_id = pg_temp.txn('T6') \gset
SELECT pg_temp.act_as('v2@demo.in');
SELECT set_config('app.user_role', 'SUPERVISOR', true);
SELECT pg_temp.fails('a faked app.user_role does not allow a supervisor step',
  format($$UPDATE fraud_cases SET status = 'UNDER_REVIEW' WHERE case_id = %s$$, :c2), 'TP003');

-- Users: sign-up cannot create staff
SELECT set_config('app.user_id', '', true), set_config('app.allow_staff_insert', 'off', true);
INSERT INTO users (email, full_name, password_hash, role) VALUES ('hacker@demo.in', 'Hacker', '$2b$12$' || repeat('x', 53), 'SUPERVISOR');
SELECT pg_temp.check('sign-up asking for SUPERVISOR is forced to CUSTOMER',
  role = 'CUSTOMER', role::text) FROM users WHERE email = 'hacker@demo.in';
SELECT pg_temp.fails('nobody signed in cannot change a role',
  format($$UPDATE users SET role = 'SUPERVISOR' WHERE user_id = %s$$, pg_temp.uid('hacker@demo.in')), 'TP002');

-- Assignments: only active investigators
SELECT pg_temp.act_as('sup1@demo.in');
SELECT pg_temp.fails('a supervisor cannot be assigned as investigator',
  format($$INSERT INTO case_assignments (case_id, investigator_id, assigned_by) VALUES (%s, %s, %s)$$,
         :c2, pg_temp.uid('sup2@demo.in'), pg_temp.uid('sup1@demo.in')), 'TP002');
SELECT pg_temp.ok('an active investigator can be assigned',
  format($$INSERT INTO case_assignments (case_id, investigator_id, assigned_by) VALUES (%s, %s, %s)$$,
         :c2, pg_temp.uid('inv@demo.in'), pg_temp.uid('sup1@demo.in')));
SELECT pg_temp.fails('only one open assignment per case',
  format($$INSERT INTO case_assignments (case_id, investigator_id, assigned_by) VALUES (%s, %s, %s)$$,
         :c2, pg_temp.uid('inv@demo.in'), pg_temp.uid('sup1@demo.in')), '23505');

-- Audit log: written by triggers in the same transaction, with the actor
SELECT pg_temp.check('every case change is in the audit log with who did it',
  count(*) >= 5 AND count(*) FILTER (WHERE actor_id IS NOT NULL) >= 3, count(*) || ' rows')
FROM audit_log WHERE entity_type = 'fraud_cases' AND entity_id IN (:c1, :c2);
SELECT pg_temp.check('assignments are audited',
  EXISTS (SELECT 1 FROM audit_log WHERE entity_type = 'case_assignments' AND (new_row ->> 'case_id')::bigint = :c2));

\ir _report.sql
