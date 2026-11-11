-- 002_integrity.sql : who is acting, row rules that need other rows, the case state machine, audit log.
-- Error codes: TP002 business rule, TP003 illegal transition, TP004 append-only, TP005 complaint rule
-- (TP001 = engine invariant, 003).

-- 1. The acting user ------------------------------------------------------------------------------
-- The API puts the signed-in user's id in app.user_id for each transaction. actor_role() reads that
-- user's CURRENT role from users (only if active): a role change or deactivation takes effect at once,
-- and the role cannot be faked by setting a GUC. Seeds bootstrap staff with app.allow_staff_insert = 'on'.
CREATE FUNCTION actor_id() RETURNS bigint
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.user_id', true), '')::bigint
$$;

CREATE FUNCTION actor_role() RETURNS user_role
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT role FROM users WHERE user_id = actor_id() AND is_active
$$;

CREATE FUNCTION staff_bootstrap() RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT coalesce(current_setting('app.allow_staff_insert', true), '') = 'on'
$$;

CREATE FUNCTION require_role(VARIADIC p_roles user_role[]) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_role user_role := actor_role();
BEGIN
  IF v_role IS NULL OR NOT (v_role = ANY (p_roles)) THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002',
      MESSAGE = 'only ' || (SELECT string_agg(lower(r::text) || 's', ' or ') FROM unnest(p_roles) r) || ' can do this'
                || CASE WHEN v_role IS NULL THEN ' (nobody signed in)' ELSE ' (you are ' || lower(v_role::text) || ')' END;
  END IF;
END $$;

CREATE FUNCTION require_assigned(p_case_id bigint) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM require_role('INVESTIGATOR');
  IF NOT EXISTS (SELECT 1 FROM case_assignments
                 WHERE case_id = p_case_id AND investigator_id = actor_id() AND ended_at IS NULL) THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'this case is not assigned to you';
  END IF;
END $$;

-- 2. Append-only / immutable tables ----------------------------------------------------------------
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

-- 3. Complaints and drafts: own transfer, amount within the transfer, starts as SUBMITTED -------------
CREATE FUNCTION check_complaint() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_owner bigint; v_amount numeric; v_channel text;
BEGIN
  SELECT a.user_id, t.amount, t.channel INTO v_owner, v_amount, v_channel
  FROM transactions t JOIN accounts a ON a.account_id = t.source_account_id
  WHERE t.txn_id = NEW.disputed_txn_id;

  IF v_owner IS DISTINCT FROM NEW.customer_id THEN
    RAISE EXCEPTION USING ERRCODE = 'TP005', MESSAGE = 'complainant does not own the paying account';
  END IF;
  IF v_channel = 'RECOVERY' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP005', MESSAGE = 'a recovery payment cannot be disputed';
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

CREATE FUNCTION check_draft() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.disputed_txn_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM transactions t JOIN accounts a ON a.account_id = t.source_account_id
       WHERE t.txn_id = NEW.disputed_txn_id AND a.user_id = NEW.customer_id AND t.channel <> 'RECOVERY') THEN
    RAISE EXCEPTION USING ERRCODE = 'TP005', MESSAGE = 'a draft can only refer to a transfer you made';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER draft_complaints_check BEFORE INSERT OR UPDATE OF customer_id, disputed_txn_id ON draft_complaints
  FOR EACH ROW EXECUTE FUNCTION check_draft();

-- 4. Users: staff roles only from a supervisor; role/active/password changes guarded ------------------
CREATE FUNCTION force_customer_role() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.role <> 'CUSTOMER' AND NOT staff_bootstrap() AND actor_role() IS DISTINCT FROM 'SUPERVISOR' THEN
    NEW.role := 'CUSTOMER';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER users_force_customer BEFORE INSERT ON users
  FOR EACH ROW EXECUTE FUNCTION force_customer_role();

-- Supervisor only; nobody changes their own role or deactivates themselves; the last active supervisor stays.
CREATE FUNCTION guard_user_update() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_actor bigint := actor_id();
BEGIN
  IF staff_bootstrap() THEN RETURN NEW; END IF;
  IF (NEW.role IS DISTINCT FROM OLD.role OR NEW.is_active IS DISTINCT FROM OLD.is_active)
     AND actor_role() IS DISTINCT FROM 'SUPERVISOR' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'only a supervisor can change roles or deactivate users';
  END IF;
  IF NEW.password_hash IS DISTINCT FROM OLD.password_hash
     AND v_actor IS DISTINCT FROM OLD.user_id AND actor_role() IS DISTINCT FROM 'SUPERVISOR' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'only the user or a supervisor can change a password';
  END IF;
  IF v_actor = OLD.user_id AND (NEW.role IS DISTINCT FROM OLD.role OR NOT NEW.is_active) THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'you cannot change your own role or deactivate yourself';
  END IF;
  IF OLD.role = 'SUPERVISOR' AND OLD.is_active AND (NEW.role <> 'SUPERVISOR' OR NOT NEW.is_active)
     AND NOT EXISTS (SELECT 1 FROM users WHERE role = 'SUPERVISOR' AND is_active AND user_id <> OLD.user_id) THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'the last active supervisor cannot be demoted or deactivated';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER users_guard_update BEFORE UPDATE OF role, is_active, password_hash ON users
  FOR EACH ROW EXECUTE FUNCTION guard_user_update();

