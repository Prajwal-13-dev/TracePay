-- 09 database roles (009_db_roles.sql): what the web app's own role, tracepay_app, can and cannot do.
-- Run: docker compose exec postgres psql -U tracepay_owner -d tracepay -f /db/tests/09_roles.sql
\ir _setup.sql
GRANT ALL ON results, results_n_seq TO tracepay_app;
SELECT pg_temp.uid('v1@demo.in') AS v1, pg_temp.uid('sup1@demo.in') AS sup1, pg_temp.txn('T1') AS t1 \gset

-- Everything below runs as the web app's role
SET LOCAL ROLE tracepay_app;
SELECT pg_temp.fails('the app cannot DROP a table', 'DROP TABLE users', '42501');
SELECT pg_temp.fails('the app cannot TRUNCATE the audit log', 'TRUNCATE audit_log', '42501');
SELECT pg_temp.fails('the app cannot change a balance directly', 'UPDATE accounts SET balance = balance + 1000000', '42501');
SELECT pg_temp.fails('the app cannot insert a transfer directly (only record_transfer)',
  $$INSERT INTO transactions (external_ref, source_account_id, destination_account_id, amount, channel, occurred_at)
    VALUES ('HACK', 1, 2, 1, 'UPI', now())$$, '42501');
SELECT pg_temp.fails('the app cannot write the audit log', $$INSERT INTO audit_log (entity_type, entity_id, action) VALUES ('x', 1, 'INSERT')$$, '42501');
SELECT pg_temp.fails('the app cannot change a role directly (only set_user_role)', $$UPDATE users SET role = 'SUPERVISOR'$$, '42501');
SELECT pg_temp.fails('the app cannot drop an engine rule', $$SELECT drop_invariant('txn_capacity')$$, '42501');
SELECT pg_temp.fails('the app cannot refresh the materialized view itself', 'REFRESH MATERIALIZED VIEW supervisor_case_summary', '42501');

-- What the app does do works, and the triggers still write audit, outbox and history rows it cannot write itself
SELECT set_config('app.user_id', :'v1', true);
SELECT pg_temp.ok('a customer files a complaint through the app role',
  format($$INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative)
           VALUES (%s, %s, 1000, 'Fake courier asked me to pay a customs fee by UPI.')$$, :v1, :t1));
SELECT pg_temp.ok('a customer sends money through record_transfer', $$SELECT record_transfer('TP1000000001', 'TP1000000007', 100, 'UPI')$$);
SELECT set_config('app.user_id', :'sup1', true), set_config('app.status_note', 'Duplicate of an earlier complaint.', true);
SELECT pg_temp.ok('a supervisor rejects the case with a note',
  format($$UPDATE fraud_cases SET status = 'REJECTED' WHERE disputed_txn_id = %s$$, :t1));
SELECT pg_temp.ok('the app refreshes the dashboard through refresh_case_summary()', 'SELECT refresh_case_summary()');
RESET ROLE;

SELECT pg_temp.check('the case was audited, queued for Neo4j, and its history has the note',
  EXISTS (SELECT 1 FROM audit_log a JOIN fraud_cases c ON a.entity_type = 'fraud_cases' AND a.entity_id = c.case_id WHERE c.disputed_txn_id = :t1)
  AND EXISTS (SELECT 1 FROM graph_outbox o JOIN fraud_cases c ON o.entity = 'case' AND o.entity_id = c.case_id WHERE c.disputed_txn_id = :t1)
  AND EXISTS (SELECT 1 FROM case_status_history h JOIN fraud_cases c USING (case_id) WHERE c.disputed_txn_id = :t1 AND h.note LIKE 'Duplicate%'));

\ir _report.sql
