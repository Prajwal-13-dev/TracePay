-- 04 tracing (004_tracing.sql): candidate paths, start_trace, confirm_link, FIFO suggestions.
-- Run: docker compose exec postgres psql -U tracepay_owner -d tracepay -f /db/tests/04_tracing.sql
\ir _setup.sql

-- T12 candidate paths from T1 on the demo scenario (A -> B -> A is a cycle)
CREATE TEMP TABLE tr AS SELECT * FROM trace_candidates(pg_temp.txn('T1'));
SELECT pg_temp.check('T12a the trace ends on the cycle and returns T1, T2, T3, T4, T5, T7',
  string_agg(t.external_ref, ',' ORDER BY t.external_ref) = 'T1,T2,T3,T4,T5,T7',
  string_agg(t.external_ref, ',' ORDER BY tr.depth, tr.occurred_at))
FROM tr JOIN transactions t USING (txn_id);
SELECT pg_temp.check('T12b each transfer listed once', count(*) = count(DISTINCT txn_id)) FROM tr;
SELECT pg_temp.check('T12c no hop earlier than its parent',
  NOT EXISTS (SELECT 1 FROM tr c JOIN transactions p ON p.txn_id = c.parent_txn_id WHERE c.occurred_at <= p.occurred_at));
SELECT pg_temp.check('T12d upper bound = smallest transfer on the path (T4 via T2: 10,000)',
  upper_bound = 10000, upper_bound::text) FROM tr WHERE txn_id = pg_temp.txn('T4');
SELECT pg_temp.check('T12e an optional depth cap stops at that hop',
  max(depth) = 1, 'max depth ' || max(depth)) FROM trace_candidates(pg_temp.txn('T1'), 1);

-- T13 a transfer 4 days after the previous hop is outside the 72-hour window
INSERT INTO transactions (external_ref, source_account_id, destination_account_id, amount, channel, occurred_at)
VALUES ('LATE', pg_temp.acct('TP1000000006'), pg_temp.acct('TP1000000007'), 1000, 'UPI', '2026-10-16 11:00+05:30');
SELECT pg_temp.check('T13 a 4-day-later transfer: excluded at 72 h, included with a 5-day window',
  NOT EXISTS (SELECT 1 FROM trace_candidates(pg_temp.txn('T1')) WHERE txn_id = pg_temp.txn('LATE'))
  AND EXISTS (SELECT 1 FROM trace_candidates(pg_temp.txn('T1'), NULL, interval '5 days') WHERE txn_id = pg_temp.txn('LATE')));

-- Refund payments are never laundering hops
INSERT INTO transactions (external_ref, source_account_id, destination_account_id, amount, channel, occurred_at)
VALUES ('RC-TEST', pg_temp.acct('TP1000000006'), pg_temp.acct('TP1000000001'), 100, 'RECOVERY', '2026-10-12 12:00+05:30');
SELECT pg_temp.check('a RECOVERY transfer out of D is not a trace candidate',
  NOT EXISTS (SELECT 1 FROM trace_candidates(pg_temp.txn('T1')) WHERE txn_id = pg_temp.txn('RC-TEST')));

-- Fixture: C1 (V1 on T1, 40,000) and C2 (V2 on T6, 20,000), assigned to inv and accepted; inv2 is not assigned
INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative) VALUES
  (pg_temp.uid('v1@demo.in'), pg_temp.txn('T1'), 40000, 'Fake courier asked me to pay a customs fee by UPI.'),
  (pg_temp.uid('v2@demo.in'), pg_temp.txn('T6'), 20000, 'A parcel delivery agent said I owe customs duty.');
SELECT (SELECT case_id FROM fraud_cases WHERE disputed_txn_id = pg_temp.txn('T1')) AS c1,
       (SELECT case_id FROM fraud_cases WHERE disputed_txn_id = pg_temp.txn('T6')) AS c2 \gset
