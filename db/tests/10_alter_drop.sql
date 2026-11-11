-- 10 schema evolution demo (requirement 5: ALTER and DROP). Every change runs inside the test transaction,
-- is checked, then ROLLED BACK: the real schema (db/migrations) is never altered after the fact.
-- Run: docker compose exec postgres psql -U tracepay_owner -d tracepay -f /db/tests/10_alter_drop.sql
\ir _setup.sql

-- 1. ALTER TABLE ... ADD COLUMN, then ADD a named CHECK constraint
ALTER TABLE accounts ADD COLUMN branch_city text;
ALTER TABLE accounts ADD CONSTRAINT accounts_branch_city_format CHECK (branch_city ~ '^[A-Z][a-z]+$');
SELECT pg_temp.check('ADD COLUMN: accounts.branch_city exists',
  EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'accounts' AND column_name = 'branch_city'));
SELECT pg_temp.fails('ADD CONSTRAINT: a badly written city is rejected',
  $$UPDATE accounts SET branch_city = 'bengaluru!' WHERE account_ref = 'TP1000000001'$$, '23514');
SELECT pg_temp.ok('ADD CONSTRAINT: a valid city is accepted',
  $$UPDATE accounts SET branch_city = 'Bengaluru' WHERE account_ref = 'TP1000000001'$$);

-- 2. ALTER COLUMN: change a default, change a type
ALTER TABLE fraud_cases ALTER COLUMN priority SET DEFAULT 3;
ALTER TABLE accounts ALTER COLUMN branch_city TYPE varchar(40);
SELECT pg_temp.check('SET DEFAULT: fraud_cases.priority now defaults to 3',
  column_default = '3', column_default) FROM information_schema.columns WHERE table_name = 'fraud_cases' AND column_name = 'priority';
SELECT pg_temp.check('ALTER TYPE: accounts.branch_city is varchar(40)',
  data_type = 'character varying' AND character_maximum_length = 40, data_type || '(' || character_maximum_length || ')')
FROM information_schema.columns WHERE table_name = 'accounts' AND column_name = 'branch_city';
SELECT pg_temp.fails('ALTER TYPE is refused on a column a trigger depends on (users.phone, audited)',
  'ALTER TABLE users ALTER COLUMN phone TYPE varchar(20)', '0A000');

-- 3. DROP and recreate a dependent object (the materialized view and its unique index)
DROP MATERIALIZED VIEW supervisor_case_summary;
SELECT pg_temp.check('DROP MATERIALIZED VIEW: it is gone',
  NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'supervisor_case_summary'));
CREATE MATERIALIZED VIEW supervisor_case_summary AS
  SELECT c.case_id, c.status, c.priority, c.reported_amount, c.verified_loss, c.created_at,
         COALESCE(a.allocated, 0) AS allocated, COALESCE(r.refunded, 0) AS refunded
  FROM fraud_cases c
  LEFT JOIN (SELECT case_id, SUM(amount) AS allocated FROM recovery_allocations
             WHERE status IN ('ACTIVE', 'PAID') GROUP BY case_id) a ON a.case_id = c.case_id
  LEFT JOIN (SELECT ra.case_id, SUM(rf.amount) AS refunded
             FROM refunds rf JOIN recovery_allocations ra ON ra.allocation_id = rf.allocation_id
             WHERE rf.status = 'PROCESSED' GROUP BY ra.case_id) r ON r.case_id = c.case_id;
CREATE UNIQUE INDEX supervisor_case_summary_pk ON supervisor_case_summary (case_id);
SELECT pg_temp.ok('the recreated view refreshes concurrently (needs its unique index)',
  'REFRESH MATERIALIZED VIEW CONCURRENTLY supervisor_case_summary');

-- 4. DROP INDEX / CREATE INDEX (the EXPLAIN before-and-after experiment uses exactly this pair)
DROP INDEX idx_txn_source_time;
SELECT pg_temp.check('DROP INDEX: idx_txn_source_time is gone', NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'idx_txn_source_time'));
CREATE INDEX idx_txn_source_time ON transactions (source_account_id, occurred_at, txn_id);
SELECT pg_temp.check('CREATE INDEX: idx_txn_source_time is back', EXISTS (SELECT 1 FROM pg_class WHERE relname = 'idx_txn_source_time'));

-- 5. DROP COLUMN
ALTER TABLE accounts DROP COLUMN branch_city;
SELECT pg_temp.check('DROP COLUMN: accounts.branch_city is gone (with its constraint)',
  NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'accounts' AND column_name = 'branch_city')
  AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'accounts_branch_city_format'));

\ir _report.sql
