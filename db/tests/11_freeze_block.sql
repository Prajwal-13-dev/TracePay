-- 11 Freeze blocks the whole account (010_freeze_blocks_outgoing.sql): while a freeze is ACTIVE no money may
-- leave the account, whatever the amount; incoming money and recovery payouts are still allowed.
-- Run: docker compose exec postgres psql -U tracepay_owner -d tracepay -f /db/tests/11_freeze_block.sql
\ir _setup.sql

-- A small ACTIVE freeze (1,000) on D, approved by a second supervisor: far less than D's balance.
INSERT INTO account_freezes (account_id, requested_for_case, requested_by, approved_by, frozen_amount, status, approved_at, expires_at)
VALUES (pg_temp.acct('TP1000000006'), (SELECT min(case_id) FROM fraud_cases), pg_temp.uid('sup1@demo.in'),
        pg_temp.uid('sup2@demo.in'), 1000, 'ACTIVE', now(), now() + interval '7 days')
RETURNING freeze_id AS f1 \gset
SELECT pg_temp.check('D has more than the frozen 1,000', pg_temp.bal('TP1000000006') > 1000, 'balance ' || pg_temp.bal('TP1000000006'));

SELECT pg_temp.act_as('d@demo.in');
SELECT pg_temp.fails('frozen account cannot send even 1 rupee',
  $$SELECT record_transfer('TP1000000006', 'TP1000000007', 1, 'UPI')$$, 'TP006');
SELECT pg_temp.fails('frozen account cannot send its unfrozen part either (whole account blocked)',
  $$SELECT record_transfer('TP1000000006', 'TP1000000007', 500, 'IMPS')$$, 'TP006');
SELECT pg_temp.check('the refused transfers moved no money', pg_temp.bal('TP1000000006') > 1000);

SELECT pg_temp.act_as('c@demo.in');
SELECT pg_temp.ok('a frozen account can still RECEIVE money',
  $$SELECT record_transfer('TP1000000005', 'TP1000000006', 100, 'UPI')$$);
SELECT pg_temp.ok('other accounts are unaffected',
  $$SELECT record_transfer('TP1000000005', 'TP1000000007', 100, 'UPI')$$);
SELECT pg_temp.check('account_is_frozen() reports the block',
  account_is_frozen(pg_temp.acct('TP1000000006')) AND NOT account_is_frozen(pg_temp.acct('TP1000000005')));

-- Recovery payouts (channel RECOVERY, only made by pay_out_freeze) may leave a frozen account.
SELECT pg_temp.ok('a RECOVERY payout may leave a frozen account', format(
  $$INSERT INTO transactions (external_ref, source_account_id, destination_account_id, amount, channel, occurred_at)
    VALUES ('RC-TEST', %s, %s, 10, 'RECOVERY', now())$$, pg_temp.acct('TP1000000006'), pg_temp.acct('TP1000000001')));
SELECT pg_temp.fails('customers cannot use the RECOVERY channel to get round the block',
  $$SELECT record_transfer('TP1000000006', 'TP1000000007', 1, 'RECOVERY')$$, 'TP002');

-- When the freeze ends the block lifts.
RESET ROLE;
UPDATE account_freezes SET status = 'RELEASED' WHERE freeze_id = :f1;
SELECT pg_temp.act_as('d@demo.in');
SELECT pg_temp.ok('after the freeze ends, the account can send again',
  $$SELECT record_transfer('TP1000000006', 'TP1000000007', 1, 'UPI')$$);

-- An expired freeze does not block either.
INSERT INTO account_freezes (account_id, requested_for_case, requested_by, approved_by, frozen_amount, status, approved_at, expires_at)
VALUES (pg_temp.acct('TP1000000005'), (SELECT min(case_id) FROM fraud_cases), pg_temp.uid('sup1@demo.in'),
        pg_temp.uid('sup2@demo.in'), 10, 'ACTIVE', now() - interval '2 days', now() - interval '1 day');
SELECT pg_temp.act_as('c@demo.in');
SELECT pg_temp.ok('an expired freeze does not block',
  $$SELECT record_transfer('TP1000000005', 'TP1000000007', 1, 'UPI')$$);

\ir _report.sql