SELECT pg_temp.act_as('sup1@demo.in');
SELECT create_user('inv2@demo.in', 'Second Investigator', NULL, '$2b$12$' || repeat('z', 53), 'INVESTIGATOR');
SELECT pg_temp.ok('supervisor assigns C1 and C2 to inv',
  format('CALL assign_case(%s, %s, 0); CALL assign_case(%s, %s, 0)', :c1, pg_temp.uid('inv@demo.in'), :c2, pg_temp.uid('inv@demo.in')));
SELECT pg_temp.act_as('inv@demo.in');
UPDATE fraud_cases SET status = 'INVESTIGATING' WHERE case_id IN (:c1, :c2);

-- Only the assigned investigator traces
SELECT pg_temp.act_as('inv2@demo.in');
SELECT pg_temp.fails('an investigator not assigned to C1 cannot start its trace', format('CALL start_trace(%s)', :c1), 'TP002');
SELECT pg_temp.act_as('sup1@demo.in');
SELECT pg_temp.fails('a supervisor does not trace', format('CALL start_trace(%s)', :c1), 'TP002');
SELECT pg_temp.act_as('inv@demo.in');
SELECT pg_temp.ok('start_trace C1 (root T1, 40,000) and C2 (root T6, 20,000)', format('CALL start_trace(%s); CALL start_trace(%s)', :c1, :c2));
SELECT pg_temp.ok('start_trace is idempotent', format('CALL start_trace(%s)', :c1));
SELECT pg_temp.check('the root node carries the reported amount',
  inflow_amount = 40000 AND is_root) FROM trace_nodes WHERE case_id = :c1 AND txn_id = pg_temp.txn('T1');

-- Confirming links (procedure: link(case, from, to, amount, method))
CREATE FUNCTION pg_temp.link(p_case bigint, p_from text, p_to text, p_amt numeric, p_method text DEFAULT 'MANUAL')
RETURNS text LANGUAGE sql AS $f$
  SELECT format('CALL confirm_link(%s, %s, %s, %s, %L, 0)', p_case, pg_temp.txn(p_from), pg_temp.txn(p_to), p_amt, p_method)
$f$;
SELECT pg_temp.ok('C1 confirms T1 -> T2 25,000', pg_temp.link(:c1, 'T1', 'T2', 25000));
SELECT pg_temp.ok('C1 confirms T1 -> T3 10,000, then 5,000 more', pg_temp.link(:c1, 'T1', 'T3', 10000) || ';' || pg_temp.link(:c1, 'T1', 'T3', 5000));
SELECT pg_temp.check('a second confirmation adds to the same link: one link of 15,000, node inflow 15,000',
  (SELECT count(*) FROM fund_flow_links l JOIN trace_nodes n ON n.node_id = l.to_node_id WHERE l.case_id = :c1 AND n.txn_id = pg_temp.txn('T3')) = 1
  AND (SELECT attributed_amount FROM fund_flow_links l JOIN trace_nodes n ON n.node_id = l.to_node_id WHERE l.case_id = :c1 AND n.txn_id = pg_temp.txn('T3')) = 15000
  AND (SELECT inflow_amount FROM trace_nodes WHERE case_id = :c1 AND txn_id = pg_temp.txn('T3')) = 15000);

-- T09 node_outflow: T1 holds 40,000; 25,000 + 15,000 already out; 5,000 more to T7 crosses it
SELECT pg_temp.fails('T09 links out of T1 would total 45,000 (> 40,000)', pg_temp.link(:c1, 'T1', 'T7', 5000), 'TP001');

-- FIFO from T2 at account B (T2 25,000 then T6 20,000 in; T4 10,000 and T5 8,000 out)
SELECT pg_temp.check('FIFO from T2 suggests T4 = 10,000 and T5 = 8,000',
  string_agg(t.external_ref || '=' || s.suggested_amount, ',' ORDER BY t.external_ref) = 'T4=10000.00,T5=8000.00',
  string_agg(t.external_ref || '=' || s.suggested_amount, ', ' ORDER BY t.external_ref))
