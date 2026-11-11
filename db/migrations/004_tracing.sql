-- 004_tracing.sql : candidate paths (recursive CTE), start_trace, confirm_link, FIFO suggestion.
-- Only the assigned investigator traces (require_assigned). Amounts are capped by the engine rules
-- txn_capacity and node_outflow (003).

-- 1. Candidate paths from a disputed transfer: chronological, cycle-safe, within a time window per hop.
--    Terminates because every hop is strictly later and no transfer repeats on a path. p_max_depth is an
--    optional cap (the app passes 10, the same cap as the Neo4j query). RECOVERY transfers are not hops.
CREATE FUNCTION trace_candidates(p_txn_id bigint, p_max_depth int DEFAULT NULL,
                                            p_window interval DEFAULT interval '72 hours')
RETURNS TABLE (txn_id bigint, parent_txn_id bigint, depth int,
               source_account_id bigint, destination_account_id bigint,
               amount numeric, occurred_at timestamptz, upper_bound numeric, path bigint[])
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE trace AS (
    SELECT t.txn_id, NULL::bigint AS parent_txn_id, 0 AS depth,
           t.source_account_id, t.destination_account_id, t.amount, t.occurred_at,
           t.amount AS upper_bound, ARRAY[t.txn_id] AS path
    FROM transactions t
    WHERE t.txn_id = p_txn_id
    UNION ALL
    SELECT n.txn_id, tr.txn_id, tr.depth + 1,
           n.source_account_id, n.destination_account_id, n.amount, n.occurred_at,
           LEAST(tr.upper_bound, n.amount), tr.path || n.txn_id
    FROM trace tr
    JOIN transactions n
      ON n.source_account_id = tr.destination_account_id   -- money leaves the account it reached
     AND n.occurred_at > tr.occurred_at                     -- ...only after it arrived
     AND n.occurred_at <= tr.occurred_at + p_window         -- ...within the time window
     AND n.channel <> 'RECOVERY'                            -- refunds to victims are not laundering hops
    WHERE (p_max_depth IS NULL OR tr.depth < p_max_depth)
      AND n.txn_id <> ALL (tr.path)
  )
  SELECT DISTINCT ON (txn_id) txn_id, parent_txn_id, depth, source_account_id,
         destination_account_id, amount, occurred_at, upper_bound, path
  FROM trace
  ORDER BY txn_id, depth, upper_bound DESC;
$$;

