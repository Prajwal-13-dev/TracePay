-- 003_engine.sql : conservation-constraint engine (handbook Section 14)
-- A restricted, concurrency-safe CREATE ASSERTION for the rule shape:
--   for each parent p:  SUM(child.qty WHERE child.status IN S)  <=  (or =)  COALESCE(p.qty, 0)
-- register_invariant() validates the rule against the catalog and GENERATES:
--   inv_<rule>_check(key)  recompute SUM for one parent, raise TP001 with the exact excess
--   inv_<rule>_lock()      BEFORE ROW on child: lock parent row(s) FOR UPDATE (prevents the race)
--   inv_<rule>_child()     AFTER ROW on child: check new and old parent
--   inv_<rule>_parent()    AFTER UPDATE of the parent limit: limit may not drop below usage
-- '=' rules use DEFERRABLE INITIALLY DEFERRED constraint triggers (checked at COMMIT).

CREATE TABLE invariant_definitions (
  invariant_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name            text NOT NULL UNIQUE CHECK (name ~ '^[a-z][a-z0-9_]{2,40}$'),
  parent_table    regclass NOT NULL,
  parent_key      name NOT NULL,
  parent_quantity name NOT NULL,
  child_table     regclass NOT NULL,
  child_fk        name NOT NULL,
  child_quantity  name NOT NULL,
  relation        text NOT NULL CHECK (relation IN ('<=', '=')),
  status_column   name,
  included_status text[],
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK ((status_column IS NULL) = (included_status IS NULL))
);

CREATE FUNCTION attnum_of(p_table regclass, p_col name) RETURNS smallint
LANGUAGE sql STABLE AS $$
  SELECT attnum FROM pg_attribute
  WHERE attrelid = p_table AND attname = p_col AND NOT attisdropped AND attnum > 0
$$;

CREATE FUNCTION assert_numeric_column(p_table regclass, p_col name) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_attribute a
                 WHERE a.attrelid = p_table AND a.attname = p_col AND NOT a.attisdropped
                   AND a.atttypid IN ('numeric'::regtype, 'integer'::regtype, 'bigint'::regtype)) THEN
    RAISE EXCEPTION 'column %.% is missing or not numeric', p_table, p_col;
  END IF;
END $$;

