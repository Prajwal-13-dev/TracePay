-- 03 constraint engine (003_engine.sql): registration checks, the six money rules, diagnostics.
-- Rows are written directly here (as the owner) so each rule is tested on its own, without the procedures.
-- Run: docker compose exec postgres psql -U tracepay_owner -d tracepay -f /db/tests/03_engine.sql
\ir _setup.sql

-- T06 bad registrations are rejected and leave nothing behind
SELECT pg_temp.fails('T06a unknown column',
  $$SELECT register_invariant('bad_one', 'accounts', 'account_id', 'no_such_col', 'account_freezes', 'account_id', 'frozen_amount')$$, 'P0001');
SELECT pg_temp.fails('T06b a text column is not a quantity',
  $$SELECT register_invariant('bad_two', 'accounts', 'account_id', 'balance', 'fraud_cases', 'customer_id', 'narrative')$$, 'P0001');
SELECT pg_temp.fails('T06c no foreign key from child to parent',
  $$SELECT register_invariant('bad_three', 'accounts', 'account_id', 'balance', 'refunds', 'allocation_id', 'amount')$$, 'P0001');
SELECT pg_temp.fails('T06d unsupported relation >=',
  $$SELECT register_invariant('bad_four', 'accounts', 'account_id', 'balance', 'account_freezes', 'account_id', 'frozen_amount', '>=')$$, 'P0001');

-- T07 six rules -> 6 definitions, 18 triggers, 24 functions (and no leftovers from T06)
SELECT pg_temp.check('T07 the six rules generated 6 definitions, 18 triggers, 24 functions',
  d = 6 AND t = 18 AND f = 24, format('%s definitions, %s triggers, %s functions', d, t, f))
FROM (SELECT (SELECT count(*) FROM invariant_definitions) AS d,
             (SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'inv\_%') AS t,
             (SELECT count(*) FROM pg_proc WHERE proname LIKE 'inv\_%') AS f) x;

-- Fixture: C1 (V1 on T1) and C2 (V2 on T6)
INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative) VALUES
  (pg_temp.uid('v1@demo.in'), pg_temp.txn('T1'), 40000, 'Fake courier asked me to pay a customs fee by UPI.'),
  (pg_temp.uid('v2@demo.in'), pg_temp.txn('T6'), 20000, 'A parcel delivery agent said I owe customs duty.');
SELECT (SELECT case_id FROM fraud_cases WHERE disputed_txn_id = pg_temp.txn('T1')) AS c1,
       (SELECT case_id FROM fraud_cases WHERE disputed_txn_id = pg_temp.txn('T6')) AS c2,
       pg_temp.uid('inv@demo.in') AS inv, pg_temp.uid('sup1@demo.in') AS sup1, pg_temp.uid('sup2@demo.in') AS sup2,
       pg_temp.acct('TP1000000006') AS acct_d \gset

-- T08 txn_capacity: T4 moved 10,000; C1 claims 7,000, C2 tries 4,000 -> excess 1,000
SELECT pg_temp.ok('T08a C1 claims 7,000 of T4',
  format('INSERT INTO trace_nodes (case_id, txn_id, inflow_amount) VALUES (%s, %s, 7000)', :c1, pg_temp.txn('T4')));
SELECT pg_temp.fails('T08b C2 claims 4,000 more of T4 (10,000 in total moved)',
  format('INSERT INTO trace_nodes (case_id, txn_id, inflow_amount) VALUES (%s, %s, 4000)', :c2, pg_temp.txn('T4')), 'TP001');

-- node_outflow: links leaving a node never exceed its inflow
SELECT pg_temp.ok('node_outflow fixture: C1 nodes T1 40,000, T2 25,000, T3 15,000',
  format('INSERT INTO trace_nodes (case_id, txn_id, is_root, inflow_amount) VALUES (%1$s, %2$s, true, 40000), (%1$s, %3$s, false, 25000), (%1$s, %4$s, false, 15000)',
         :c1, pg_temp.txn('T1'), pg_temp.txn('T2'), pg_temp.txn('T3')));
SELECT node_id AS n1 FROM trace_nodes WHERE case_id = :c1 AND txn_id = pg_temp.txn('T1') \gset
SELECT node_id AS n2 FROM trace_nodes WHERE case_id = :c1 AND txn_id = pg_temp.txn('T2') \gset
SELECT node_id AS n3 FROM trace_nodes WHERE case_id = :c1 AND txn_id = pg_temp.txn('T3') \gset
SELECT pg_temp.ok('T09a links out of T1: 25,000 + 15,000 = its 40,000',
  format($$INSERT INTO fund_flow_links (case_id, from_node_id, to_node_id, attributed_amount, method, linked_by)
           VALUES (%1$s, %2$s, %3$s, 25000, 'MANUAL', %5$s), (%1$s, %2$s, %4$s, 15000, 'MANUAL', %5$s)$$, :c1, :n1, :n2, :n3, :inv));
SELECT pg_temp.fails('T09b raising one of them by 1 crosses the node''s inflow',
  format('UPDATE fund_flow_links SET attributed_amount = 25001 WHERE from_node_id = %s AND to_node_id = %s', :n1, :n2), 'TP001');

