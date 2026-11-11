-- 06 views (006_views_search.sql): views, the dashboard summary and its lazy refresh.
-- Run: docker compose exec postgres psql -U tracepay_owner -d tracepay -f /db/tests/06_views.sql
\ir _setup.sql

-- Fixture: C1 on T1 traced to A, verified 40,000; an active 10,000 freeze at D with 4,000 allocated and 1,500 refunded;
-- an expired freeze at C.
INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative)
VALUES (pg_temp.uid('v1@demo.in'), pg_temp.txn('T1'), 40000, 'Fake courier asked me to pay a customs fee by UPI.');
SELECT case_id AS c1, pg_temp.uid('inv@demo.in') AS inv, pg_temp.uid('sup1@demo.in') AS sup1
FROM fraud_cases WHERE disputed_txn_id = pg_temp.txn('T1') \gset
UPDATE fraud_cases SET verified_loss = 40000, verified_by = :sup1 WHERE case_id = :c1;
INSERT INTO trace_nodes (case_id, txn_id, is_root, inflow_amount) VALUES (:c1, pg_temp.txn('T1'), true, 40000);
INSERT INTO account_freezes (account_id, requested_for_case, requested_by, approved_by, frozen_amount, status, approved_at, expires_at) VALUES
  (pg_temp.acct('TP1000000006'), :c1, :inv, :sup1, 10000, 'ACTIVE', now(), now() + interval '7 days'),
  (pg_temp.acct('TP1000000005'), :c1, :inv, :sup1, 1000, 'ACTIVE', now() - interval '9 days', now() - interval '2 days');
SELECT freeze_id AS f1 FROM account_freezes WHERE account_id = pg_temp.acct('TP1000000006') \gset
INSERT INTO recovery_allocations (freeze_id, case_id, amount, allocated_by) VALUES (:f1, :c1, 4000, :sup1);
INSERT INTO refunds (allocation_id, amount, idempotency_key, processed_by)
SELECT allocation_id, 1500, gen_random_uuid(), :sup1 FROM recovery_allocations WHERE case_id = :c1;

-- Views
SELECT pg_temp.check('active_freezes leaves out a freeze past its expiry',
  count(*) = 1 AND min(freeze_id) = :f1, count(*) || ' active') FROM active_freezes;
SELECT pg_temp.check('freeze_capacity: 10,000 frozen, 4,000 allocated, 6,000 remaining',
  frozen_amount = 10000 AND allocated = 4000 AND remaining = 6000) FROM freeze_capacity WHERE freeze_id = :f1;
SELECT pg_temp.check('trace_accounts: C1 reached account A',
  EXISTS (SELECT 1 FROM trace_accounts WHERE case_id = :c1 AND account_id = pg_temp.acct('TP1000000003')));
SELECT pg_temp.check('account_disputed_inflow: 40,000 of disputed money into A from 1 case',
  disputed_inflow = 40000 AND case_count = 1) FROM account_disputed_inflow WHERE account_id = pg_temp.acct('TP1000000003');

-- Dashboard summary: refreshed only when its data changed
SELECT refresh_case_summary() AS first_refresh \gset
SELECT refresh_case_summary() AS second_refresh \gset
SELECT pg_temp.check('the first refresh runs (data changed), the second is skipped (nothing changed)',
  :'first_refresh'::boolean AND NOT :'second_refresh'::boolean, :'first_refresh' || ', ' || :'second_refresh');
SELECT pg_temp.check('the summary has one row per case',
  (SELECT count(*) FROM supervisor_case_summary) = (SELECT count(*) FROM fraud_cases));
SELECT pg_temp.check('C1 in the summary: allocated 4,000, refunded 1,500 (aggregated before the join)',
  allocated = 4000 AND refunded = 1500) FROM supervisor_case_summary WHERE case_id = :c1;
UPDATE fraud_cases SET priority = 1 WHERE case_id = :c1;
SELECT pg_temp.check('a write to a source table marks the summary stale again', stale) FROM summary_state;

-- Indexes the queries rely on exist
SELECT pg_temp.check('every named index exists (trace, FIFO, queue, engine sums, full-text, vectors, audit)',
  count(*) = 13, count(*) || ' of 13')
FROM pg_indexes WHERE indexname IN ('idx_txn_source_time', 'idx_txn_dest_time', 'idx_cases_status', 'idx_cases_customer',
  'idx_nodes_txn', 'idx_links_to', 'idx_alloc_freeze', 'idx_alloc_case', 'idx_refund_alloc', 'idx_freeze_account_active',
  'idx_cases_fts', 'idx_case_embeddings', 'idx_audit_entity');

\ir _report.sql
