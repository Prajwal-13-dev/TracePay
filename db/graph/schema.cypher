// Neo4j schema for TracePay (applied automatically by scripts/graph-sync.mjs).
//
// Model
//   (:Account {account_id, account_ref, balance, status, owner})
//   (:Account)-[:SENT {txn_id, ref, amount, occurred_at, channel}]->(:Account)
//   (:Case {case_id, status, root_txn_id})-[:ROOT]->(:Account)   // account that received the disputed transfer

CREATE CONSTRAINT account_id_unique IF NOT EXISTS FOR (a:Account) REQUIRE a.account_id IS UNIQUE;
CREATE CONSTRAINT case_id_unique    IF NOT EXISTS FOR (c:Case)    REQUIRE c.case_id    IS UNIQUE;
CREATE INDEX account_ref_idx  IF NOT EXISTS FOR (a:Account) ON (a.account_ref);
CREATE INDEX sent_txn_idx     IF NOT EXISTS FOR ()-[s:SENT]-() ON (s.txn_id);
CREATE INDEX sent_time_idx    IF NOT EXISTS FOR ()-[s:SENT]-() ON (s.occurred_at);