CREATE FUNCTION register_invariant(
  p_name text, p_parent_table regclass, p_parent_key name, p_parent_quantity name,
  p_child_table regclass, p_child_fk name, p_child_quantity name,
  p_relation text DEFAULT '<=', p_status_column name DEFAULT NULL, p_included_status text[] DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  v_id     bigint;
  v_filter text := '';
  v_op     text := CASE p_relation WHEN '<=' THEN '>' ELSE '<>' END;
  f_check  text := 'inv_' || p_name || '_check';
  f_lock   text := 'inv_' || p_name || '_lock';
  f_child  text := 'inv_' || p_name || '_child';
  f_parent text := 'inv_' || p_name || '_parent';
  v_defer  text := CASE p_relation WHEN '=' THEN 'CONSTRAINT ' ELSE '' END;
  v_when   text := CASE p_relation WHEN '=' THEN ' DEFERRABLE INITIALLY DEFERRED' ELSE '' END;
BEGIN
  -- 1. Validate against the system catalog. Any error rolls back everything: no partial artefacts.
  IF p_relation IS NULL OR p_relation NOT IN ('<=', '=') THEN
    RAISE EXCEPTION 'unsupported relation %', p_relation;
  END IF;
  PERFORM assert_numeric_column(p_parent_table, p_parent_quantity);
  PERFORM assert_numeric_column(p_child_table, p_child_quantity);
  IF NOT EXISTS (SELECT 1 FROM pg_index i
                 WHERE i.indrelid = p_parent_table AND i.indisunique AND i.indnatts = 1
                   AND i.indkey[0] = attnum_of(p_parent_table, p_parent_key)) THEN
    RAISE EXCEPTION '% is not a single-column unique key of %', p_parent_key, p_parent_table;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint c, unnest(c.conkey, c.confkey) AS k(ck, pk)
                 WHERE c.contype = 'f' AND c.conrelid = p_child_table AND c.confrelid = p_parent_table
                   AND k.ck = attnum_of(p_child_table, p_child_fk)
                   AND k.pk = attnum_of(p_parent_table, p_parent_key)) THEN
    RAISE EXCEPTION 'no foreign key %.% -> %.%', p_child_table, p_child_fk, p_parent_table, p_parent_key;
  END IF;
  IF p_status_column IS NOT NULL THEN
    IF attnum_of(p_child_table, p_status_column) IS NULL THEN
      RAISE EXCEPTION 'status column % not found on %', p_status_column, p_child_table;
    END IF;
    v_filter := format(' AND %I = ANY (%L::text[])', p_status_column, p_included_status);
  END IF;

  INSERT INTO invariant_definitions (name, parent_table, parent_key, parent_quantity, child_table,
                                     child_fk, child_quantity, relation, status_column, included_status)
  VALUES (p_name, p_parent_table, p_parent_key, p_parent_quantity, p_child_table,
          p_child_fk, p_child_quantity, p_relation, p_status_column, p_included_status)
  RETURNING invariant_id INTO v_id;

  -- 2. Check function: recompute the SUM for one parent; raise TP001 with limit, total, excess.
  EXECUTE format($f$
    CREATE FUNCTION %1$I(p_key bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $b$
    DECLARE v_limit numeric; v_total numeric;
    BEGIN
      SELECT COALESCE(%2$I, 0) INTO v_limit FROM %3$s WHERE %4$I = p_key;
      IF NOT FOUND THEN RETURN; END IF;
      SELECT COALESCE(SUM(%5$I), 0) INTO v_total FROM %6$s WHERE %7$I = p_key%8$s;
      IF v_total %9$s v_limit THEN
        RAISE EXCEPTION USING ERRCODE = 'TP001',
          MESSAGE = 'invariant ' || %10$L || ' violated',
          DETAIL  = 'parent_key=' || p_key || ' limit=' || v_limit
                    || ' total=' || v_total || ' excess=' || (v_total - v_limit);
      END IF;
    END $b$;$f$,
    f_check, p_parent_quantity, p_parent_table, p_parent_key,
    p_child_quantity, p_child_table, p_child_fk, v_filter, v_op, p_name);

  -- 3. Lock function: BEFORE ROW on the child. Locks the parent first, so a concurrent writer waits.
  --    On a move to another parent, both parents are locked in key order in one statement.
  EXECUTE format($f$
    CREATE FUNCTION %1$I() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $b$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        PERFORM 1 FROM %2$s WHERE %3$I = NEW.%4$I FOR UPDATE;
        RETURN NEW;
      ELSIF TG_OP = 'UPDATE' THEN
        PERFORM 1 FROM %2$s WHERE %3$I IN (OLD.%4$I, NEW.%4$I) ORDER BY %3$I FOR UPDATE;
        RETURN NEW;
      ELSE
        PERFORM 1 FROM %2$s WHERE %3$I = OLD.%4$I FOR UPDATE;
        RETURN OLD;
      END IF;
    END $b$;$f$, f_lock, p_parent_table, p_parent_key, p_child_fk);

  -- 4. Child check: AFTER ROW, checks the new parent and (on update/delete) the old one.
  EXECUTE format($f$
    CREATE FUNCTION %1$I() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $b$
    BEGIN
      IF TG_OP IN ('INSERT', 'UPDATE') THEN PERFORM %2$I(NEW.%3$I); END IF;
      IF TG_OP IN ('UPDATE', 'DELETE') THEN PERFORM %2$I(OLD.%3$I); END IF;
      RETURN NULL;
    END $b$;$f$, f_child, f_check, p_child_fk);

  -- 5. Parent check: a limit may not be lowered below what the children already use.
  EXECUTE format($f$
    CREATE FUNCTION %1$I() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $b$
    BEGIN PERFORM %2$I(NEW.%3$I); RETURN NULL; END $b$;$f$,
    f_parent, f_check, p_parent_key);

  -- 6. Triggers. Names sort a_lock < b_check < c_parent, so firing order is explicit.
  EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION %I()',
                 'inv_' || p_name || '_a_lock', p_child_table, f_lock);
  EXECUTE format('CREATE %sTRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %s%s FOR EACH ROW EXECUTE FUNCTION %I()',
                 v_defer, 'inv_' || p_name || '_b_check', p_child_table, v_when, f_child);
  EXECUTE format('CREATE %sTRIGGER %I AFTER UPDATE OF %I ON %s%s FOR EACH ROW EXECUTE FUNCTION %I()',
                 v_defer, 'inv_' || p_name || '_c_parent', p_parent_quantity, p_parent_table, v_when, f_parent);
  RETURN v_id;
END $$;

