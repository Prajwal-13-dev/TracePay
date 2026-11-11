// PostgreSQL -> Neo4j sync worker (transactional outbox).
//
//   npm run graph:sync      keep running: drain graph_outbox every second
//   npm run graph:once      drain once and exit
//   npm run graph:rebuild   wipe the graph, re-queue every row, drain, exit
//
// Every write is a MERGE keyed on the PostgreSQL id, so processing a row twice is harmless.
import { readFileSync } from 'node:fs';
import pg from 'pg';
import neo4j from 'neo4j-driver';

const args = new Set(process.argv.slice(2));
const ONCE = args.has('--once') || args.has('--rebuild');
const BATCH = 200;

const db = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 2 });
const driver = neo4j.driver(process.env.NEO4J_URI ?? 'bolt://localhost:7687',
  neo4j.auth.basic(process.env.NEO4J_USER ?? 'neo4j', process.env.NEO4J_PASSWORD ?? ''));

const CYPHER = {
  account: `
    MERGE (a:Account {account_id: $r.account_id})
    SET a.account_ref = $r.account_ref, a.balance = $r.balance, a.status = $r.status, a.owner = $r.owner`,
  transaction: `
    MERGE (s:Account {account_id: $r.source_account_id})
    MERGE (d:Account {account_id: $r.destination_account_id})
    MERGE (s)-[t:SENT {txn_id: $r.txn_id}]->(d)
    SET t.ref = $r.external_ref, t.amount = $r.amount, t.channel = $r.channel,
        t.occurred_at = datetime($r.occurred_at)`,
  case: `
    MERGE (c:Case {case_id: $r.case_id})
    SET c.status = $r.status, c.root_txn_id = $r.disputed_txn_id
    WITH c
    MATCH (root:Account {account_id: $r.root_account_id})
    MERGE (c)-[:ROOT]->(root)`,
};

const LOAD = {
  account: `SELECT a.account_id::int, a.account_ref, a.balance::float8 AS balance, a.status, u.full_name AS owner
            FROM accounts a JOIN users u USING (user_id) WHERE a.account_id = ANY($1)`,
  transaction: `SELECT txn_id::int AS txn_id, external_ref, source_account_id::int, destination_account_id::int,
                       amount::float8 AS amount, channel, to_char(occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS occurred_at
                FROM transactions WHERE txn_id = ANY($1)`,
  case: `SELECT c.case_id::int, c.status, c.disputed_txn_id::int, t.destination_account_id::int AS root_account_id
         FROM fraud_cases c JOIN transactions t ON t.txn_id = c.disputed_txn_id WHERE c.case_id = ANY($1)`,
};
// Accounts before transfers before cases, so MERGEd nodes get their properties first.
const ORDER = ['account', 'transaction', 'case'];

async function applySchema() {
  const stmts = readFileSync(new URL('../db/graph/schema.cypher', import.meta.url), 'utf8')
    .split(';').map(s => s.replace(/\/\/.*$/gm, '').trim()).filter(Boolean);
  const s = driver.session();
  try { for (const q of stmts) await s.run(q); } finally { await s.close(); }
}

async function drainOnce() {
  const c = await db.connect();
  let done = 0;
  try {
    await c.query('BEGIN');
    // SKIP LOCKED: two workers never process the same row.
    const { rows } = await c.query(
      `SELECT outbox_id, entity, entity_id::int FROM graph_outbox
       WHERE processed_at IS NULL AND attempts < 10
       ORDER BY outbox_id LIMIT ${BATCH} FOR UPDATE SKIP LOCKED`);
    if (!rows.length) { await c.query('COMMIT'); return 0; }

    const session = driver.session();
    try {
      for (const entity of ORDER) {
        const ids = [...new Set(rows.filter(r => r.entity === entity).map(r => r.entity_id))];
        if (!ids.length) continue;
        const data = (await c.query(LOAD[entity], [ids])).rows;
        await session.executeWrite(async tx => {
          for (const r of data) await tx.run(CYPHER[entity], { r });
        });
        done += ids.length;
      }
      await c.query('UPDATE graph_outbox SET processed_at = now() WHERE outbox_id = ANY($1)',
                    [rows.map(r => r.outbox_id)]);
    } catch (e) {
      await c.query(`UPDATE graph_outbox SET attempts = attempts + 1, last_error = $2 WHERE outbox_id = ANY($1)`,
                    [rows.map(r => r.outbox_id), String(e.message ?? e).slice(0, 500)]);
      console.error('sync batch failed:', e.message ?? e);
    } finally {
      await session.close();
    }
    await c.query('COMMIT');
  } catch (e) {
    await c.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    c.release();
  }
  return done;
}

async function main() {
  await driver.verifyConnectivity();
  await applySchema();
  if (args.has('--rebuild')) {
    await driver.executeQuery('MATCH (n) DETACH DELETE n');
    const { rows } = await db.query('SELECT enqueue_full_graph_sync() AS n');
    console.log(`graph wiped, ${rows[0].n} rows queued`);
  }
  for (;;) {
    let n;
    while ((n = await drainOnce()) > 0) console.log(`synced ${n} entities`);
    if (ONCE) break;
    await new Promise(r => setTimeout(r, 1000));
  }
  const { records } = await driver.executeQuery(
    'MATCH (a:Account) WITH count(a) AS accounts OPTIONAL MATCH ()-[t:SENT]->() RETURN accounts, count(t) AS transfers');
  console.log('graph now holds', records[0]?.toObject());
  await driver.close(); await db.end();
}

main().catch(async e => { console.error(e); await driver.close(); await db.end(); process.exit(1); });
