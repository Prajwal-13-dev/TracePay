-- 010: a freeze blocks the whole account for outgoing money.
-- Before: only the frozen AMOUNT was protected (available = balance - frozen), so the rest could still leave.
-- Now: while an account has an ACTIVE, unexpired freeze, NO money may leave it, whatever the amount: the bank


CREATE FUNCTION block_frozen_outgoing() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_freeze bigint; v_ref text;
BEGIN
  IF NEW.channel = 'RECOVERY' THEN
    RETURN NEW;                                   -- recovery payouts to victims
  END IF;
  SELECT f.freeze_id INTO v_freeze
  FROM account_freezes f
  WHERE f.account_id = NEW.source_account_id AND f.status = 'ACTIVE' AND f.expires_at > now()
  ORDER BY f.freeze_id LIMIT 1;
  IF FOUND THEN
    SELECT account_ref INTO v_ref FROM accounts WHERE account_id = NEW.source_account_id;
    RAISE EXCEPTION USING ERRCODE = 'TP006',
      MESSAGE = format('account %s is frozen (freeze #%s): no money can leave it until the freeze is settled, released or expires',
                       v_ref, v_freeze),
      DETAIL  = format('account_id=%s freeze_id=%s', NEW.source_account_id, v_freeze);
  END IF;
  RETURN NEW;
END $$;

-- Triggers of the same timing fire in name order: "transactions_a_..." runs before "transactions_apply",
-- so a frozen account is refused before any balance is touched.
CREATE TRIGGER transactions_a_block_frozen BEFORE INSERT ON transactions
  FOR EACH ROW EXECUTE FUNCTION block_frozen_outgoing();

-- Is this account blocked right now? (used by the UI badges)
CREATE FUNCTION account_is_frozen(p_account_id bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM account_freezes
                 WHERE account_id = p_account_id AND status = 'ACTIVE' AND expires_at > now());
$$;
