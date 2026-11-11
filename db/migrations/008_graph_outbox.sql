-- 008_graph_outbox.sql : Neo4j sync through a transactional outbox.
-- PostgreSQL stays the system of record. Every change Neo4j needs (accounts, transfers, cases) is recorded here
-- IN THE SAME TRANSACTION as the change itself, so a rolled-back write never reaches the graph.
-- scripts/graph-sync.mjs drains this table and MERGEs into Neo4j (idempotent, so replaying a row is harmless).
-- Neo4j is read-only for money: it only suggests paths; amounts are committed by confirm_link().

CREATE TABLE graph_outbox (
  outbox_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity       text   NOT NULL,
  entity_id    bigint NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  attempts     int    NOT NULL DEFAULT 0,
  last_error   text,
  CONSTRAINT graph_outbox_entity_check   CHECK (entity IN ('account', 'transaction', 'case')),
  CONSTRAINT graph_outbox_attempts_check CHECK (attempts >= 0)
);
-- The worker only ever scans pending rows.
CREATE INDEX graph_outbox_pending ON graph_outbox (outbox_id) WHERE processed_at IS NULL;

-- One generic trigger function: TG_ARGV[0] = entity name, TG_ARGV[1] = key column.
CREATE FUNCTION enqueue_graph_sync() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO graph_outbox (entity, entity_id)
  VALUES (TG_ARGV[0], (to_jsonb(NEW) ->> TG_ARGV[1])::bigint);
  RETURN NULL;
END $$;

CREATE TRIGGER accounts_graph_sync AFTER INSERT OR UPDATE OF balance, status ON accounts
  FOR EACH ROW EXECUTE FUNCTION enqueue_graph_sync('account', 'account_id');
CREATE TRIGGER transactions_graph_sync AFTER INSERT ON transactions
  FOR EACH ROW EXECUTE FUNCTION enqueue_graph_sync('transaction', 'txn_id');
CREATE TRIGGER fraud_cases_graph_sync AFTER INSERT OR UPDATE OF status ON fraud_cases
  FOR EACH ROW EXECUTE FUNCTION enqueue_graph_sync('case', 'case_id');

-- Re-queue everything (used by `npm run graph:rebuild` after wiping Neo4j).
CREATE FUNCTION enqueue_full_graph_sync() RETURNS bigint
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  WITH a AS (INSERT INTO graph_outbox (entity, entity_id) SELECT 'account', account_id FROM accounts RETURNING 1),
       t AS (INSERT INTO graph_outbox (entity, entity_id) SELECT 'transaction', txn_id FROM transactions RETURNING 1),
       c AS (INSERT INTO graph_outbox (entity, entity_id) SELECT 'case', case_id FROM fraud_cases RETURNING 1)
  SELECT (SELECT count(*) FROM a) + (SELECT count(*) FROM t) + (SELECT count(*) FROM c);
$$;
