-- Tracing tests (handbook Section 24): T08 (via confirm_link), T09, T10, T11, T12, T13 + FIFO.
-- Runs in one transaction and rolls back.
-- Run: docker compose exec postgres psql -U tracepay_owner -d tracepay -f /db/tests/t08_t13_tracing.sql
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
CREATE FUNCTION pg_temp.act_as(p_email text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.user_id', user_id::text, true), set_config('app.user_role', role::text, true)
  FROM users WHERE email = p_email;
$$;
CREATE FUNCTION pg_temp.uid(p_email text) RETURNS bigint LANGUAGE sql AS
  $$ SELECT user_id FROM users WHERE email = p_email $$;
CREATE FUNCTION pg_temp.txn(p_ref text) RETURNS bigint LANGUAGE sql AS
  $$ SELECT txn_id FROM transactions WHERE external_ref = p_ref $$;
CREATE FUNCTION pg_temp.link(p_case bigint, p_from text, p_to text, p_amt numeric, p_method text DEFAULT 'MANUAL')
RETURNS text LANGUAGE sql AS $$
  SELECT format('CALL confirm_link(%s, %s, %s, %s, %L, %s)', p_case, pg_temp.txn(p_from), pg_temp.txn(p_to),
                p_amt, p_method, pg_temp.uid('inv@demo.in'))
$$;
CREATE TEMP TABLE results (n serial, line text);

-- T12: trace from T1 on the scenario
CREATE TEMP TABLE tr AS SELECT * FROM trace_candidates(pg_temp.txn('T1'));
INSERT INTO results (line)
SELECT CASE WHEN count(*) = 6 AND string_agg(t.external_ref, ',' ORDER BY t.external_ref) = 'T1,T2,T3,T4,T5,T7'
            THEN 'PASS' ELSE 'FAIL' END
       || '  T12a trace terminates on the cycle, returns ' || string_agg(t.external_ref, ',' ORDER BY tr.depth, tr.occurred_at)
FROM tr JOIN transactions t USING (txn_id);
INSERT INTO results (line)
SELECT CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END || '  T12b T7 listed once (got ' || count(*) || ')'
FROM tr WHERE txn_id = pg_temp.txn('T7');
INSERT INTO results (line)
SELECT CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END || '  T12c no hop earlier than its parent (violations: ' || count(*) || ')'
FROM tr c JOIN transactions p ON p.txn_id = c.parent_txn_id WHERE c.occurred_at <= p.occurred_at;

-- T13: a transfer 4 days after the previous hop is outside the 72-hour window
INSERT INTO transactions (external_ref, source_account_id, destination_account_id, amount, channel, occurred_at)
SELECT 'LATE', d.account_id, e.account_id, 1000, 'UPI', timestamptz '2026-10-16 11:00+05:30'
FROM accounts d, accounts e WHERE d.account_ref = 'TP1000000006' AND e.account_ref = 'TP1000000007';
INSERT INTO results (line)
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM trace_candidates(pg_temp.txn('T1')) WHERE txn_id = pg_temp.txn('LATE'))
             AND EXISTS (SELECT 1 FROM trace_candidates(pg_temp.txn('T1'), 5, interval '5 days') WHERE txn_id = pg_temp.txn('LATE'))
            THEN 'PASS' ELSE 'FAIL' END || '  T13 4-day-later transfer excluded at 72h, included at 5 days';

-- Fixture: C1 (V1 on T1, 40,000) and C2 (V2 on T6, 20,000), both moved to INVESTIGATING
INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative) VALUES
  (pg_temp.uid('v1@demo.in'), pg_temp.txn('T1'), 40000, 'Fake courier asked me to pay a customs fee by UPI.'),
  (pg_temp.uid('v2@demo.in'), pg_temp.txn('T6'), 20000, 'A parcel delivery agent said I owe customs duty.');
CREATE TEMP TABLE c AS
  SELECT (SELECT case_id FROM fraud_cases WHERE disputed_txn_id = pg_temp.txn('T1')) AS c1,
         (SELECT case_id FROM fraud_cases WHERE disputed_txn_id = pg_temp.txn('T6')) AS c2;
SELECT pg_temp.act_as('sup1@demo.in') \g /dev/null
UPDATE fraud_cases SET status = 'UNDER_REVIEW' WHERE case_id IN (SELECT c1 FROM c UNION SELECT c2 FROM c);
SELECT pg_temp.act_as('inv@demo.in') \g /dev/null
UPDATE fraud_cases SET status = 'INVESTIGATING' WHERE case_id IN (SELECT c1 FROM c UNION SELECT c2 FROM c);

