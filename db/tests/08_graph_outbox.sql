-- 08 Neo4j outbox (008_graph_outbox.sql): every change Neo4j needs is queued in the same transaction.
-- Run: docker compose exec postgres psql -U tracepay_owner -d tracepay -f /db/tests/08_graph_outbox.sql
\ir _setup.sql
SELECT coalesce(max(outbox_id), 0) AS before FROM graph_outbox \gset

-- A transfer queues the transfer and both accounts (their balances changed)
SELECT pg_temp.act_as('v1@demo.in');
SELECT record_transfer('TP1000000001', 'TP1000000007', 1000, 'UPI');
SELECT pg_temp.check('a transfer queues 1 transaction and 2 account rows',
  count(*) FILTER (WHERE entity = 'transaction') = 1 AND count(*) FILTER (WHERE entity = 'account') = 2,
  string_agg(entity, ', ' ORDER BY outbox_id)) FROM graph_outbox WHERE outbox_id > :before;

-- A new case and each status change queue the case
SELECT coalesce(max(outbox_id), 0) AS mark FROM graph_outbox \gset
INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative)
VALUES (pg_temp.uid('v1@demo.in'), pg_temp.txn('T1'), 40000, 'Fake courier asked me to pay a customs fee by UPI.');
SELECT case_id AS c1 FROM fraud_cases WHERE disputed_txn_id = pg_temp.txn('T1') \gset
SELECT pg_temp.act_as('sup1@demo.in');
SELECT set_config('app.status_note', 'Duplicate report.', true);
UPDATE fraud_cases SET status = 'REJECTED' WHERE case_id = :c1;
SELECT pg_temp.check('a new case and its status change queue 2 case rows',
  count(*) = 2 AND bool_and(entity = 'case' AND entity_id = :c1)) FROM graph_outbox WHERE outbox_id > :mark;

-- A write that rolls back leaves nothing in the outbox
SELECT coalesce(max(outbox_id), 0) AS mark2 FROM graph_outbox \gset
SELECT pg_temp.fails('an overdraft rolls back',
  $$SELECT record_transfer('TP1000000007', 'TP1000000001', 999999, 'UPI')$$, 'TP002');
SELECT pg_temp.check('the rolled-back transfer queued nothing', count(*) = 0) FROM graph_outbox WHERE outbox_id > :mark2;

-- A full re-queue covers every account, transfer and case
SELECT enqueue_full_graph_sync() AS queued \gset
SELECT pg_temp.check('enqueue_full_graph_sync queues every account, transfer and case',
  :queued = (SELECT count(*) FROM accounts) + (SELECT count(*) FROM transactions) + (SELECT count(*) FROM fraud_cases),
  :queued || ' rows');

\ir _report.sql