-- 2. Start a trace: the disputed transfer becomes the root node with the reported amount. Idempotent.
CREATE PROCEDURE start_trace(p_case_id bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_case fraud_cases;
BEGIN
  PERFORM require_assigned(p_case_id);
  SELECT * INTO v_case FROM fraud_cases WHERE case_id = p_case_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'case not found';
  END IF;
  IF v_case.status <> 'INVESTIGATING' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'case is not INVESTIGATING';
  END IF;
  INSERT INTO trace_nodes (case_id, txn_id, is_root, inflow_amount)
  VALUES (p_case_id, v_case.disputed_txn_id, true, v_case.reported_amount)
  ON CONFLICT (case_id, txn_id) DO NOTHING;
END $$;

-- 3. Confirm that p_amount of p_from_txn flowed into p_to_txn for this case. Creates the target node or adds
--    to its inflow; confirming more of an existing link adds to it. Atomic.
CREATE PROCEDURE confirm_link(p_case_id bigint, p_from_txn bigint, p_to_txn bigint,
                                         p_amount numeric, p_method text, p_actor bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_status  text;
  v_from    trace_nodes;
  v_src     transactions;
  v_dst     transactions;
  v_to_node bigint;
BEGIN
  PERFORM require_assigned(p_case_id);
  SELECT status INTO v_status FROM fraud_cases WHERE case_id = p_case_id;
  IF v_status IS DISTINCT FROM 'INVESTIGATING' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'case is not INVESTIGATING';
  END IF;

  SELECT * INTO v_from FROM trace_nodes WHERE case_id = p_case_id AND txn_id = p_from_txn;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'source transfer is not a confirmed node of this case';
  END IF;

  SELECT * INTO v_src FROM transactions WHERE txn_id = p_from_txn;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'source transfer not found';
  END IF;
  SELECT * INTO v_dst FROM transactions WHERE txn_id = p_to_txn;
  IF NOT FOUND OR v_dst.source_account_id <> v_src.destination_account_id OR v_dst.channel = 'RECOVERY' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'target is not an outgoing transfer of the receiving account';
  END IF;
  IF v_dst.occurred_at <= v_src.occurred_at THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'target transfer must happen after the source transfer';
  END IF;

  INSERT INTO trace_nodes (case_id, txn_id, inflow_amount)
  VALUES (p_case_id, p_to_txn, p_amount)
  ON CONFLICT (case_id, txn_id)
  DO UPDATE SET inflow_amount = trace_nodes.inflow_amount + EXCLUDED.inflow_amount
  RETURNING node_id INTO v_to_node;

  INSERT INTO fund_flow_links (case_id, from_node_id, to_node_id, attributed_amount, method, linked_by)
  VALUES (p_case_id, v_from.node_id, v_to_node, p_amount, p_method, actor_id())
  ON CONFLICT (from_node_id, to_node_id)
  DO UPDATE SET attributed_amount = fund_flow_links.attributed_amount + EXCLUDED.attributed_amount,
                method = EXCLUDED.method, linked_by = EXCLUDED.linked_by, linked_at = now();
END $$;

-- 4. FIFO suggestion (window functions): the receiving account spends money in arrival order.
--    Inflows and outflows become intervals on running-sum lines that start at the same moment (window before
--    the disputed inflow), so money spent earlier uses up earlier inflows. Only later outflows are suggested.
CREATE FUNCTION suggest_fifo(p_case_id bigint, p_from_txn bigint,
                                        p_window interval DEFAULT interval '72 hours')
RETURNS TABLE (to_txn_id bigint, suggested_amount numeric)
LANGUAGE sql STABLE AS $$
  WITH src AS (
    SELECT t.txn_id, t.destination_account_id AS acct, t.occurred_at AS t0, n.inflow_amount
    FROM trace_nodes n JOIN transactions t ON t.txn_id = n.txn_id
    WHERE n.case_id = p_case_id AND n.txn_id = p_from_txn
  ),
  inflows AS (
    SELECT t.txn_id, SUM(t.amount) OVER w - t.amount AS lo, SUM(t.amount) OVER w AS hi
    FROM transactions t, src
    WHERE t.destination_account_id = src.acct
      AND t.occurred_at > src.t0 - p_window AND t.occurred_at <= src.t0 + p_window
    WINDOW w AS (ORDER BY t.occurred_at, t.txn_id)
  ),
  tainted AS (
    SELECT i.lo, i.lo + src.inflow_amount AS hi
    FROM inflows i JOIN src ON src.txn_id = i.txn_id
  ),
  outflows AS (
    SELECT t.txn_id, t.occurred_at, SUM(t.amount) OVER w - t.amount AS lo, SUM(t.amount) OVER w AS hi
    FROM transactions t, src
    WHERE t.source_account_id = src.acct AND t.channel <> 'RECOVERY'
      AND t.occurred_at > src.t0 - p_window AND t.occurred_at <= src.t0 + p_window
    WINDOW w AS (ORDER BY t.occurred_at, t.txn_id)
  )
  SELECT o.txn_id, LEAST(o.hi, x.hi) - GREATEST(o.lo, x.lo)
  FROM outflows o CROSS JOIN tainted x, src
  WHERE o.occurred_at > src.t0
    AND LEAST(o.hi, x.hi) > GREATEST(o.lo, x.lo)
  ORDER BY o.txn_id;
$$;
