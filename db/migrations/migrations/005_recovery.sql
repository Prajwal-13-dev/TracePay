-- 005_recovery.sql : assignment, loss verification, freezes, allocation, refunds, settlement
-- Handbook Section 16. Every money step locks freeze before case (same order as the engine
-- triggers), re-checks business rules, and lets the six engine rules enforce the limits.
-- Status changes need app.user_role set by the caller (the API sets it per transaction).

-- Assign or reassign an investigator; first assignment moves SUBMITTED -> UNDER_REVIEW.
CREATE PROCEDURE assign_case(p_case_id bigint, p_investigator_id bigint, p_actor bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_status text;
BEGIN
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
  VALUES (p_case_id, p_investigator_id, p_actor, clock_timestamp());
  IF v_status = 'SUBMITTED' THEN
    UPDATE fraud_cases SET status = 'UNDER_REVIEW' WHERE case_id = p_case_id;
  END IF;
END $$;

-- Supervisor records the verified loss (CHECK: 0 < loss <= reported). Lowering it below
-- existing allocations is rejected by rule allocation_within_loss.
CREATE PROCEDURE verify_loss(p_case_id bigint, p_amount numeric, p_actor bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_status text;
BEGIN
  SELECT status INTO v_status FROM fraud_cases WHERE case_id = p_case_id FOR UPDATE;
  IF v_status IS DISTINCT FROM 'INVESTIGATING' AND v_status IS DISTINCT FROM 'RECOVERY' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'loss can be verified only while INVESTIGATING or in RECOVERY';
  END IF;
  UPDATE fraud_cases SET verified_loss = p_amount, verified_by = p_actor WHERE case_id = p_case_id;
END $$;

-- Lazy expiry: run first by every recovery procedure, so no scheduler is needed.
CREATE PROCEDURE expire_freezes()
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  -- Partly refunded allocations keep what was paid and stop there.
  UPDATE recovery_allocations a SET amount = r.paid, status = 'PAID'
  FROM (SELECT allocation_id, SUM(amount) AS paid FROM refunds
        WHERE status = 'PROCESSED' GROUP BY allocation_id) r
  WHERE a.allocation_id = r.allocation_id AND a.status = 'ACTIVE'
    AND a.freeze_id IN (SELECT freeze_id FROM account_freezes WHERE status = 'ACTIVE' AND expires_at <= now());
  -- Untouched allocations on expired freezes are cancelled.
  UPDATE recovery_allocations SET status = 'CANCELLED'
  WHERE status = 'ACTIVE'
    AND freeze_id IN (SELECT freeze_id FROM account_freezes WHERE status = 'ACTIVE' AND expires_at <= now());
  UPDATE account_freezes SET status = 'EXPIRED' WHERE status = 'ACTIVE' AND expires_at <= now();
$$;

-- Investigator requests a freeze on an account the case's confirmed trace reached.
CREATE FUNCTION request_freeze(p_case_id bigint, p_account_id bigint, p_amount numeric, p_actor bigint)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_status text; v_id bigint;
BEGIN
  SELECT status INTO v_status FROM fraud_cases WHERE case_id = p_case_id;
  IF v_status IS DISTINCT FROM 'INVESTIGATING' AND v_status IS DISTINCT FROM 'RECOVERY' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'freezes can be requested only while INVESTIGATING or in RECOVERY';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM trace_nodes n JOIN transactions t ON t.txn_id = n.txn_id
                 WHERE n.case_id = p_case_id AND t.destination_account_id = p_account_id) THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'account is not on this case''s confirmed trace';
  END IF;
  INSERT INTO account_freezes (account_id, requested_for_case, requested_by, frozen_amount)
  VALUES (p_account_id, p_case_id, p_actor, p_amount)
  RETURNING freeze_id INTO v_id;
  RETURN v_id;
END $$;

-- Supervisor approves (ACTIVE, rule freeze_within_balance fires) or declines.
-- Four-eyes rule: CHECK approved_by <> requested_by on the table.
CREATE PROCEDURE decide_freeze(p_freeze_id bigint, p_approve boolean, p_actor bigint,
                               p_expires_at timestamptz DEFAULT now() + interval '7 days')
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_freeze account_freezes;
BEGIN
  CALL expire_freezes();
  SELECT * INTO v_freeze FROM account_freezes WHERE freeze_id = p_freeze_id FOR UPDATE;
  IF NOT FOUND OR v_freeze.status <> 'REQUESTED' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'freeze is not awaiting a decision';
  END IF;
  UPDATE account_freezes
  SET status      = CASE WHEN p_approve THEN 'ACTIVE' ELSE 'DECLINED' END,
      approved_by = p_actor,
      approved_at = now(),
      expires_at  = CASE WHEN p_approve THEN p_expires_at END
  WHERE freeze_id = p_freeze_id;
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
  -- Rules allocation_within_freeze and allocation_within_loss fire on this INSERT.
  INSERT INTO recovery_allocations (freeze_id, case_id, amount, status, allocated_by)
  VALUES (p_freeze_id, p_case_id, p_amount, 'ACTIVE', p_actor)
  RETURNING allocation_id INTO v_id;
  RETURN v_id;
END $$;

-- Exactly-once refund: a replay with the same idempotency key returns the original refund id.
CREATE FUNCTION process_refund(p_allocation_id bigint, p_amount numeric, p_idempotency_key uuid, p_actor bigint)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_alloc recovery_allocations; v_refund_id bigint; v_paid numeric;
BEGIN
  CALL expire_freezes();
  -- Lock first: a concurrent replay with the same key waits here...
  SELECT * INTO v_alloc FROM recovery_allocations WHERE allocation_id = p_allocation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'allocation not found';
  END IF;
  -- ...then sees the first call's committed refund and returns it, with no new effect.
  SELECT refund_id INTO v_refund_id FROM refunds WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    RETURN v_refund_id;
  END IF;
  IF v_alloc.status <> 'ACTIVE' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'allocation is not ACTIVE';
  END IF;
  -- Rule refund_within_allocation fires on this INSERT.
  INSERT INTO refunds (allocation_id, amount, status, idempotency_key, processed_by)
  VALUES (p_allocation_id, p_amount, 'PROCESSED', p_idempotency_key, p_actor)
  RETURNING refund_id INTO v_refund_id;
  SELECT SUM(amount) INTO v_paid FROM refunds WHERE allocation_id = p_allocation_id AND status = 'PROCESSED';
  IF v_paid = v_alloc.amount THEN
    UPDATE recovery_allocations SET status = 'PAID' WHERE allocation_id = p_allocation_id;
  END IF;
  RETURN v_refund_id;
END $$;

-- Close a freeze: unpaid allocations are cancelled, partly paid ones shrink to what was paid,
-- the freeze becomes SETTLED, and only then is the paid total debited from the account
-- (debiting first would briefly break freeze_within_balance). Returns the amount paid out.
CREATE FUNCTION settle_freeze(p_freeze_id bigint, p_actor bigint)
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_freeze account_freezes; v_paid numeric;
BEGIN
  SELECT * INTO v_freeze FROM account_freezes WHERE freeze_id = p_freeze_id FOR UPDATE;
  IF NOT FOUND OR v_freeze.status <> 'ACTIVE' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'only an ACTIVE freeze can be settled';
  END IF;
  UPDATE recovery_allocations a SET amount = r.paid, status = 'PAID'
  FROM (SELECT allocation_id, SUM(amount) AS paid FROM refunds
        WHERE status = 'PROCESSED' GROUP BY allocation_id) r
  WHERE a.allocation_id = r.allocation_id AND a.freeze_id = p_freeze_id AND a.status = 'ACTIVE';
  UPDATE recovery_allocations SET status = 'CANCELLED' WHERE freeze_id = p_freeze_id AND status = 'ACTIVE';
  SELECT COALESCE(SUM(amount), 0) INTO v_paid
  FROM recovery_allocations WHERE freeze_id = p_freeze_id AND status = 'PAID';
  UPDATE account_freezes SET status = 'SETTLED' WHERE freeze_id = p_freeze_id;
  UPDATE accounts SET balance = balance - v_paid WHERE account_id = v_freeze.account_id;
  RETURN v_paid;
END $$;
