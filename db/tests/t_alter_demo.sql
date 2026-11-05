-- Checks that 008_alter_demo.sql took effect. Read-only except one rolled-back insert.
\set QUIET on
BEGIN;
CREATE TEMP TABLE results (n serial, line text);
INSERT INTO results (line)
SELECT CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END || '  accounts.ifsc column added'
FROM information_schema.columns WHERE table_name = 'accounts' AND column_name = 'ifsc';
INSERT INTO results (line)
SELECT CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END || '  named CHECK accounts_ifsc_format exists'
FROM pg_constraint WHERE conname = 'accounts_ifsc_format';
INSERT INTO results (line)
SELECT CASE WHEN column_default = '2' THEN 'PASS' ELSE 'FAIL' END || '  fraud_cases.priority default is now ' || column_default
FROM information_schema.columns WHERE table_name = 'fraud_cases' AND column_name = 'priority';
INSERT INTO results (line)
SELECT CASE WHEN data_type = 'character varying' AND character_maximum_length = 15 THEN 'PASS' ELSE 'FAIL' END
       || '  users.phone widened to ' || data_type || '(' || character_maximum_length || ')'
FROM information_schema.columns WHERE table_name = 'users' AND column_name = 'phone';
DO $$ BEGIN
  UPDATE accounts SET ifsc = 'bad-code' WHERE account_ref = 'TP1000000001';
  INSERT INTO results (line) VALUES ('FAIL  bad IFSC accepted');
EXCEPTION WHEN check_violation THEN
  INSERT INTO results (line) VALUES ('PASS  bad IFSC rejected by the new CHECK');
END $$;
UPDATE accounts SET ifsc = 'SBIN0001234' WHERE account_ref = 'TP1000000001';
INSERT INTO results (line) VALUES ('PASS  valid IFSC SBIN0001234 accepted');
INSERT INTO results (line)
SELECT CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'FAIL' END || '  recreated materialized view and index exist'
FROM pg_class WHERE relname IN ('supervisor_case_summary', 'idx_txn_source_time');
\set QUIET off
SELECT line AS result FROM results ORDER BY n;
ROLLBACK;