-- T14 freeze_within_balance: D holds 12,000; freeze 10,000 OK, another 5,000 rejected
SELECT pg_temp.ok('T14a freeze 10,000 at D (balance 12,000)',
  format($$INSERT INTO account_freezes (account_id, requested_for_case, requested_by, approved_by, frozen_amount, status, approved_at, expires_at)
           VALUES (%s, %s, %s, %s, 10000, 'ACTIVE', now(), now() + interval '7 days')$$, :acct_d, :c1, :inv, :sup1));
SELECT pg_temp.fails('T14b another 5,000 at D (15,000 > 12,000)',
  format($$INSERT INTO account_freezes (account_id, requested_for_case, requested_by, approved_by, frozen_amount, status, approved_at, expires_at)
           VALUES (%s, %s, %s, %s, 5000, 'ACTIVE', now(), now() + interval '7 days')$$, :acct_d, :c2, :inv, :sup2), 'TP001');
SELECT freeze_id AS f1 FROM account_freezes WHERE account_id = :acct_d AND status = 'ACTIVE' \gset
SELECT pg_temp.fails('T14c the balance cannot drop below what is frozen (parent check)',
  format('UPDATE accounts SET balance = 9000 WHERE account_id = %s', :acct_d), 'TP001');

-- T17a allocation_within_loss: C2 has no verified loss -> zero capacity
SELECT pg_temp.fails('T17a allocate to C2 before its loss is verified',
  format('INSERT INTO recovery_allocations (freeze_id, case_id, amount, allocated_by) VALUES (%s, %s, 1000, %s)', :f1, :c2, :sup1), 'TP001');

UPDATE fraud_cases SET verified_loss = 40000, verified_by = :sup1 WHERE case_id = :c1;
UPDATE fraud_cases SET verified_loss = 3000,  verified_by = :sup1 WHERE case_id = :c2;

-- T16 allocation_within_freeze: freeze 10,000; C1 6,000 OK; C2 6,000 -> excess 2,000 (the race outcome)
SELECT pg_temp.ok('T16a allocate 6,000 to C1',
  format('INSERT INTO recovery_allocations (freeze_id, case_id, amount, allocated_by) VALUES (%s, %s, 6000, %s)', :f1, :c1, :sup1));
SELECT pg_temp.fails('T16b allocate 6,000 to C2 (freeze is 10,000)',
  format('INSERT INTO recovery_allocations (freeze_id, case_id, amount, allocated_by) VALUES (%s, %s, 6000, %s)', :f1, :c2, :sup1), 'TP001');
SELECT pg_temp.fails('T17b allocate 4,000 to C2: fits the freeze, exceeds its 3,000 loss',
  format('INSERT INTO recovery_allocations (freeze_id, case_id, amount, allocated_by) VALUES (%s, %s, 4000, %s)', :f1, :c2, :sup1), 'TP001');

-- T18 a limit cannot be lowered below what children already use
SELECT pg_temp.fails('T18a lower the freeze to 5,000 (6,000 allocated)',
  format('UPDATE account_freezes SET frozen_amount = 5000 WHERE freeze_id = %s', :f1), 'TP001');
SELECT pg_temp.fails('T18b lower C1''s verified loss to 5,000 (6,000 allocated)',
  format('UPDATE fraud_cases SET verified_loss = 5000 WHERE case_id = %s', :c1), 'TP001');

-- refund_within_allocation
SELECT allocation_id AS a1 FROM recovery_allocations WHERE case_id = :c1 \gset
SELECT pg_temp.fails('refund 7,000 on a 6,000 allocation',
  format('INSERT INTO refunds (allocation_id, amount, idempotency_key, processed_by) VALUES (%s, 7000, gen_random_uuid(), %s)', :a1, :sup1), 'TP001');

-- T19 diagnostics: a bad row slipped in with triggers off is found by verify_invariant
ALTER TABLE recovery_allocations DISABLE TRIGGER USER;
INSERT INTO recovery_allocations (freeze_id, case_id, amount, allocated_by) VALUES (:f1, :c2, 9000, :sup1);
ALTER TABLE recovery_allocations ENABLE TRIGGER USER;
SELECT pg_temp.check('T19 verify_invariant finds the freeze: limit 10,000, total 15,000, excess 5,000',
  v.limit_qty = 10000 AND v.child_total = 15000 AND v.excess = 5000,
  format('freeze %s: limit %s, total %s, excess %s', v.parent_key, v.limit_qty, v.child_total, v.excess))
FROM verify_invariant('allocation_within_freeze') v;

-- explain_invariant and drop_invariant
SELECT pg_temp.check('explain_invariant lists the rule''s 3 triggers and 4 functions',
  jsonb_array_length(e -> 'triggers') = 3 AND jsonb_array_length(e -> 'functions') = 4)
FROM explain_invariant('refund_within_allocation') e;
SELECT drop_invariant('refund_within_allocation');
SELECT pg_temp.check('drop_invariant removes its triggers, functions and definition',
  NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname LIKE 'inv\_refund\_within\_allocation\_%')
  AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname LIKE 'inv\_refund\_within\_allocation\_%')
  AND NOT EXISTS (SELECT 1 FROM invariant_definitions WHERE name = 'refund_within_allocation'));

\ir _report.sql
