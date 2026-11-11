-- 030_chains.sql : realistic laundering chains for the 96 sample complaints.
-- Without this, each sample case is a single transfer (victim -> mule) and the trace graph has one arrow.
-- Money now moves on, like real mule networks:
--   victim --(disputed)--> mule holder --(40 min)--> layering account --(3 h)--> cash-out agent
-- and every third mule also forwards a slice to the NEXT mule (20 min), so chains get longer and
-- different victims' money mixes in the same accounts (the "shared mule" situation).
-- Finally 12 cases are assigned to the investigator (6 already INVESTIGATING) so they can be traced.
SET app.allow_staff_insert = 'off';

INSERT INTO users (email, full_name, phone, password_hash) VALUES
 ('layer1@demo.in', 'Layering Account 1', '8100000001', '$2b$12$AyT2NAIAuThFVrMLKNZlbesCF.rpHgXh.VTvv3Q3bhqEkePHnPPn2'),
 ('layer2@demo.in', 'Layering Account 2', '8100000002', '$2b$12$AyT2NAIAuThFVrMLKNZlbesCF.rpHgXh.VTvv3Q3bhqEkePHnPPn2'),
 ('layer3@demo.in', 'Layering Account 3', '8100000003', '$2b$12$AyT2NAIAuThFVrMLKNZlbesCF.rpHgXh.VTvv3Q3bhqEkePHnPPn2'),
 ('layer4@demo.in', 'Layering Account 4', '8100000004', '$2b$12$AyT2NAIAuThFVrMLKNZlbesCF.rpHgXh.VTvv3Q3bhqEkePHnPPn2'),
 ('cashout1@demo.in', 'Cash-out Agent 1', '8200000001', '$2b$12$AyT2NAIAuThFVrMLKNZlbesCF.rpHgXh.VTvv3Q3bhqEkePHnPPn2'),
 ('cashout2@demo.in', 'Cash-out Agent 2', '8200000002', '$2b$12$AyT2NAIAuThFVrMLKNZlbesCF.rpHgXh.VTvv3Q3bhqEkePHnPPn2');

INSERT INTO accounts (user_id, account_ref, balance)
SELECT u.user_id, a.ref, a.bal
FROM (VALUES ('layer1@demo.in', 'TP4000000001', 40000), ('layer2@demo.in', 'TP4000000002', 40000),
             ('layer3@demo.in', 'TP4000000003', 40000), ('layer4@demo.in', 'TP4000000004', 40000),
             ('cashout1@demo.in', 'TP5000000001', 90000), ('cashout2@demo.in', 'TP5000000002', 90000)) AS a(email, ref, bal)
JOIN users u ON u.email = a.email ORDER BY a.ref;

-- The disputed transfers of the sample cases, with the mule number (1..10) they reached.
CREATE TEMP TABLE sample AS
SELECT t.external_ref AS ref, t.amount, t.occurred_at AS at, d.account_ref AS mule,
       substr(d.account_ref, 11)::int AS m, row_number() OVER (ORDER BY t.occurred_at, t.txn_id) AS n
FROM fraud_cases c JOIN transactions t ON t.txn_id = c.disputed_txn_id
JOIN accounts d ON d.account_id = t.destination_account_id
WHERE d.account_ref LIKE 'TP3%';

CREATE TEMP TABLE seed_transfer_rows AS
SELECT row_number() OVER (ORDER BY h.at, h.ref) AS ord, h.ref AS external_ref, src.account_id AS source_account_id,
       dst.account_id AS destination_account_id, h.amt::numeric AS amount, h.channel::text AS channel, h.at AS occurred_at
FROM (
  -- hop 1: mule -> layering account, 80% of the money, 40 minutes later
  SELECT 'L1-' || ref AS ref, mule AS src, 'TP400000000' || (1 + (m - 1) % 4) AS dst,
         round(amount * 0.8) AS amt, 'IMPS' AS channel, at + interval '40 minutes' AS at FROM sample
  UNION ALL
  -- hop 2: layering account -> cash-out agent, 60%, 3 hours later
  SELECT 'L2-' || ref, 'TP400000000' || (1 + (m - 1) % 4), 'TP500000000' || (1 + (m - 1) % 2),
         round(amount * 0.6), 'NEFT', at + interval '3 hours' FROM sample
  UNION ALL
  -- every third case: mule -> next mule, 15%, 20 minutes later (makes chains longer and mixed)
  SELECT 'X-' || ref, mule, 'TP30000000' || lpad((m % 10 + 1)::text, 2, '0'),
         round(amount * 0.15), 'UPI', at + interval '20 minutes' FROM sample WHERE n % 3 = 0
) h
JOIN accounts src ON src.account_ref = h.src
JOIN accounts dst ON dst.account_ref = h.dst
WHERE h.amt > 0;
CALL seed_insert_transfers();

-- Give the investigator work: 12 cases assigned, the first 6 already accepted (INVESTIGATING).
DO $$
DECLARE
  v_inv bigint := (SELECT user_id FROM users WHERE email = 'inv@demo.in');
  v_sup bigint := (SELECT user_id FROM users WHERE email = 'sup1@demo.in');
  r record;
BEGIN
  PERFORM set_config('app.user_id', v_sup::text, true), set_config('app.user_role', 'SUPERVISOR', true);
  FOR r IN SELECT case_id FROM fraud_cases WHERE status = 'SUBMITTED' ORDER BY case_id LIMIT 12 LOOP
    CALL assign_case(r.case_id, v_inv, v_sup);
  END LOOP;
  PERFORM set_config('app.user_id', v_inv::text, true), set_config('app.user_role', 'INVESTIGATOR', true);
  UPDATE fraud_cases SET status = 'INVESTIGATING'
  WHERE case_id IN (SELECT case_id FROM fraud_cases WHERE status = 'UNDER_REVIEW' ORDER BY case_id LIMIT 6);
END $$;

DROP TABLE sample;