-- Diagnostics: every parent that currently violates the rule (useful after bulk loads or disabled triggers).
CREATE FUNCTION verify_invariant(p_name text)
RETURNS TABLE (parent_key bigint, limit_qty numeric, child_total numeric, excess numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE d invariant_definitions; v_filter text := '';
BEGIN
  SELECT * INTO STRICT d FROM invariant_definitions WHERE name = p_name;
  IF d.status_column IS NOT NULL THEN
    v_filter := format(' AND c.%I = ANY (%L::text[])', d.status_column, d.included_status);
  END IF;
  RETURN QUERY EXECUTE format($q$
    SELECT p.%1$I::bigint, COALESCE(p.%2$I, 0)::numeric, COALESCE(s.total, 0)::numeric,
           (COALESCE(s.total, 0) - COALESCE(p.%2$I, 0))::numeric
    FROM %3$s p
    LEFT JOIN (SELECT c.%4$I AS k, SUM(c.%5$I) AS total
               FROM %6$s c WHERE true%7$s GROUP BY c.%4$I) s ON s.k = p.%1$I
    WHERE COALESCE(s.total, 0) %8$s COALESCE(p.%2$I, 0)$q$,
    d.parent_key, d.parent_quantity, d.parent_table, d.child_fk, d.child_quantity,
    d.child_table, v_filter, CASE d.relation WHEN '<=' THEN '>' ELSE '<>' END);
END $$;

-- Diagnostics: the rule definition plus the generated triggers and function source.
CREATE FUNCTION explain_invariant(p_name text) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'definition', to_jsonb(d),
    'triggers', (SELECT jsonb_agg(jsonb_build_object('table', t.tgrelid::regclass::text, 'trigger', t.tgname)
                                  ORDER BY t.tgname)
                 FROM pg_trigger t
                 WHERE t.tgname IN ('inv_' || p_name || '_a_lock', 'inv_' || p_name || '_b_check',
                                    'inv_' || p_name || '_c_parent')),
    'functions', (SELECT jsonb_agg(pg_get_functiondef(p.oid) ORDER BY p.proname)
                  FROM pg_proc p
                  WHERE p.proname IN ('inv_' || p_name || '_check', 'inv_' || p_name || '_lock',
                                      'inv_' || p_name || '_child', 'inv_' || p_name || '_parent')))
  FROM invariant_definitions d WHERE d.name = p_name;
$$;

-- Remove a rule cleanly (3 triggers, 4 functions, 1 definition row) so it can be regenerated.
CREATE FUNCTION drop_invariant(p_name text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE d invariant_definitions;
BEGIN
  SELECT * INTO STRICT d FROM invariant_definitions WHERE name = p_name;
  EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', 'inv_' || p_name || '_a_lock', d.child_table);
  EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', 'inv_' || p_name || '_b_check', d.child_table);
  EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', 'inv_' || p_name || '_c_parent', d.parent_table);
  EXECUTE format('DROP FUNCTION IF EXISTS %I()', 'inv_' || p_name || '_lock');
  EXECUTE format('DROP FUNCTION IF EXISTS %I()', 'inv_' || p_name || '_child');
  EXECUTE format('DROP FUNCTION IF EXISTS %I()', 'inv_' || p_name || '_parent');
  EXECUTE format('DROP FUNCTION IF EXISTS %I(bigint)', 'inv_' || p_name || '_check');
  DELETE FROM invariant_definitions WHERE name = p_name;
END $$;

-- The six TracePay money rules (handbook 14.5). Lock order freeze -> case follows name order.
SELECT register_invariant('txn_capacity', 'transactions', 'txn_id', 'amount',
                          'trace_nodes', 'txn_id', 'inflow_amount');
SELECT register_invariant('node_outflow', 'trace_nodes', 'node_id', 'inflow_amount',
                          'fund_flow_links', 'from_node_id', 'attributed_amount');
SELECT register_invariant('freeze_within_balance', 'accounts', 'account_id', 'balance',
                          'account_freezes', 'account_id', 'frozen_amount', '<=', 'status', ARRAY['ACTIVE']);
SELECT register_invariant('allocation_within_freeze', 'account_freezes', 'freeze_id', 'frozen_amount',
                          'recovery_allocations', 'freeze_id', 'amount', '<=', 'status', ARRAY['ACTIVE','PAID']);
SELECT register_invariant('allocation_within_loss', 'fraud_cases', 'case_id', 'verified_loss',
                          'recovery_allocations', 'case_id', 'amount', '<=', 'status', ARRAY['ACTIVE','PAID']);
SELECT register_invariant('refund_within_allocation', 'recovery_allocations', 'allocation_id', 'amount',
                          'refunds', 'allocation_id', 'amount', '<=', 'status', ARRAY['PROCESSED']);
