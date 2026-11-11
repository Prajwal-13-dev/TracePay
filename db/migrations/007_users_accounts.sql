-- 007_users_accounts.sql : user management, accounts, and transfers that move money.

-- 1. Users: the procedures the API calls (the rules are in the users triggers, 002) ---------------------
CREATE FUNCTION create_user(p_email citext, p_full_name text, p_phone text, p_password_hash text,
                            p_role user_role DEFAULT 'CUSTOMER')
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id bigint;
BEGIN
  IF p_role <> 'CUSTOMER' AND NOT staff_bootstrap() AND actor_role() IS DISTINCT FROM 'SUPERVISOR' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'only a supervisor can create staff users';
  END IF;
  INSERT INTO users (email, full_name, phone, password_hash, role)
  VALUES (p_email, btrim(p_full_name), NULLIF(p_phone, ''), p_password_hash, p_role)
  RETURNING user_id INTO v_id;
  RETURN v_id;
END $$;

CREATE PROCEDURE set_user_role(p_user_id bigint, p_role user_role)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE users SET role = p_role WHERE user_id = p_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'user not found'; END IF;
END $$;

CREATE PROCEDURE set_user_active(p_user_id bigint, p_active boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE users SET is_active = p_active WHERE user_id = p_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'user not found'; END IF;
END $$;

CREATE PROCEDURE set_user_password(p_user_id bigint, p_password_hash text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE users SET password_hash = p_password_hash WHERE user_id = p_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'user not found'; END IF;
END $$;

-- 2. Accounts ------------------------------------------------------------------------------------------
-- Next free TP########## reference (serialised by an advisory lock, so two sign-ups never collide).
CREATE FUNCTION next_account_ref() RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_next bigint;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('next_account_ref'));
  SELECT COALESCE(MAX(substr(account_ref, 3)::bigint), 6000000000) + 1 INTO v_next
  FROM accounts WHERE account_ref >= 'TP6000000000';
  RETURN 'TP' || lpad(v_next::text, 10, '0');
END $$;

-- Supervisors open accounts for anyone; otherwise only a user's FIRST account (sign-up) can be opened.
CREATE FUNCTION open_account(p_user_id bigint, p_opening_balance numeric DEFAULT 0)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id bigint;
BEGIN
  IF p_opening_balance IS NULL OR p_opening_balance < 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'opening balance must be 0 or more';
  END IF;
  IF actor_role() IS DISTINCT FROM 'SUPERVISOR' AND NOT staff_bootstrap()
     AND EXISTS (SELECT 1 FROM accounts WHERE user_id = p_user_id) THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'only a supervisor can open a second account';
  END IF;
  INSERT INTO accounts (user_id, account_ref, balance)
  VALUES (p_user_id, next_account_ref(), p_opening_balance)
  RETURNING account_id INTO v_id;
  RETURN v_id;
END $$;

-- 3. Every transfer moves money -------------------------------------------------------------------------
-- Locks both accounts in account_id order (no deadlock between opposite transfers), refuses closed accounts
-- and spending frozen money, then debits and credits. CHECK balance >= 0 and rule freeze_within_balance
-- back this up. A trigger, so seeds, tests and the app cannot bypass it.
CREATE FUNCTION apply_transfer() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_src accounts; v_dst accounts; v_frozen numeric;
BEGIN
  -- Leave malformed rows to the table's own CHECKs (amount > 0, source <> destination).
  IF NEW.amount IS NULL OR NEW.amount <= 0 OR NEW.source_account_id = NEW.destination_account_id THEN
    RETURN NEW;
  END IF;
  PERFORM 1 FROM accounts WHERE account_id IN (NEW.source_account_id, NEW.destination_account_id)
  ORDER BY account_id FOR UPDATE;
  SELECT * INTO v_src FROM accounts WHERE account_id = NEW.source_account_id;
  SELECT * INTO v_dst FROM accounts WHERE account_id = NEW.destination_account_id;
  IF v_src.status <> 'ACTIVE' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'account ' || v_src.account_ref || ' is closed';
  END IF;
  IF v_dst.status <> 'ACTIVE' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'account ' || v_dst.account_ref || ' is closed';
  END IF;
  SELECT COALESCE(SUM(frozen_amount), 0) INTO v_frozen
  FROM account_freezes WHERE account_id = v_src.account_id AND status = 'ACTIVE';
  IF v_src.balance - v_frozen < NEW.amount THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'insufficient available balance',
      DETAIL = 'balance=' || v_src.balance || ' frozen=' || v_frozen
               || ' available=' || (v_src.balance - v_frozen) || ' requested=' || NEW.amount;
  END IF;
  UPDATE accounts SET balance = balance - NEW.amount WHERE account_id = v_src.account_id;
  UPDATE accounts SET balance = balance + NEW.amount WHERE account_id = v_dst.account_id;
  RETURN NEW;
END $$;

CREATE TRIGGER transactions_apply BEFORE INSERT ON transactions
  FOR EACH ROW EXECUTE FUNCTION apply_transfer();

-- 4. Sending money: the one procedure the app calls ------------------------------------------------------
-- Customers send from their own accounts, now. Supervisors may move money between any two accounts and
-- backdate it (to build demo laundering chains). RECOVERY is reserved for the recovery procedures.
CREATE SEQUENCE transfer_ref_seq;

CREATE FUNCTION record_transfer(p_source_ref text, p_dest_ref text, p_amount numeric, p_channel text,
                                p_occurred_at timestamptz DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_src accounts; v_dst accounts; v_role user_role := actor_role(); v_at timestamptz; v_id bigint;
BEGIN
  IF v_role IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'sign in to send money';
  END IF;
  IF p_channel IS NULL OR p_channel NOT IN ('UPI', 'IMPS', 'NEFT', 'CARD') THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'channel must be UPI, IMPS, NEFT or CARD';
  END IF;
  SELECT * INTO v_src FROM accounts WHERE account_ref = upper(btrim(p_source_ref));
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'source account not found'; END IF;
  SELECT * INTO v_dst FROM accounts WHERE account_ref = upper(btrim(p_dest_ref));
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'recipient account not found'; END IF;
  IF v_src.account_id = v_dst.account_id THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'you cannot send money to the same account';
  END IF;
  IF v_role <> 'SUPERVISOR' AND v_src.user_id IS DISTINCT FROM actor_id() THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'you can only send money from your own account';
  END IF;
  v_at := COALESCE(p_occurred_at, clock_timestamp());
  IF v_at > clock_timestamp() + interval '1 minute' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'a transfer cannot be dated in the future';
  END IF;
  IF v_role <> 'SUPERVISOR' AND v_at < clock_timestamp() - interval '5 minutes' THEN
    RAISE EXCEPTION USING ERRCODE = 'TP002', MESSAGE = 'only a supervisor can record a past transfer';
  END IF;
  INSERT INTO transactions (external_ref, source_account_id, destination_account_id, amount, channel, occurred_at)
  VALUES ('TX' || to_char(clock_timestamp() AT TIME ZONE 'Asia/Kolkata', 'YYMMDD') || '-' || lpad(nextval('transfer_ref_seq')::text, 5, '0'),
          v_src.account_id, v_dst.account_id, p_amount, p_channel, v_at)
  RETURNING txn_id INTO v_id;
  RETURN v_id;
END $$;

-- 5. Seeds: insert historical transfers so that each account ends at its intended balance --------------
-- A seed fills TEMP TABLE seed_transfer_rows (ord, external_ref, source_account_id, destination_account_id,
-- amount, channel, occurred_at) and calls this. Each account's balance is first set to its OPENING balance
-- (intended balance minus what the transfers bring in, never so low that a transfer would overdraw it),
-- then the transfers are inserted in order and the trigger moves the money.
CREATE PROCEDURE seed_insert_transfers()
LANGUAGE plpgsql AS $$
BEGIN
  WITH legs AS (
    SELECT source_account_id AS acct, ord, -amount AS delta FROM seed_transfer_rows
    UNION ALL
    SELECT destination_account_id, ord, amount FROM seed_transfer_rows
  ), running AS (
    SELECT acct, SUM(delta) OVER (PARTITION BY acct ORDER BY ord, delta) AS run FROM legs
  ), per AS (
    SELECT acct, (SELECT SUM(delta) FROM legs l WHERE l.acct = r.acct) AS net, MIN(run) AS low
    FROM running r GROUP BY acct
  )
  UPDATE accounts a SET balance = GREATEST(a.balance - per.net, -per.low, 0)
  FROM per WHERE a.account_id = per.acct;

  INSERT INTO transactions (external_ref, source_account_id, destination_account_id, amount, channel, occurred_at)
  SELECT external_ref, source_account_id, destination_account_id, amount, channel, occurred_at
  FROM seed_transfer_rows ORDER BY ord;
  DROP TABLE seed_transfer_rows;
END $$;