-- An investigator who is demoted or deactivated drops their open cases (they show as unassigned).
CREATE FUNCTION end_assignments_of_inactive() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF OLD.role = 'INVESTIGATOR' AND (NEW.role <> 'INVESTIGATOR' OR NOT NEW.is_active) THEN
    UPDATE case_assignments SET ended_at = clock_timestamp()
    WHERE investigator_id = NEW.user_id AND ended_at IS NULL;
  END IF;
  RETURN NULL;
END $$;

CREATE TRIGGER users_end_assignments AFTER UPDATE OF role, is_active ON users
  FOR EACH ROW EXECUTE FUNCTION end_assignments_of_inactive();

-- 5. Assignees must be active investigators; links stay inside one case -------------------------------
CREATE FUNCTION check_assignee() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM users WHERE user_id = NEW.investigator_id AND role = 'INVESTIGATOR' AND is_active) THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'assignee is not an active investigator';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER case_assignments_check BEFORE INSERT ON case_assignments
  FOR EACH ROW EXECUTE FUNCTION check_assignee();

CREATE FUNCTION check_link_case() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT count(*) FROM trace_nodes
      WHERE node_id IN (NEW.from_node_id, NEW.to_node_id) AND case_id = NEW.case_id) <> 2 THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'both ends of a link must be nodes of the same case';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER fund_flow_links_same_case BEFORE INSERT OR UPDATE OF case_id, from_node_id, to_node_id ON fund_flow_links
  FOR EACH ROW EXECUTE FUNCTION check_link_case();

-- 6. Case state machine: allowed moves are data, the trigger enforces them ---------------------------
INSERT INTO case_status_transitions (from_status, to_status, allowed_role) VALUES
  ('SUBMITTED',     'UNDER_REVIEW',  'SUPERVISOR'),
  ('UNDER_REVIEW',  'INVESTIGATING', 'INVESTIGATOR'),
  ('INVESTIGATING', 'UNDER_REVIEW',  'INVESTIGATOR'),   -- hand-back (procedure hand_back_case)
  ('INVESTIGATING', 'RECOVERY',      'SUPERVISOR'),
  ('RECOVERY',      'CLOSED',        'SUPERVISOR'),
  ('INVESTIGATING', 'CLOSED',        'SUPERVISOR'),     -- nothing recoverable
  ('SUBMITTED',     'REJECTED',      'SUPERVISOR'),
  ('UNDER_REVIEW',  'REJECTED',      'SUPERVISOR'),
  ('INVESTIGATING', 'REJECTED',      'SUPERVISOR');

-- Records each move in case_status_history, with the optional note (app.status_note) for the customer.
CREATE FUNCTION enforce_case_transition() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_role text   := actor_role()::text;
  v_user bigint := actor_id();
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
    INSERT INTO case_status_history (case_id, from_status, to_status, changed_by, note)
    VALUES (NEW.case_id, OLD.status, NEW.status, v_user, NULLIF(current_setting('app.status_note', true), ''));
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER fraud_cases_transition BEFORE UPDATE OF status ON fraud_cases
  FOR EACH ROW EXECUTE FUNCTION enforce_case_transition();

-- 7. Row-level audit log. TG_ARGV[0] = primary-key column. Actor from app.user_id. ------------------
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

-- Users are audited without the password hash.
CREATE FUNCTION audit_user() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_old jsonb := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) - 'password_hash' END;
  v_new jsonb := to_jsonb(NEW) - 'password_hash';
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.password_hash IS DISTINCT FROM OLD.password_hash THEN
    v_new := v_new || '{"password":"changed"}';
  END IF;
  INSERT INTO audit_log (actor_id, entity_type, entity_id, action, old_row, new_row)
  VALUES (actor_id(), 'users', NEW.user_id, TG_OP, v_old, v_new);
  RETURN NULL;
END $$;

CREATE TRIGGER audit_users AFTER INSERT OR UPDATE OF role, is_active, password_hash, full_name, phone ON users
  FOR EACH ROW EXECUTE FUNCTION audit_user();
CREATE TRIGGER audit_fraud_cases AFTER INSERT OR UPDATE ON fraud_cases
  FOR EACH ROW EXECUTE FUNCTION audit_row('case_id');
CREATE TRIGGER audit_assignments AFTER INSERT OR UPDATE ON case_assignments
  FOR EACH ROW EXECUTE FUNCTION audit_row('assignment_id');
CREATE TRIGGER audit_trace_nodes AFTER INSERT OR UPDATE OR DELETE ON trace_nodes
  FOR EACH ROW EXECUTE FUNCTION audit_row('node_id');
CREATE TRIGGER audit_links AFTER INSERT OR UPDATE ON fund_flow_links
  FOR EACH ROW EXECUTE FUNCTION audit_row('link_id');
CREATE TRIGGER audit_freezes AFTER INSERT OR UPDATE ON account_freezes
  FOR EACH ROW EXECUTE FUNCTION audit_row('freeze_id');
CREATE TRIGGER audit_allocations AFTER INSERT OR UPDATE ON recovery_allocations
  FOR EACH ROW EXECUTE FUNCTION audit_row('allocation_id');
CREATE TRIGGER audit_refunds AFTER INSERT OR UPDATE ON refunds
  FOR EACH ROW EXECUTE FUNCTION audit_row('refund_id');
CREATE TRIGGER audit_accounts AFTER UPDATE OF balance, status ON accounts
  FOR EACH ROW EXECUTE FUNCTION audit_row('account_id');
