-- 005_recovery.sql : assignment, loss verification, freezes, allocation, refunds, settlement, hand-back.
-- Every procedure checks the caller's role itself. Money steps lock freeze before case (the same order as
-- the engine triggers), re-check business rules, and let the six engine rules enforce the limits.

-- Assign or reassign an investigator (supervisors); the first assignment moves SUBMITTED -> UNDER_REVIEW.
CREATE PROCEDURE assign_case(p_case_id bigint, p_investigator_id bigint, p_actor bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_status text;
BEGIN
  PERFORM require_role('SUPERVISOR');
  SELECT status INTO v_status FROM fraud_cases WHERE case_id = p_case_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'case not found';
  END IF;
  IF v_status IN ('CLOSED', 'REJECTED') THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'case is ' || v_status;
  END IF;
  UPDATE case_assignments SET ended_at = clock_timestamp()
  WHERE case_id = p_case_id AND ended_at IS NULL;
  INSERT INTO case_assignments (case_id, investigator_id, assigned_by, assigned_at)
  VALUES (p_case_id, p_investigator_id, actor_id(), clock_timestamp());
  IF v_status = 'SUBMITTED' THEN
    UPDATE fraud_cases SET status = 'UNDER_REVIEW' WHERE case_id = p_case_id;
  END IF;
END $$;

-- Supervisor records the verified loss (CHECK: 0 < loss <= reported). Lowering it below existing
-- allocations is rejected by rule allocation_within_loss.
CREATE PROCEDURE verify_loss(p_case_id bigint, p_amount numeric, p_actor bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_status text;
BEGIN
  PERFORM require_role('SUPERVISOR');
  SELECT status INTO v_status FROM fraud_cases WHERE case_id = p_case_id FOR UPDATE;
  IF v_status IS DISTINCT FROM 'INVESTIGATING' AND v_status IS DISTINCT FROM 'RECOVERY' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'loss can be verified only while INVESTIGATING or in RECOVERY';
  END IF;
  UPDATE fraud_cases SET verified_loss = p_amount, verified_by = actor_id() WHERE case_id = p_case_id;
END $$;

-- Pays every PAID allocation of a closed (SETTLED/EXPIRED) freeze not paid yet: one RECOVERY transfer from
-- the frozen account to the account the victim paid from. The freeze is already closed, so its hold no
-- longer counts against the balance.
CREATE FUNCTION pay_out_freeze(p_freeze_id bigint) RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r record; v_txn bigint; v_total numeric := 0;
BEGIN
  FOR r IN
    SELECT a.allocation_id, a.amount, f.account_id AS from_acct, t.source_account_id AS victim_acct
    FROM recovery_allocations a
    JOIN account_freezes f ON f.freeze_id = a.freeze_id
    JOIN fraud_cases c ON c.case_id = a.case_id
    JOIN transactions t ON t.txn_id = c.disputed_txn_id
    WHERE a.freeze_id = p_freeze_id AND a.status = 'PAID' AND a.credit_txn_id IS NULL AND a.amount > 0
      AND f.status IN ('SETTLED', 'EXPIRED')
    ORDER BY a.allocation_id
  LOOP
    INSERT INTO transactions (external_ref, source_account_id, destination_account_id, amount, channel, occurred_at)
    VALUES ('RC-' || r.allocation_id, r.from_acct, r.victim_acct, r.amount, 'RECOVERY', clock_timestamp())
    RETURNING txn_id INTO v_txn;
    UPDATE recovery_allocations SET credit_txn_id = v_txn WHERE allocation_id = r.allocation_id;
    v_total := v_total + r.amount;
  END LOOP;
  RETURN v_total;
END $$;

-- Lazy expiry, run first by every recovery procedure (no scheduler needed). Partly refunded allocations keep
-- what was paid, untouched ones are cancelled, and what was refunded is paid out.
CREATE PROCEDURE expire_freezes()
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_ids bigint[];
BEGIN
  SELECT array_agg(freeze_id ORDER BY freeze_id) INTO v_ids
  FROM account_freezes WHERE status = 'ACTIVE' AND expires_at <= now();
  IF v_ids IS NULL THEN RETURN; END IF;
  UPDATE recovery_allocations a SET amount = r.paid, status = 'PAID'
  FROM (SELECT allocation_id, SUM(amount) AS paid FROM refunds
        WHERE status = 'PROCESSED' GROUP BY allocation_id) r
  WHERE a.allocation_id = r.allocation_id AND a.status = 'ACTIVE' AND a.freeze_id = ANY (v_ids);
  UPDATE recovery_allocations SET status = 'CANCELLED' WHERE status = 'ACTIVE' AND freeze_id = ANY (v_ids);
  UPDATE account_freezes SET status = 'EXPIRED' WHERE freeze_id = ANY (v_ids);
  PERFORM pay_out_freeze(f) FROM unnest(v_ids) AS f;
END $$;

-- The assigned investigator requests a freeze on an open account the case's confirmed trace reached.
CREATE FUNCTION request_freeze(p_case_id bigint, p_account_id bigint, p_amount numeric, p_actor bigint)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_status text; v_id bigint;
BEGIN
  PERFORM require_assigned(p_case_id);
  SELECT status INTO v_status FROM fraud_cases WHERE case_id = p_case_id;
  IF v_status IS DISTINCT FROM 'INVESTIGATING' AND v_status IS DISTINCT FROM 'RECOVERY' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'freezes can be requested only while INVESTIGATING or in RECOVERY';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM trace_nodes n JOIN transactions t ON t.txn_id = n.txn_id
                 WHERE n.case_id = p_case_id AND t.destination_account_id = p_account_id) THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'account is not on this case''s confirmed trace';
  END IF;
  IF (SELECT status FROM accounts WHERE account_id = p_account_id) <> 'ACTIVE' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'account is closed';
  END IF;
  IF EXISTS (SELECT 1 FROM account_freezes WHERE requested_for_case = p_case_id AND account_id = p_account_id
             AND status IN ('REQUESTED', 'ACTIVE')) THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'this case already has an open freeze on this account';
  END IF;
  INSERT INTO account_freezes (account_id, requested_for_case, requested_by, frozen_amount)
  VALUES (p_account_id, p_case_id, actor_id(), p_amount)
  RETURNING freeze_id INTO v_id;
  RETURN v_id;
END $$;

-- Supervisor approves (ACTIVE: rule freeze_within_balance fires) or declines. Four-eyes: CHECK on the table.
CREATE PROCEDURE decide_freeze(p_freeze_id bigint, p_approve boolean, p_actor bigint,
                                          p_expires_at timestamptz DEFAULT now() + interval '7 days')
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_freeze account_freezes;
BEGIN
  PERFORM require_role('SUPERVISOR');
  CALL expire_freezes();
  SELECT * INTO v_freeze FROM account_freezes WHERE freeze_id = p_freeze_id FOR UPDATE;
  IF NOT FOUND OR v_freeze.status <> 'REQUESTED' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'freeze is not awaiting a decision';
  END IF;
  UPDATE account_freezes
  SET status      = CASE WHEN p_approve THEN 'ACTIVE' ELSE 'DECLINED' END,
      approved_by = actor_id(),
      approved_at = now(),
      expires_at  = CASE WHEN p_approve THEN p_expires_at END
  WHERE freeze_id = p_freeze_id;
END $$;

-- Release an active freeze early (nothing allocated from it): the hold ends, nothing is paid.
CREATE PROCEDURE release_freeze(p_freeze_id bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_freeze account_freezes;
BEGIN
  PERFORM require_role('SUPERVISOR');
  CALL expire_freezes();
  SELECT * INTO v_freeze FROM account_freezes WHERE freeze_id = p_freeze_id FOR UPDATE;
  IF NOT FOUND OR v_freeze.status <> 'ACTIVE' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'only an ACTIVE freeze can be released';
  END IF;
  IF EXISTS (SELECT 1 FROM recovery_allocations WHERE freeze_id = p_freeze_id AND status IN ('ACTIVE', 'PAID')) THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'money from this freeze is allocated: settle it instead';
  END IF;
  UPDATE account_freezes SET status = 'RELEASED' WHERE freeze_id = p_freeze_id;
END $$;

-- Supervisor reserves part of a freeze for a case in RECOVERY.
-- Extra rule: a case may claim at an account only what its confirmed trace brought there.
CREATE FUNCTION allocate_recovery(p_freeze_id bigint, p_case_id bigint, p_amount numeric, p_actor bigint)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_freeze  account_freezes;
  v_status  text;
  v_traced  numeric;
  v_claimed numeric;
  v_id      bigint;
BEGIN
  PERFORM require_role('SUPERVISOR');
  CALL expire_freezes();
  SELECT * INTO v_freeze FROM account_freezes WHERE freeze_id = p_freeze_id FOR UPDATE;   -- freeze first
  IF NOT FOUND OR v_freeze.status <> 'ACTIVE' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'freeze is not active';
  END IF;
  SELECT status INTO v_status FROM fraud_cases WHERE case_id = p_case_id FOR UPDATE;      -- then case
  IF v_status IS DISTINCT FROM 'RECOVERY' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'case is not in RECOVERY';
  END IF;
  SELECT COALESCE(SUM(n.inflow_amount), 0) INTO v_traced
  FROM trace_nodes n JOIN transactions t ON t.txn_id = n.txn_id
  WHERE n.case_id = p_case_id AND t.destination_account_id = v_freeze.account_id;
  SELECT COALESCE(SUM(a.amount), 0) INTO v_claimed
  FROM recovery_allocations a JOIN account_freezes f ON f.freeze_id = a.freeze_id
  WHERE a.case_id = p_case_id AND f.account_id = v_freeze.account_id AND a.status IN ('ACTIVE', 'PAID');
  IF v_claimed + p_amount > v_traced THEN
    RAISE EXCEPTION USING ERRCODE = 'TP001', MESSAGE = 'allocation exceeds money traced to this account',
      DETAIL = 'traced=' || v_traced || ' already_claimed=' || v_claimed || ' requested=' || p_amount
               || ' excess=' || (v_claimed + p_amount - v_traced);
  END IF;
  INSERT INTO recovery_allocations (freeze_id, case_id, amount, status, allocated_by)
  VALUES (p_freeze_id, p_case_id, p_amount, 'ACTIVE', actor_id())
  RETURNING allocation_id INTO v_id;
  RETURN v_id;
END $$;

-- Exactly-once refund: a replay with the same idempotency key returns the original refund id;
-- the same key with different data is refused.
CREATE FUNCTION process_refund(p_allocation_id bigint, p_amount numeric, p_idempotency_key uuid, p_actor bigint)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_alloc recovery_allocations; v_prev refunds; v_refund_id bigint; v_paid numeric;
BEGIN
  PERFORM require_role('SUPERVISOR');
  CALL expire_freezes();
  SELECT * INTO v_alloc FROM recovery_allocations WHERE allocation_id = p_allocation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'allocation not found';
  END IF;
  SELECT * INTO v_prev FROM refunds WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_prev.allocation_id <> p_allocation_id OR v_prev.amount <> p_amount THEN
      RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'idempotency key reused with different data';
    END IF;
    RETURN v_prev.refund_id;
  END IF;
  IF v_alloc.status <> 'ACTIVE' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'allocation is not ACTIVE';
  END IF;
  INSERT INTO refunds (allocation_id, amount, status, idempotency_key, processed_by)
  VALUES (p_allocation_id, p_amount, 'PROCESSED', p_idempotency_key, actor_id())
  RETURNING refund_id INTO v_refund_id;
  SELECT SUM(amount) INTO v_paid FROM refunds WHERE allocation_id = p_allocation_id AND status = 'PROCESSED';
  IF v_paid = v_alloc.amount THEN
    UPDATE recovery_allocations SET status = 'PAID' WHERE allocation_id = p_allocation_id;
  END IF;
  RETURN v_refund_id;
END $$;

-- Settle: unpaid allocations cancelled, partly paid ones shrink to what was paid, freeze SETTLED,
-- then the paid money moves to the victims. A freeze past its date cannot be settled.
CREATE FUNCTION settle_freeze(p_freeze_id bigint, p_actor bigint)
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_freeze account_freezes;
BEGIN
  PERFORM require_role('SUPERVISOR');
  CALL expire_freezes();
  SELECT * INTO v_freeze FROM account_freezes WHERE freeze_id = p_freeze_id FOR UPDATE;
  IF NOT FOUND OR v_freeze.status <> 'ACTIVE' OR v_freeze.expires_at <= now() THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'only an ACTIVE, unexpired freeze can be settled';
  END IF;
  UPDATE recovery_allocations a SET amount = r.paid, status = 'PAID'
  FROM (SELECT allocation_id, SUM(amount) AS paid FROM refunds
        WHERE status = 'PROCESSED' GROUP BY allocation_id) r
  WHERE a.allocation_id = r.allocation_id AND a.freeze_id = p_freeze_id AND a.status = 'ACTIVE';
  UPDATE recovery_allocations SET status = 'CANCELLED' WHERE freeze_id = p_freeze_id AND status = 'ACTIVE';
  UPDATE account_freezes SET status = 'SETTLED' WHERE freeze_id = p_freeze_id;
  RETURN pay_out_freeze(p_freeze_id);
END $$;

-- The assigned investigator hands a case back (before accepting it, or while investigating if nothing has
-- been confirmed yet). The assignment ends; the case waits for a supervisor to reassign it.
CREATE PROCEDURE hand_back_case(p_case_id bigint, p_reason text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_status text;
BEGIN
  PERFORM require_assigned(p_case_id);
  IF p_reason IS NULL OR length(btrim(p_reason)) < 5 THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'say why you are handing the case back';
  END IF;
  SELECT status INTO v_status FROM fraud_cases WHERE case_id = p_case_id FOR UPDATE;
  IF v_status NOT IN ('UNDER_REVIEW', 'INVESTIGATING') THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'a case in ' || v_status || ' cannot be handed back';
  END IF;
  IF EXISTS (SELECT 1 FROM fund_flow_links WHERE case_id = p_case_id)
     OR EXISTS (SELECT 1 FROM account_freezes WHERE requested_for_case = p_case_id AND status IN ('REQUESTED', 'ACTIVE')) THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'links or freezes are already confirmed for this case: ask a supervisor to reassign it';
  END IF;
  DELETE FROM trace_nodes WHERE case_id = p_case_id;          -- only the root can exist without links
  UPDATE case_assignments SET ended_at = clock_timestamp() WHERE case_id = p_case_id AND ended_at IS NULL;
  IF v_status = 'INVESTIGATING' THEN
    PERFORM set_config('app.status_note', 'Handed back by the investigator: ' || btrim(p_reason), true);
    UPDATE fraud_cases SET status = 'UNDER_REVIEW' WHERE case_id = p_case_id;
    PERFORM set_config('app.status_note', '', true);
  END IF;
END $$;
