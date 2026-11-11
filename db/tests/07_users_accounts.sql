-- 07 users and accounts (007_users_accounts.sql): staff management, accounts, transfers that move money.
-- Run: docker compose exec postgres psql -U tracepay_owner -d tracepay -f /db/tests/07_users_accounts.sql
\ir _setup.sql
\set h '$2b$12$AyT2NAIAuThFVrMLKNZlbesCF.rpHgXh.VTvv3Q3bhqEkePHnPPn2'
CREATE TEMP TABLE money_before AS SELECT SUM(balance) AS total FROM accounts;

-- Creating users: staff only by a supervisor
SELECT pg_temp.act_as('v1@demo.in');
SELECT set_config('app.user_role', 'SUPERVISOR', true);
SELECT pg_temp.fails('a customer cannot create an investigator (a faked role does not help)',
  format('SELECT create_user(%L, %L, NULL, %L, %L)', 'x1@demo.in', 'Fake Staff', :'h', 'INVESTIGATOR'), 'TP002');
SELECT pg_temp.fails('a customer cannot promote anyone',
  format('CALL set_user_role(%s, %L)', pg_temp.uid('a@demo.in'), 'SUPERVISOR'), 'TP002');
SELECT pg_temp.act_as('sup1@demo.in');
SELECT pg_temp.ok('a supervisor creates an investigator',
  format('SELECT create_user(%L, %L, %L, %L, %L)', 'inv2@demo.in', 'New Investigator', '9123456780', :'h', 'INVESTIGATOR'));
SELECT pg_temp.check('the new user has role INVESTIGATOR', role = 'INVESTIGATOR', role::text) FROM users WHERE email = 'inv2@demo.in';
SELECT pg_temp.ok('a supervisor promotes a customer to supervisor', format('CALL set_user_role(%s, %L)', pg_temp.uid('a@demo.in'), 'SUPERVISOR'));
SELECT pg_temp.fails('nobody changes their own role', format('CALL set_user_role(%s, %L)', pg_temp.uid('sup1@demo.in'), 'INVESTIGATOR'), 'TP002');
SELECT pg_temp.fails('nobody deactivates themselves', format('CALL set_user_active(%s, false)', pg_temp.uid('sup1@demo.in')), 'TP002');

-- Deactivating an investigator ends their open assignments
INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative)
VALUES (pg_temp.uid('v1@demo.in'), pg_temp.txn('T1'), 1000, 'A test complaint to check that assignments end on deactivation.');
SELECT case_id AS c1 FROM fraud_cases WHERE disputed_txn_id = pg_temp.txn('T1') \gset
CALL assign_case(:c1, pg_temp.uid('inv2@demo.in'), 0);
SELECT pg_temp.ok('a supervisor deactivates the new investigator', format('CALL set_user_active(%s, false)', pg_temp.uid('inv2@demo.in')));
SELECT pg_temp.check('their open assignment was ended',
  NOT EXISTS (SELECT 1 FROM case_assignments WHERE investigator_id = pg_temp.uid('inv2@demo.in') AND ended_at IS NULL));
SELECT pg_temp.act_as('inv2@demo.in');
SELECT pg_temp.check('a deactivated user has no role any more', actor_role() IS NULL);

-- The last active supervisor always stays
SELECT pg_temp.act_as('sup1@demo.in');
CALL set_user_active(pg_temp.uid('a@demo.in'), false);
CALL set_user_active(pg_temp.uid('sup2@demo.in'), false);
SELECT pg_temp.check('only sup1 is an active supervisor now', count(*) = 1) FROM users WHERE role = 'SUPERVISOR' AND is_active;
SELECT set_config('app.user_id', '', true), set_config('app.allow_staff_insert', 'off', true);
SELECT pg_temp.fails('the last active supervisor cannot be removed',
  format('UPDATE users SET role = %L WHERE user_id = %s', 'CUSTOMER', pg_temp.uid('sup1@demo.in')), 'TP002');

