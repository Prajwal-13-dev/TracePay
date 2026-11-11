-- Query catalogue (handbook Section 17): every required SQL concept, run on a demo state.
-- Builds the demo workflow inside a transaction, runs each query, then rolls back.
-- Run: docker compose exec postgres psql -U tracepay_owner -d tracepay -f /db/queries/catalogue.sql
\set QUIET on
\pset footer off
BEGIN;
SELECT set_config('app.user_id', (SELECT user_id FROM users WHERE email='sup1@demo.in')::text, true),
       set_config('app.user_role', 'SUPERVISOR', true) \g /dev/null

-- Demo state: C1 and C2 traced to D, freeze at D, allocations, one refund
DO $$
DECLARE c1 bigint; c2 bigint; f bigint; a bigint;
  inv  bigint := (SELECT user_id FROM users WHERE email='inv@demo.in');
  sup  bigint := (SELECT user_id FROM users WHERE email='sup1@demo.in');
  tx   bigint[] := ARRAY(SELECT txn_id FROM transactions WHERE external_ref ~ '^T[1-7]$' ORDER BY external_ref);
BEGIN
  INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative, priority) VALUES
    ((SELECT user_id FROM users WHERE email='v1@demo.in'), tx[1], 40000,
     'A fake courier called about a parcel stuck in customs and asked me to pay a customs fee by UPI.', 1)
    RETURNING case_id INTO c1;
  INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative, priority) VALUES
    ((SELECT user_id FROM users WHERE email='v2@demo.in'), tx[6], 20000,
     'Someone posing as a delivery agent said my package needed a customs duty payment before release.', 2)
    RETURNING case_id INTO c2;
  CALL assign_case(c1, inv, sup); CALL assign_case(c2, inv, sup);
  PERFORM set_config('app.user_id', inv::text, true);   -- the investigator acts (roles come from users)
  UPDATE fraud_cases SET status = 'INVESTIGATING' WHERE case_id IN (c1, c2);
  CALL start_trace(c1); CALL start_trace(c2);
  CALL confirm_link(c1, tx[1], tx[2], 25000, 'MANUAL', inv);
  CALL confirm_link(c1, tx[1], tx[3], 15000, 'MANUAL', inv);
  CALL confirm_link(c1, tx[2], tx[4],  7000, 'MANUAL', inv);
  CALL confirm_link(c1, tx[2], tx[5],  8000, 'FIFO',   inv);
  CALL confirm_link(c2, tx[6], tx[4],  3000, 'MANUAL', inv);
  f := request_freeze(c1, (SELECT account_id FROM accounts WHERE account_ref='TP1000000006'), 10000, inv);
  PERFORM set_config('app.user_id', sup::text, true);   -- a supervisor acts
  CALL decide_freeze(f, true, sup);
  CALL verify_loss(c1, 40000, sup); CALL verify_loss(c2, 20000, sup);
  UPDATE fraud_cases SET status = 'RECOVERY' WHERE case_id IN (c1, c2);
  a := allocate_recovery(f, c1, 7000, sup);
  PERFORM allocate_recovery(f, c2, 3000, sup);
  PERFORM process_refund(a, 4000, gen_random_uuid(), sup);
  UPDATE fraud_cases SET investigator_notes = 'Mule account D shared with case ' || c2 WHERE case_id = c1;
END $$;
SELECT refresh_case_summary() \g /dev/null
\set QUIET off

\echo '\n== 17.1 Materialized view: supervisor_case_summary'
SELECT * FROM supervisor_case_summary ORDER BY case_id;

\echo '\n== 17.1 View: freeze_capacity (allocation desk)'
SELECT * FROM freeze_capacity;

\echo '\n== 17.2 JOIN + GROUP BY + HAVING + ORDER BY: shared mule accounts'
SELECT a.account_ref, COUNT(DISTINCT n.case_id) AS open_cases, SUM(n.inflow_amount) AS disputed_inflow
FROM trace_nodes n
JOIN transactions t ON t.txn_id = n.txn_id
JOIN accounts a     ON a.account_id = t.destination_account_id
JOIN fraud_cases c  ON c.case_id = n.case_id
WHERE c.status IN ('INVESTIGATING', 'RECOVERY')
GROUP BY a.account_ref
HAVING COUNT(DISTINCT n.case_id) > 1
ORDER BY disputed_inflow DESC;

