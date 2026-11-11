-- 01 core tables (001_core.sql): row constraints, immutable tables, status lookup tables.
-- Run: docker compose exec postgres psql -U tracepay_owner -d tracepay -f /db/tests/01_core.sql
\ir _setup.sql

-- T01 transfers: amount and parties
SELECT pg_temp.fails('T01a a transfer amount must be positive',
  $$INSERT INTO transactions (external_ref, source_account_id, destination_account_id, amount, channel, occurred_at)
    VALUES ('X1', 1, 2, -5, 'UPI', now())$$, '23514');
SELECT pg_temp.fails('T01b a transfer cannot go to the same account',
  $$INSERT INTO transactions (external_ref, source_account_id, destination_account_id, amount, channel, occurred_at)
    VALUES ('X2', 1, 1, 5, 'UPI', now())$$, '23514');
SELECT pg_temp.fails('T01c unknown channel',
  $$INSERT INTO transactions (external_ref, source_account_id, destination_account_id, amount, channel, occurred_at)
    VALUES ('X3', 1, 2, 5, 'CHEQUE', now())$$, '23514');

-- T02 append-only tables
SELECT pg_temp.fails('T02a a transfer cannot be updated', $$UPDATE transactions SET amount = 1 WHERE external_ref = 'T1'$$, 'TP004');
SELECT pg_temp.fails('T02b a transfer cannot be deleted', $$DELETE FROM transactions WHERE external_ref = 'T1'$$, 'TP004');
SELECT pg_temp.fails('T02c the audit log cannot be updated', $$UPDATE audit_log SET action = 'DELETE'$$, 'TP004');
SELECT pg_temp.fails('T02d the audit log cannot be truncated', $$TRUNCATE audit_log$$, 'TP004');

-- Users and accounts
SELECT pg_temp.fails('users: email must look like an email',
  $$INSERT INTO users (email, full_name, password_hash) VALUES ('not-an-email', 'Some One', '$2b$12$' || repeat('x', 53))$$, '23514');
SELECT pg_temp.fails('users: phone must be a 10-digit Indian mobile number',
  $$INSERT INTO users (email, full_name, phone, password_hash) VALUES ('p@demo.in', 'Some One', '12345', '$2b$12$' || repeat('x', 53))$$, '23514');
SELECT pg_temp.fails('users: password must be a bcrypt/argon2 hash, never plain text',
  $$INSERT INTO users (email, full_name, password_hash) VALUES ('q@demo.in', 'Some One', 'Demo@1234')$$, '23514');
SELECT pg_temp.fails('users: email is unique (case-insensitive)',
  $$INSERT INTO users (email, full_name, password_hash) VALUES ('V1@DEMO.IN', 'Copy Cat', '$2b$12$' || repeat('x', 53))$$, '23505');
SELECT pg_temp.fails('accounts: reference format TP + 10 digits',
  $$INSERT INTO accounts (user_id, account_ref) VALUES (1, 'XX123')$$, '23514');
SELECT pg_temp.fails('accounts: IFSC format',
  $$INSERT INTO accounts (user_id, account_ref, ifsc) VALUES (1, 'TP9999999999', 'bad')$$, '23514');
SELECT pg_temp.fails('accounts: balance never below zero',
  $$UPDATE accounts SET balance = -1 WHERE account_ref = 'TP1000000001'$$, '23514');
SELECT pg_temp.check('accounts: every account has the branch IFSC by default',
  NOT EXISTS (SELECT 1 FROM accounts WHERE ifsc IS DISTINCT FROM 'TPAY0000001'));

-- Cases: verified loss rules (a case for V1 on T1 as fixture)
INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative)
VALUES (pg_temp.uid('v1@demo.in'), pg_temp.txn('T1'), 40000, 'Fake courier asked me to pay a customs fee by UPI.');
SELECT case_id AS c1 FROM fraud_cases WHERE disputed_txn_id = pg_temp.txn('T1') \gset
SELECT pg_temp.fails('cases: verified loss cannot exceed the reported amount',
  format($$UPDATE fraud_cases SET verified_loss = 50000, verified_by = %s WHERE case_id = %s$$, pg_temp.uid('sup1@demo.in'), :c1), '23514');
SELECT pg_temp.fails('cases: a verified loss needs the verifier (and the reverse)',
  format($$UPDATE fraud_cases SET verified_loss = 1000 WHERE case_id = %s$$, :c1), '23514');
SELECT pg_temp.fails('cases: priority is 1 to 5',
  format($$UPDATE fraud_cases SET priority = 9 WHERE case_id = %s$$, :c1), '23514');
SELECT pg_temp.fails('cases: the narrative needs at least 30 characters',
  format($$INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative)
           VALUES (%s, %s, 100, 'too short')$$, pg_temp.uid('v2@demo.in'), pg_temp.txn('T6')), '23514');

-- Freezes: four-eyes rule as a table CHECK
SELECT pg_temp.fails('freezes: the requester can never be the approver (four-eyes CHECK)',
  format($$INSERT INTO account_freezes (account_id, requested_for_case, requested_by, approved_by, frozen_amount, status, approved_at, expires_at)
           VALUES (%s, %s, %s, %s, 100, 'ACTIVE', now(), now() + interval '1 day')$$,
         pg_temp.acct('TP1000000006'), :c1, pg_temp.uid('sup1@demo.in'), pg_temp.uid('sup1@demo.in')), '23514');
SELECT pg_temp.fails('freezes: an approved freeze needs an expiry after approval',
  format($$INSERT INTO account_freezes (account_id, requested_for_case, requested_by, approved_by, frozen_amount, status, approved_at, expires_at)
           VALUES (%s, %s, %s, %s, 100, 'ACTIVE', now(), now() - interval '1 day')$$,
         pg_temp.acct('TP1000000006'), :c1, pg_temp.uid('inv@demo.in'), pg_temp.uid('sup1@demo.in')), '23514');

-- Status lookup tables
SELECT pg_temp.check('lookups: 6 case, 6 freeze, 3 allocation and 1 refund statuses',
  (SELECT count(*) FROM case_status) = 6 AND (SELECT count(*) FROM freeze_status) = 6
  AND (SELECT count(*) FROM allocation_status) = 3 AND (SELECT count(*) FROM refund_status) = 1);
SELECT pg_temp.fails('lookups: an unknown status in the case history is rejected by the foreign key',
  format($$INSERT INTO case_status_history (case_id, from_status, to_status) VALUES (%s, 'SUBMITTED', 'LOST')$$, :c1), '23503');
SELECT pg_temp.fails('lookups: a transition to an unknown case status is rejected',
  $$INSERT INTO case_status_transitions VALUES ('SUBMITTED', 'LOST', 'SUPERVISOR')$$, '23503');

\ir _report.sql