FROM suggest_fifo(:c1, pg_temp.txn('T2')) s JOIN transactions t ON t.txn_id = s.to_txn_id;

-- T08 through confirm_link: C1 takes 7,000 of T4; C2 tries 4,000 of T4 -> excess 1,000
SELECT pg_temp.ok('C1 confirms T2 -> T4 7,000 (MANUAL)', pg_temp.link(:c1, 'T2', 'T4', 7000));
SELECT pg_temp.ok('C1 confirms T2 -> T5 8,000 (FIFO)', pg_temp.link(:c1, 'T2', 'T5', 8000, 'FIFO'));
SELECT pg_temp.fails('T08 C2 confirms T6 -> T4 4,000 (C1 already has 7,000 of 10,000)', pg_temp.link(:c2, 'T6', 'T4', 4000), 'TP001');
SELECT pg_temp.ok('C2 confirms T6 -> T4 3,000 (fits)', pg_temp.link(:c2, 'T6', 'T4', 3000));

-- T10 confirm_link business rules
SELECT pg_temp.fails('T10a the target must be later than the source (T5 11:10 -> T2 10:20)', pg_temp.link(:c1, 'T5', 'T2', 1000), 'TP002');
SELECT pg_temp.fails('T10b the target must leave the receiving account (T2 -> T3)', pg_temp.link(:c1, 'T2', 'T3', 1000), 'TP002');
SELECT pg_temp.fails('T10c the source must be a node of the case (T3 for C2)', pg_temp.link(:c2, 'T3', 'T7', 1000), 'TP002');
SELECT pg_temp.fails('T10d a refund payment cannot be a link target', pg_temp.link(:c1, 'T4', 'RC-TEST', 50), 'TP002');
SELECT pg_temp.fails('T10e the method is MANUAL or FIFO', pg_temp.link(:c1, 'T1', 'T7', 1, 'GUESS'), '23514');

-- T11 every non-root node's inflow equals the sum of its incoming links
SELECT pg_temp.check('T11 inflow = sum of incoming links for every node',
  count(*) = 0, count(*) || ' mismatches')
FROM (SELECT n.node_id FROM trace_nodes n JOIN fund_flow_links l ON l.to_node_id = n.node_id
      WHERE NOT n.is_root GROUP BY n.node_id, n.inflow_amount HAVING n.inflow_amount <> SUM(l.attributed_amount)) x;

-- Both ends of a link belong to the link's case
SELECT pg_temp.fails('a link cannot join nodes of two different cases',
  format($$INSERT INTO fund_flow_links (case_id, from_node_id, to_node_id, attributed_amount, method, linked_by)
           VALUES (%1$s, (SELECT node_id FROM trace_nodes WHERE case_id = %1$s AND is_root),
                         (SELECT node_id FROM trace_nodes WHERE case_id = %2$s AND is_root), 1, 'MANUAL', %3$s)$$,
         :c1, :c2, pg_temp.uid('inv@demo.in')), 'TP002');

-- FIFO counts money the account spent BEFORE the disputed transfer arrived
-- A receives 5,000 at 09:00 and spends 5,000 at 09:30, before T1 (10:00): T2 (25,000) is then fully tainted.
SELECT pg_temp.act_as('sup1@demo.in');
SELECT record_transfer('TP1000000005', 'TP1000000003', 5000, 'UPI', '2026-10-12 09:00+05:30');
SELECT record_transfer('TP1000000003', 'TP1000000007', 5000, 'UPI', '2026-10-12 09:30+05:30');
SELECT pg_temp.check('FIFO from T1 with earlier spending: T2 = 25,000, T3 = 15,000, T7 = none',
  string_agg(t.external_ref || '=' || s.suggested_amount, ',' ORDER BY t.external_ref) = 'T2=25000.00,T3=15000.00',
  string_agg(t.external_ref || '=' || s.suggested_amount, ', ' ORDER BY t.external_ref))
FROM suggest_fifo(:c1, pg_temp.txn('T1')) s JOIN transactions t ON t.txn_id = s.to_txn_id;

\ir _report.sql
