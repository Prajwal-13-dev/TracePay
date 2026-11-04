-- 002_integrity.sql : immutability, complaint rules, roles, case state machine, audit log
-- Error codes: TP002 business rule, TP003 illegal transition, TP004 append-only, TP005 complaint rule

-- 1. Append-only / immutable tables -------------------------------------------
CREATE FUNCTION forbid_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE = 'TP004', MESSAGE = TG_TABLE_NAME || ' is append-only';
END $$;

CREATE TRIGGER transactions_immutable BEFORE UPDATE OR DELETE ON transactions
  FOR EACH ROW EXECUTE FUNCTION forbid_change();
CREATE TRIGGER audit_log_append_only BEFORE UPDATE OR DELETE ON audit_log
  FOR EACH ROW EXECUTE FUNCTION forbid_change();
CREATE TRIGGER audit_log_no_truncate BEFORE TRUNCATE ON audit_log
  FOR EACH STATEMENT EXECUTE FUNCTION forbid_change();
CREATE TRIGGER status_history_append_only BEFORE UPDATE OR DELETE ON case_status_history
  FOR EACH ROW EXECUTE FUNCTION forbid_change();

-- 2. Complaint rules: own transfer, amount within transfer, starts as SUBMITTED --
CREATE FUNCTION check_complaint() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_owner bigint; v_amount numeric;
BEGIN
  SELECT a.user_id, t.amount INTO v_owner, v_amount
  FROM transactions t JOIN accounts a ON a.account_id = t.source_account_id
  WHERE t.txn_id = NEW.disputed_txn_id;

  IF v_owner IS DISTINCT FROM NEW.customer_id THEN
    RAISE EXCEPTION USING ERRCODE = 'TP005', MESSAGE = 'complainant does not own the paying account';
  END IF;
  IF NEW.reported_amount > v_amount THEN
    RAISE EXCEPTION USING ERRCODE = 'TP005', MESSAGE = 'reported amount exceeds the transfer amount',
      DETAIL = 'reported=' || NEW.reported_amount || ' transfer=' || v_amount;
  END IF;
  IF TG_OP = 'INSERT' AND NEW.status <> 'SUBMITTED' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP005', MESSAGE = 'a new case must start as SUBMITTED';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER fraud_cases_check_complaint
  BEFORE INSERT OR UPDATE OF customer_id, disputed_txn_id, reported_amount ON fraud_cases
  FOR EACH ROW EXECUTE FUNCTION check_complaint();

-- 3. Public sign-up can only create customers --------------------------------
-- Staff are created only by the seed, which sets app.allow_staff_insert = 'on'.
CREATE FUNCTION force_customer_role() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF coalesce(current_setting('app.allow_staff_insert', true), '') <> 'on' THEN
    NEW.role := 'CUSTOMER';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER users_force_customer BEFORE INSERT ON users
  FOR EACH ROW EXECUTE FUNCTION force_customer_role();

-- 4. Assignees must be investigators -----------------------------------------
CREATE FUNCTION check_assignee() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT role FROM users WHERE user_id = NEW.investigator_id) IS DISTINCT FROM 'INVESTIGATOR' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'assignee is not an investigator';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER case_assignments_check BEFORE INSERT ON case_assignments
  FOR EACH ROW EXECUTE FUNCTION check_assignee();

-- 5. Case state machine: allowed moves are data, the trigger enforces them -----
INSERT INTO case_status_transitions (from_status, to_status, allowed_role) VALUES
  ('SUBMITTED',     'UNDER_REVIEW',  'SUPERVISOR'),
  ('UNDER_REVIEW',  'INVESTIGATING', 'INVESTIGATOR'),
  ('INVESTIGATING', 'RECOVERY',      'SUPERVISOR'),
  ('RECOVERY',      'CLOSED',        'SUPERVISOR'),
  ('INVESTIGATING', 'CLOSED',        'SUPERVISOR'),   -- nothing recoverable
  ('SUBMITTED',     'REJECTED',      'SUPERVISOR'),
  ('UNDER_REVIEW',  'REJECTED',      'SUPERVISOR'),
  ('INVESTIGATING', 'REJECTED',      'SUPERVISOR');

CREATE FUNCTION enforce_case_transition() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_role text   := current_setting('app.user_role', true);
  v_user bigint := NULLIF(current_setting('app.user_id', true), '')::bigint;
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT EXISTS (SELECT 1 FROM case_status_transitions
                   WHERE from_status = OLD.status AND to_status = NEW.status
                     AND allowed_role::text = v_role) THEN
      RAISE EXCEPTION USING ERRCODE = 'TP003',
        MESSAGE = format('transition %s -> %s not allowed for role %s',
                         OLD.status, NEW.status, coalesce(v_role, 'unknown'));
    END IF;
    IF NEW.status = 'RECOVERY' AND NEW.verified_loss IS NULL THEN
      RAISE EXCEPTION USING ERRCODE = 'TP003', MESSAGE = 'verify the loss before RECOVERY';
    END IF;
    INSERT INTO case_status_history (case_id, from_status, to_status, changed_by)
    VALUES (NEW.case_id, OLD.status, NEW.status, v_user);
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER fraud_cases_transition BEFORE UPDATE OF status ON fraud_cases
  FOR EACH ROW EXECUTE FUNCTION enforce_case_transition();

-- 6. Row-level audit log. TG_ARGV[0] = primary-key column. Actor from app.user_id.
CREATE FUNCTION audit_row() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_old jsonb := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) - 'search_vector' END;
  v_new jsonb := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) - 'search_vector' END;
BEGIN
  INSERT INTO audit_log (actor_id, entity_type, entity_id, action, old_row, new_row)
  VALUES (NULLIF(current_setting('app.user_id', true), '')::bigint,
          TG_TABLE_NAME, (coalesce(v_new, v_old) ->> TG_ARGV[0])::bigint, TG_OP, v_old, v_new);
  RETURN NULL;
END $$;

CREATE TRIGGER audit_fraud_cases AFTER INSERT OR UPDATE ON fraud_cases
  FOR EACH ROW EXECUTE FUNCTION audit_row('case_id');
CREATE TRIGGER audit_trace_nodes AFTER INSERT OR UPDATE ON trace_nodes
  FOR EACH ROW EXECUTE FUNCTION audit_row('node_id');
CREATE TRIGGER audit_links AFTER INSERT ON fund_flow_links
  FOR EACH ROW EXECUTE FUNCTION audit_row('link_id');
CREATE TRIGGER audit_freezes AFTER INSERT OR UPDATE ON account_freezes
  FOR EACH ROW EXECUTE FUNCTION audit_row('freeze_id');
CREATE TRIGGER audit_allocations AFTER INSERT OR UPDATE ON recovery_allocations
  FOR EACH ROW EXECUTE FUNCTION audit_row('allocation_id');
CREATE TRIGGER audit_refunds AFTER INSERT OR UPDATE ON refunds
  FOR EACH ROW EXECUTE FUNCTION audit_row('refund_id');
CREATE TRIGGER audit_accounts AFTER UPDATE OF balance ON accounts
  FOR EACH ROW EXECUTE FUNCTION audit_row('account_id');
