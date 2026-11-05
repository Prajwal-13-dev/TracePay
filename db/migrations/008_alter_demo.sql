 schema evolution after the fact (requirement 5: ALTER and DROP).

-- 1. ALTER TABLE ... ADD COLUMN, then ADD a named CHECK constraint
ALTER TABLE accounts ADD COLUMN ifsc text;
ALTER TABLE accounts ADD CONSTRAINT accounts_ifsc_format CHECK (ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$');
COMMENT ON COLUMN accounts.ifsc IS 'Indian Financial System Code of the branch; NULL for simulated accounts';

-- 2. ALTER COLUMN: change a default, widen a type
ALTER TABLE fraud_cases ALTER COLUMN priority SET DEFAULT 2;
ALTER TABLE users ALTER COLUMN phone TYPE varchar(15);

-- 3. DROP and recreate a dependent object safely (materialized view + its unique index)
DROP MATERIALIZED VIEW IF EXISTS supervisor_case_summary;
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
CREATE UNIQUE INDEX supervisor_case_summary_pk ON supervisor_case_summary (case_id);

-- 4. DROP INDEX / CREATE INDEX (the EXPLAIN before-and-after experiment uses exactly this pair)
DROP INDEX IF EXISTS idx_txn_source_time;
CREATE INDEX idx_txn_source_time ON transactions (source_account_id, occurred_at, txn_id);
