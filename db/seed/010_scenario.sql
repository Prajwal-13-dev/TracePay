-- Demo scenario (handbook 3.2). Every demo user's password is: Demo@1234
-- Staff accounts (investigator, supervisors) can only be created here, never by sign-up.
SET app.allow_staff_insert = 'on';
\set pw '$2b$12$AyT2NAIAuThFVrMLKNZlbesCF.rpHgXh.VTvv3Q3bhqEkePHnPPn2'

INSERT INTO users (email, full_name, phone, password_hash, role) VALUES
 ('v1@demo.in',   'Victim One',       '9000000001', :'pw', 'CUSTOMER'),
 ('v2@demo.in',   'Victim Two',       '9000000002', :'pw', 'CUSTOMER'),
 ('a@demo.in',    'Mule Owner A',     '9000000003', :'pw', 'CUSTOMER'),
 ('b@demo.in',    'Mule Owner B',     '9000000004', :'pw', 'CUSTOMER'),
 ('c@demo.in',    'Mule Owner C',     '9000000005', :'pw', 'CUSTOMER'),
 ('d@demo.in',    'Mule Owner D',     '9000000006', :'pw', 'CUSTOMER'),
 ('e@demo.in',    'Mule Owner E',     '9000000007', :'pw', 'CUSTOMER'),
 ('inv@demo.in',  'Ira Investigator', '9100000001', :'pw', 'INVESTIGATOR'),
 ('sup1@demo.in', 'Sam Supervisor',   '9100000002', :'pw', 'SUPERVISOR'),
 ('sup2@demo.in', 'Sia Supervisor',   '9100000003', :'pw', 'SUPERVISOR');

INSERT INTO accounts (user_id, account_ref, balance)
SELECT u.user_id, a.ref, a.bal
FROM (VALUES ('v1@demo.in', 'TP1000000001', 60000),   -- V1
             ('v2@demo.in', 'TP1000000002', 30000),   -- V2
             ('a@demo.in',  'TP1000000003', 30000),   -- A
             ('b@demo.in',  'TP1000000004', 30000),   -- B
             ('c@demo.in',  'TP1000000005', 15000),   -- C
             ('d@demo.in',  'TP1000000006', 12000),   -- D: freeze limit in the demo
             ('e@demo.in',  'TP1000000007',  5000))   -- E
     AS a(email, ref, bal)
JOIN users u ON u.email = a.email
ORDER BY a.ref;

-- Inserted in label order, so txn_id 1..7 = T1..T7
INSERT INTO transactions (external_ref, source_account_id, destination_account_id, amount, channel, occurred_at)
SELECT t.ref, s.account_id, d.account_id, t.amt, 'UPI', t.at::timestamptz
FROM (VALUES
  (1, 'T1', 'TP1000000001', 'TP1000000003', 40000, '2026-10-12 10:00+05:30'),  -- V1 -> A (case C1)
  (2, 'T2', 'TP1000000003', 'TP1000000004', 25000, '2026-10-12 10:20+05:30'),  -- A -> B
  (3, 'T3', 'TP1000000003', 'TP1000000005', 15000, '2026-10-12 10:25+05:30'),  -- A -> C
  (4, 'T4', 'TP1000000004', 'TP1000000006', 10000, '2026-10-12 11:00+05:30'),  -- B -> D
  (5, 'T5', 'TP1000000004', 'TP1000000003',  8000, '2026-10-12 11:10+05:30'),  -- B -> A (cycle)
  (6, 'T6', 'TP1000000002', 'TP1000000004', 20000, '2026-10-12 10:40+05:30'),  -- V2 -> B (case C2)
  (7, 'T7', 'TP1000000003', 'TP1000000007',  5000, '2026-10-12 11:30+05:30')   -- A -> E
) AS t(n, ref, src, dst, amt, at)
JOIN accounts s ON s.account_ref = t.src
JOIN accounts d ON d.account_ref = t.dst
ORDER BY t.n;
