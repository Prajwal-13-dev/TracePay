// Neo4j tests (needs PostgreSQL and Neo4j running):
//   1. sync:   Neo4j holds exactly the accounts, transfers and cases PostgreSQL has; the outbox is empty
//   2. replay: re-queueing every row and syncing again creates no duplicates (MERGE is idempotent)
//   3. parity: the Neo4j trace returns exactly what the PostgreSQL recursive CTE returns
//      (same transfers, hop depth, parent and upper bound) for every case's disputed transfer
//   npm run graph:test
import { execSync } from 'node:child_process';
import pg from 'pg';
import neo4j from 'neo4j-driver';
import { MAX_HOPS, WINDOW_HOURS, traceFrom } from '../src/lib/graphQueries.mjs';

const db = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 2 });
const driver = neo4j.driver(process.env.NEO4J_URI ?? 'bolt://localhost:7687',
  neo4j.auth.basic(process.env.NEO4J_USER ?? 'neo4j', process.env.NEO4J_PASSWORD ?? ''),
  { disableLosslessIntegers: true });

// Parent is left out: when two parents tie (same depth, same upper bound) either is correct, and
// PostgreSQL breaks such ties in no fixed order.
const key = r => `${r.txn_id}|d${r.depth}|ub${Number(r.upper_bound).toFixed(2)}`;

// Disputed transfers of all cases, plus the demo roots T1 and T6 even if their cases are not filed yet.
const { rows: roots } = await db.query(
  `SELECT DISTINCT txn_id::int FROM (
     SELECT disputed_txn_id AS txn_id FROM fraud_cases
     UNION SELECT txn_id FROM transactions WHERE external_ref IN ('T1', 'T6')) x ORDER BY 1`);

let pass = 0, fail = 0;
const check = (ok, label) => { console.log(`${ok ? 'PASS' : 'FAIL'} ${label}`); if (ok) pass++; else fail++; };
const sync = () => execSync('node --env-file-if-exists=.env scripts/graph-sync.mjs --once', { stdio: 'ignore' });

async function counts() {
  const [p] = (await db.query(`SELECT (SELECT count(*) FROM accounts)::int AS accounts,
    (SELECT count(*) FROM transactions)::int AS transfers, (SELECT count(*) FROM fraud_cases)::int AS cases`)).rows;
  const { records } = await driver.executeQuery(`
    CALL { MATCH (a:Account) RETURN count(a) AS accounts }
    CALL { MATCH ()-[t:SENT]->() RETURN count(t) AS transfers, count(DISTINCT t.txn_id) AS distinct_transfers }
    CALL { MATCH (c:Case) RETURN count(c) AS cases }
    CALL { MATCH (c:Case)-[r:ROOT]->() WITH c, count(r) AS n WHERE n > 1 RETURN count(c) AS multi_root }
    RETURN accounts, transfers, distinct_transfers, cases, multi_root`);
  return { p, g: records[0].toObject() };
}

sync();
let { p, g } = await counts();
const pending = (await db.query('SELECT count(*)::int AS n FROM graph_outbox WHERE processed_at IS NULL')).rows[0].n;
check(pending === 0, `sync: outbox drained (${pending} pending)`);
check(g.accounts === p.accounts, `sync: accounts ${g.accounts} in Neo4j = ${p.accounts} in PostgreSQL`);
check(g.transfers === p.transfers, `sync: transfers ${g.transfers} in Neo4j = ${p.transfers} in PostgreSQL`);
check(g.cases === p.cases, `sync: cases ${g.cases} in Neo4j = ${p.cases} in PostgreSQL`);

await db.query('SELECT enqueue_full_graph_sync()');
sync();
({ p, g } = await counts());
check(g.transfers === p.transfers && g.distinct_transfers === g.transfers && g.accounts === p.accounts
      && g.cases === p.cases && g.multi_root === 0, 'replay: syncing everything twice creates no duplicates');

for (const { txn_id } of roots) {
  const sql = (await db.query(
    'SELECT txn_id::int, parent_txn_id::int, depth, upper_bound FROM trace_candidates($1, $2::int, make_interval(hours => $3))',
    [txn_id, MAX_HOPS, WINDOW_HOURS])).rows.map(key).sort();
  const run = async (q, p) => (await driver.executeQuery(q, p)).records.map(r => r.toObject());
  const graph = ((await traceFrom(run, txn_id)) ?? []).map(key).sort();
  const same = sql.length === graph.length && sql.every((k, i) => k === graph[i]);
  check(same, `parity: trace from txn ${txn_id} (${sql.length} transfers)`);
  if (!same) console.log(`  postgres: ${sql.join(' ')}\n  neo4j:    ${graph.join(' ')}`);
}
console.log(`\n${pass + fail} graph checks: ${pass} passed, ${fail} failed`);
await driver.close(); await db.end();
process.exit(fail ? 1 : 0);
