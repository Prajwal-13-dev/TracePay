-- 006_views_search.sql : views, the materialized dashboard view and its lazy refresh, indexes.

-- Views --------------------------------------------------------------------------
CREATE VIEW active_freezes AS
  SELECT f.* FROM account_freezes f
  WHERE f.status = 'ACTIVE' AND f.expires_at > now();

-- Distinct (case, account) pairs the confirmed traces reached
CREATE VIEW trace_accounts AS
  SELECT DISTINCT n.case_id, t.destination_account_id AS account_id
  FROM trace_nodes n JOIN transactions t ON t.txn_id = n.txn_id;

-- Per account: total disputed money attributed into it, and how many cases reached it
CREATE VIEW account_disputed_inflow AS
  SELECT t.destination_account_id AS account_id,
         COUNT(DISTINCT n.case_id) AS case_count,
         SUM(n.inflow_amount)      AS disputed_inflow
  FROM trace_nodes n JOIN transactions t ON t.txn_id = n.txn_id
  GROUP BY t.destination_account_id;

-- Each active freeze with allocated and remaining capacity (allocation desk)
CREATE VIEW freeze_capacity AS
  SELECT f.freeze_id, f.account_id, f.frozen_amount, f.expires_at,
         COALESCE(SUM(a.amount) FILTER (WHERE a.status IN ('ACTIVE', 'PAID')), 0) AS allocated,
         f.frozen_amount
           - COALESCE(SUM(a.amount) FILTER (WHERE a.status IN ('ACTIVE', 'PAID')), 0) AS remaining
  FROM active_freezes f
  LEFT JOIN recovery_allocations a ON a.freeze_id = f.freeze_id
  GROUP BY f.freeze_id, f.account_id, f.frozen_amount, f.expires_at;

-- Supervisor dashboard. Each total is aggregated in its own subquery BEFORE the join,
-- so an allocation with several refunds is not counted several times.
CREATE MATERIALIZED VIEW supervisor_case_summary AS
  SELECT c.case_id, c.status, c.priority, c.reported_amount, c.verified_loss, c.created_at,
         COALESCE(a.allocated, 0) AS allocated,
         COALESCE(r.refunded, 0)  AS refunded
  FROM fraud_cases c
  LEFT JOIN (SELECT case_id, SUM(amount) AS allocated
             FROM recovery_allocations WHERE status IN ('ACTIVE', 'PAID')
             GROUP BY case_id) a ON a.case_id = c.case_id
  LEFT JOIN (SELECT ra.case_id, SUM(rf.amount) AS refunded
             FROM refunds rf JOIN recovery_allocations ra ON ra.allocation_id = rf.allocation_id
             WHERE rf.status = 'PROCESSED'
             GROUP BY ra.case_id) r ON r.case_id = c.case_id;
CREATE UNIQUE INDEX supervisor_case_summary_pk ON supervisor_case_summary (case_id);  -- allows REFRESH ... CONCURRENTLY

-- The dashboard refreshes the materialized view only when its data changed: writes to the source tables
-- mark it stale (statement-level triggers, cheap) and refresh_case_summary() refreshes only if stale.
CREATE TABLE summary_state (
  view_name    text PRIMARY KEY,
  stale        boolean NOT NULL DEFAULT true,
  refreshed_at timestamptz
);
INSERT INTO summary_state (view_name) VALUES ('supervisor_case_summary');

CREATE FUNCTION mark_summary_stale() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE summary_state SET stale = true WHERE view_name = 'supervisor_case_summary' AND NOT stale;
  RETURN NULL;
END $$;
CREATE TRIGGER fraud_cases_summary_stale AFTER INSERT OR UPDATE OR DELETE ON fraud_cases
  FOR EACH STATEMENT EXECUTE FUNCTION mark_summary_stale();
CREATE TRIGGER allocations_summary_stale AFTER INSERT OR UPDATE OR DELETE ON recovery_allocations
  FOR EACH STATEMENT EXECUTE FUNCTION mark_summary_stale();
CREATE TRIGGER refunds_summary_stale AFTER INSERT OR UPDATE OR DELETE ON refunds
  FOR EACH STATEMENT EXECUTE FUNCTION mark_summary_stale();

-- Returns true if it refreshed. SECURITY DEFINER: only the owner may refresh a materialized view.
CREATE FUNCTION refresh_case_summary() RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE summary_state SET stale = false, refreshed_at = now()
  WHERE view_name = 'supervisor_case_summary' AND stale;
  IF NOT FOUND THEN RETURN false; END IF;
  REFRESH MATERIALIZED VIEW CONCURRENTLY supervisor_case_summary;
  RETURN true;
END $$;

-- Indexes: each one exists for a named query ------------------------------------------
CREATE INDEX idx_txn_source_time       ON transactions (source_account_id, occurred_at, txn_id);  -- each recursive trace step
CREATE INDEX idx_txn_dest_time         ON transactions (destination_account_id, occurred_at);     -- FIFO inflows, trace_accounts
CREATE INDEX idx_cases_status          ON fraud_cases (status, created_at DESC);                   -- case queue + filters
CREATE INDEX idx_cases_customer        ON fraud_cases (customer_id);                               -- customer's own cases
CREATE INDEX idx_nodes_txn             ON trace_nodes (txn_id);                                    -- txn_capacity SUM
CREATE INDEX idx_links_to              ON fund_flow_links (to_node_id);                            -- incoming-link checks
CREATE INDEX idx_alloc_freeze          ON recovery_allocations (freeze_id, status) INCLUDE (amount); -- allocation_within_freeze SUM
CREATE INDEX idx_alloc_case            ON recovery_allocations (case_id, status) INCLUDE (amount);   -- allocation_within_loss SUM
CREATE INDEX idx_refund_alloc          ON refunds (allocation_id, status) INCLUDE (amount);          -- refund_within_allocation SUM
CREATE INDEX idx_freeze_account_active ON account_freezes (account_id) WHERE status = 'ACTIVE';      -- freeze_within_balance
CREATE INDEX idx_cases_fts             ON fraud_cases USING gin (search_vector);                   -- full-text search
CREATE INDEX idx_case_embeddings       ON case_embeddings USING hnsw (embedding vector_cosine_ops); -- similar complaints
CREATE INDEX idx_audit_entity          ON audit_log (entity_type, entity_id, at DESC);              -- audit viewer
CREATE INDEX idx_links_case                    ON fund_flow_links (case_id);                       -- a case's links
CREATE INDEX idx_assignments_case              ON case_assignments (case_id, assigned_at);         -- assignment history
CREATE INDEX idx_assignments_investigator_open ON case_assignments (investigator_id) WHERE ended_at IS NULL;  -- my queue
CREATE INDEX idx_drafts_customer               ON draft_complaints (customer_id);                  -- customer's drafts
CREATE INDEX idx_users_role                    ON users (role) WHERE is_active;                    -- staff lists