-- User changes are audited, never with the password hash
SELECT pg_temp.act_as('sup1@demo.in');
CALL set_user_password(pg_temp.uid('inv2@demo.in'), '$2b$12$' || repeat('y', 53));
SELECT pg_temp.check('users are audited and the password hash is never stored in the log',
  count(*) >= 4 AND bool_and(NOT (coalesce(new_row, '{}') ? 'password_hash') AND NOT (coalesce(old_row, '{}') ? 'password_hash')),
  count(*) || ' rows') FROM audit_log WHERE entity_type = 'users';

-- Accounts
SELECT pg_temp.act_as('v1@demo.in');
SELECT pg_temp.fails('a customer cannot open a second account', format('SELECT open_account(%s, 100)', pg_temp.uid('v1@demo.in')), 'TP002');
SELECT set_config('app.user_id', '', true);
SELECT create_user('new@demo.in', 'New Customer', NULL, :'h') AS new_user \gset
SELECT pg_temp.ok('sign-up opens the new customer''s first account', format('SELECT open_account(%s, 100000)', :new_user));
SELECT pg_temp.check('the new account has the next free TP reference and its opening balance',
  account_ref ~ '^TP6[0-9]{9}$' AND balance = 100000, account_ref) FROM accounts WHERE user_id = :new_user;
SELECT pg_temp.act_as('sup1@demo.in');
SELECT pg_temp.ok('a supervisor opens a second account for V1', format('SELECT open_account(%s, 2500)', pg_temp.uid('v1@demo.in')));

-- Sending money: debit and credit in one step
SELECT pg_temp.act_as('v1@demo.in');
SELECT pg_temp.ok('V1 sends 1,000 to E', $$SELECT record_transfer('TP1000000001', 'TP1000000007', 1000, 'UPI')$$);
SELECT pg_temp.check('V1 debited, E credited',
  pg_temp.bal('TP1000000001') = 59000 AND pg_temp.bal('TP1000000007') = 6000,
  'V1 ' || pg_temp.bal('TP1000000001') || ', E ' || pg_temp.bal('TP1000000007'));
SELECT pg_temp.fails('an overdraft is refused', $$SELECT record_transfer('TP1000000001', 'TP1000000007', 999999, 'UPI')$$, 'TP002');
SELECT pg_temp.fails('nobody sends from someone else''s account', $$SELECT record_transfer('TP1000000002', 'TP1000000007', 10, 'UPI')$$, 'TP002');
SELECT pg_temp.fails('a customer cannot backdate a transfer', $$SELECT record_transfer('TP1000000001', 'TP1000000007', 10, 'UPI', now() - interval '2 days')$$, 'TP002');
SELECT pg_temp.fails('nobody dates a transfer in the future', $$SELECT record_transfer('TP1000000001', 'TP1000000007', 10, 'UPI', now() + interval '1 day')$$, 'TP002');
SELECT pg_temp.fails('the RECOVERY channel is reserved for refunds', $$SELECT record_transfer('TP1000000001', 'TP1000000007', 10, 'RECOVERY')$$, 'TP002');
SELECT pg_temp.fails('an unknown recipient', $$SELECT record_transfer('TP1000000001', 'TP0000000000', 10, 'UPI')$$, 'TP002');
SELECT pg_temp.act_as('sup1@demo.in');
SELECT pg_temp.ok('a supervisor records a backdated transfer C -> E (demo chains)',
  $$SELECT record_transfer('TP1000000005', 'TP1000000007', 500, 'IMPS', now() - interval '3 days')$$);
UPDATE accounts SET status = 'CLOSED' WHERE account_ref = 'TP1000000005';
SELECT pg_temp.fails('a transfer to a closed account is refused', $$SELECT record_transfer('TP1000000007', 'TP1000000005', 10, 'UPI')$$, 'TP002');
UPDATE accounts SET status = 'ACTIVE' WHERE account_ref = 'TP1000000005';

-- Money is conserved: only opening balances add money
SELECT pg_temp.check('the total across all accounts changed only by the two opening balances (102,500)',
  (SELECT SUM(balance) FROM accounts) = total + 102500, (SELECT SUM(balance) FROM accounts) - total || ' added') FROM money_before;
SELECT pg_temp.check('no account went below zero', min(balance) >= 0) FROM accounts;

\ir _report.sql
