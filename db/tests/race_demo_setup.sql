-- Race-demo fixture (handbook 22.1). COMMITS data: rebuild the DB afterwards for a clean state.
-- Freeze of 10,000 at account D; cases C1 and C2 each verified at 8,000, so only the freeze limit matters.
-- Then open TWO terminals and follow db/tests/RACE_DEMO.md.
INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative)
SELECT u.user_id, t.txn_id, 8000, 'Race demo complaint: fake courier customs fee scam.'
FROM (VALUES ('v1@demo.in', 'T1'), ('v2@demo.in', 'T6')) AS x(email, ref)
JOIN users u ON u.email = x.email JOIN transactions t ON t.external_ref = x.ref;

UPDATE fraud_cases SET verified_loss = 8000,
       verified_by = (SELECT user_id FROM users WHERE email = 'sup1@demo.in')
WHERE disputed_txn_id IN (SELECT txn_id FROM transactions WHERE external_ref IN ('T1', 'T6'));

INSERT INTO account_freezes (account_id, requested_for_case, requested_by, approved_by,
                             frozen_amount, status, approved_at, expires_at)
SELECT (SELECT account_id FROM accounts WHERE account_ref = 'TP1000000006'),
       (SELECT case_id FROM fraud_cases WHERE disputed_txn_id = (SELECT txn_id FROM transactions WHERE external_ref = 'T1')),
       (SELECT user_id FROM users WHERE email = 'inv@demo.in'),
       (SELECT user_id FROM users WHERE email = 'sup1@demo.in'),
       10000, 'ACTIVE', now(), now() + interval '7 days';

\echo ''
\echo 'Copy these lines. Terminal A gets the first INSERT, terminal B the second:'
SELECT format('INSERT INTO recovery_allocations (freeze_id, case_id, amount, allocated_by) VALUES (%s, %s, 6000, %s);',
              f.freeze_id, c.case_id, (SELECT user_id FROM users WHERE email = 'sup1@demo.in')) AS paste_this
FROM account_freezes f
JOIN fraud_cases c ON c.disputed_txn_id IN (SELECT txn_id FROM transactions WHERE external_ref IN ('T1', 'T6'))
WHERE f.frozen_amount = 10000 AND f.status = 'ACTIVE'
ORDER BY c.case_id;
