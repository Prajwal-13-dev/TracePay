-- Race-demo fixture (handbook 22.1). COMMITS data: rebuild the DB afterwards for a clean state.
-- Freeze of 10,000 at account D; cases C1 and C2 each verified at 8,000, so only the freeze limit matters.
-- Then open TWO terminals and follow db/tests/RACE_DEMO.md.
INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative)
SELECT u.user_id, t.txn_id, 8000, 'Race demo complaint: fake courier customs fee scam.'
FROM (VALUES ('v1@demo.in', 'T1'), ('v2@demo.in', 'T6')) AS x(email, ref)
JOIN users u ON u.email = x.email JOIN transactions t ON t.external_ref = x.ref;

UPDATE fraud_cases SET verified_loss = 8000,
       verified_by = (SELECT user_id FROM users WHERE email = 'sup1@demo.in');

INSERT INTO account_freezes (account_id, requested_for_case, requested_by, approved_by,
                             frozen_amount, status, approved_at, expires_at)
SELECT (SELECT account_id FROM accounts WHERE account_ref = 'TP1000000006'),
       (SELECT case_id FROM fraud_cases WHERE disputed_txn_id = (SELECT txn_id FROM transactions WHERE external_ref = 'T1')),
       (SELECT user_id FROM users WHERE email = 'inv@demo.in'),
       (SELECT user_id FROM users WHERE email = 'sup1@demo.in'),
       10000, 'ACTIVE', now(), now() + interval '7 days';

SELECT f.freeze_id, f.frozen_amount, c.case_id, c.verified_loss
FROM account_freezes f CROSS JOIN fraud_cases c ORDER BY c.case_id;