\echo '\n== 17.3 Nested subquery: cases with verified loss above the average'
SELECT case_id, verified_loss FROM fraud_cases
WHERE verified_loss > (SELECT AVG(verified_loss) FROM fraud_cases WHERE verified_loss IS NOT NULL)
ORDER BY verified_loss DESC;

\echo '\n== 17.3 Correlated subquery: accounts reached by more than one case'
SELECT a.account_id, a.account_ref FROM accounts a
WHERE (SELECT COUNT(DISTINCT n.case_id)
       FROM trace_nodes n JOIN transactions t ON t.txn_id = n.txn_id
       WHERE t.destination_account_id = a.account_id) > 1;

\echo '\n== 17.3 Correlated NOT EXISTS: traced accounts with no active freeze'
SELECT ta.case_id, a.account_ref FROM trace_accounts ta JOIN accounts a USING (account_id)
WHERE NOT EXISTS (SELECT 1 FROM active_freezes f WHERE f.account_id = ta.account_id)
ORDER BY ta.case_id, a.account_ref;

\echo '\n== 17.4 Window functions: running attributed total and gap between hops'
SELECT l.case_id, t.external_ref AS txn, l.attributed_amount,
       SUM(l.attributed_amount) OVER w AS running_attributed,
       t.occurred_at - LAG(t.occurred_at) OVER w AS gap_from_previous_hop
FROM fund_flow_links l
JOIN trace_nodes n  ON n.node_id = l.to_node_id
JOIN transactions t ON t.txn_id = n.txn_id
WINDOW w AS (PARTITION BY l.case_id ORDER BY t.occurred_at, l.link_id);

\echo '\n== 17.4 Window function: mule-account ranking'
SELECT a.account_ref, d.case_count, d.disputed_inflow,
       RANK() OVER (ORDER BY d.disputed_inflow DESC) AS inflow_rank
FROM account_disputed_inflow d JOIN accounts a USING (account_id);

\echo '\n== 17.5 INTERSECT: accounts shared by C1 and C2'
SELECT account_id FROM trace_accounts
WHERE case_id = (SELECT case_id FROM fraud_cases WHERE disputed_txn_id = (SELECT txn_id FROM transactions WHERE external_ref = 'T1'))
INTERSECT
SELECT account_id FROM trace_accounts
WHERE case_id = (SELECT case_id FROM fraud_cases WHERE disputed_txn_id = (SELECT txn_id FROM transactions WHERE external_ref = 'T6'));

\echo '\n== 17.5 EXCEPT: traced accounts that are not frozen'
SELECT account_id FROM trace_accounts EXCEPT SELECT account_id FROM active_freezes ORDER BY 1;

\echo '\n== 17.5 UNION: every account under investigation'
SELECT account_id, 'TRACED' AS reason FROM trace_accounts
UNION
SELECT account_id, 'FROZEN' FROM active_freezes ORDER BY 1, 2;

\echo '\n== 17.6 LEFT JOIN + NULL handling: freeze state of each traced account'
SELECT ta.case_id, a.account_ref, COALESCE(fc.remaining, 0) AS remaining_capacity,
       CASE WHEN fc.freeze_id IS NULL THEN 'NOT FROZEN' ELSE 'FROZEN' END AS state
FROM trace_accounts ta
JOIN accounts a ON a.account_id = ta.account_id
LEFT JOIN freeze_capacity fc ON fc.account_id = ta.account_id
ORDER BY ta.case_id, state, a.account_ref;

\echo '\n== 17.7 Full-text search (GIN index): courier "customs fee" -refund'
SELECT case_id, round(ts_rank_cd(search_vector, q, 32)::numeric, 3) AS rank,
       ts_headline('english', narrative, q) AS snippet
FROM fraud_cases, websearch_to_tsquery('english', 'courier "customs fee" -refund') AS q
WHERE search_vector @@ q
ORDER BY rank DESC LIMIT 20;

\echo '\n== Engine diagnostics: verify_invariant for every rule (expect no rows)'
SELECT d.name, v.* FROM invariant_definitions d, verify_invariant(d.name) v;

ROLLBACK;