INSERT INTO results (line) SELECT pg_temp.expect_ok('start_trace C1 (root T1, 40,000)', format('CALL start_trace(%s)', c1)) FROM c;
INSERT INTO results (line) SELECT pg_temp.expect_ok('start_trace C2 (root T6, 20,000)', format('CALL start_trace(%s)', c2)) FROM c;
INSERT INTO results (line) SELECT pg_temp.expect_ok('C1 confirms T1 -> T2 25,000', pg_temp.link(c1, 'T1', 'T2', 25000)) FROM c;
INSERT INTO results (line) SELECT pg_temp.expect_ok('C1 confirms T1 -> T3 15,000', pg_temp.link(c1, 'T1', 'T3', 15000)) FROM c;

-- T09 node_outflow: T1 node holds 40,000; 25,000 + 15,000 already out; 5,000 more to T7 crosses it
INSERT INTO results (line) SELECT pg_temp.expect_error('T09 links out of T1 total 45,000 (> 40,000)',
  pg_temp.link(c1, 'T1', 'T7', 5000), 'TP001') FROM c;

-- FIFO suggestion from T2 at account B (T2 25,000 then T6 20,000 in; T4 10,000 and T5 8,000 out)
INSERT INTO results (line)
SELECT CASE WHEN string_agg(t.external_ref || '=' || s.suggested_amount, ',' ORDER BY t.external_ref) = 'T4=10000.00,T5=8000.00'
            THEN 'PASS' ELSE 'FAIL' END
       || '  FIFO from T2 suggests ' || string_agg(t.external_ref || '=' || s.suggested_amount, ', ' ORDER BY t.external_ref)
FROM c, suggest_fifo(c.c1, pg_temp.txn('T2')) s JOIN transactions t ON t.txn_id = s.to_txn_id;

-- T08 via confirm_link: C1 records 7,000 of T4 (MANUAL); C2 tries 4,000 of T4 -> excess 1,000
INSERT INTO results (line) SELECT pg_temp.expect_ok('C1 confirms T2 -> T4 7,000 (MANUAL)', pg_temp.link(c1, 'T2', 'T4', 7000)) FROM c;
INSERT INTO results (line) SELECT pg_temp.expect_ok('C1 confirms T2 -> T5 8,000 (FIFO)', pg_temp.link(c1, 'T2', 'T5', 8000, 'FIFO')) FROM c;
INSERT INTO results (line) SELECT pg_temp.expect_error('T08 C2 confirms T6 -> T4 4,000 (C1 has 7,000 of 10,000)',
  pg_temp.link(c2, 'T6', 'T4', 4000), 'TP001') FROM c;
INSERT INTO results (line) SELECT pg_temp.expect_ok('C2 confirms T6 -> T4 3,000 (fits)', pg_temp.link(c2, 'T6', 'T4', 3000)) FROM c;

-- T10 confirm_link business rules
INSERT INTO results (line) SELECT pg_temp.expect_error('T10a target earlier than source (T5 11:10 -> T2 10:20)',
  pg_temp.link(c1, 'T5', 'T2', 1000), 'TP002') FROM c;
INSERT INTO results (line) SELECT pg_temp.expect_error('T10b target not sent by receiving account (T2 -> T3)',
  pg_temp.link(c1, 'T2', 'T3', 1000), 'TP002') FROM c;
INSERT INTO results (line) SELECT pg_temp.expect_error('T10c source not a node of the case (T3 for C2)',
  pg_temp.link(c2, 'T3', 'T7', 1000), 'TP002') FROM c;

-- T11 node consistency: every non-root node's inflow equals the sum of its incoming links
INSERT INTO results (line)
SELECT CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END || '  T11 inflow = incoming links (mismatches: ' || count(*) || ')'
FROM (SELECT n.node_id
      FROM trace_nodes n JOIN fund_flow_links l ON l.to_node_id = n.node_id
      WHERE NOT n.is_root
      GROUP BY n.node_id, n.inflow_amount
      HAVING n.inflow_amount <> SUM(l.attributed_amount)) x;

-- Composite FK: a link cannot join nodes of two different cases
INSERT INTO results (line) SELECT pg_temp.expect_error('Composite FK blocks a cross-case link',
  format($q$INSERT INTO fund_flow_links (case_id, from_node_id, to_node_id, attributed_amount, method, linked_by)
            VALUES (%s, (SELECT node_id FROM trace_nodes WHERE case_id = %s AND is_root),
                        (SELECT node_id FROM trace_nodes WHERE case_id = %s AND is_root), 1, 'MANUAL', %s)$q$,
         c1, c1, c2, pg_temp.uid('inv@demo.in')), '23503') FROM c;

\set QUIET off
SELECT line AS result FROM results ORDER BY n;
ROLLBACK;
