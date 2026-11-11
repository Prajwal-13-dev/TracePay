// Neo4j tracing, used by the app (src/lib/graph.ts) and by scripts/graph-test.mjs.
// Plain JS so Node scripts can import it without a TypeScript build.
//
// WHY HOP BY HOP: a single variable-length pattern ([:SENT*1..]) makes Neo4j list every path first and
// only then apply the time rules. Mule networks contain loops, so that list explodes (tens of millions of
// paths from one account) and the query never finishes. Instead we expand one hop per query, keeping only
// transfers that are strictly later than the previous hop and within the window, exactly like the
// recursive CTE trace_candidates() in PostgreSQL. Impossible paths are never generated.
//
// Same semantics as trace_candidates() (004/010):
//   money leaves the account it reached, strictly later, within WINDOW_HOURS per hop, any number of hops;
//   strictly increasing times mean no transfer can repeat on a path (cycles end by themselves);
//   each transfer is reported once, on its shallowest path (ties: the larger upper bound, then the later parent).

// No hop limit: paths end on their own because each hop must be strictly later than the last.
export const MAX_HOPS = null;
export const WINDOW_HOURS = 72;
const SAFETY_LEVELS = 500;   // only guards against a corrupt graph; real data stops long before

// The disputed transfer (depth 0).
export const ROOT_CYPHER = `
MATCH (f:Account)-[r:SENT {txn_id: $txn}]->(t:Account)
RETURN r.txn_id AS txn_id, r.ref AS ref, null AS parent_txn_id, null AS parent_ref, 0 AS depth,
       f.account_id AS from_id, f.account_ref AS from_ref, t.account_id AS to_id, t.account_ref AS to_ref,
       r.amount AS amount, toString(r.occurred_at) AS occurred_at, r.amount AS upper_bound, [r.txn_id] AS path`;

// Roots for every open case at once (for shared-mule detection); `key` = the case id.
export const OPEN_CASE_ROOTS_CYPHER = `
MATCH (c:Case) WHERE NOT c.status IN ['CLOSED', 'REJECTED']
MATCH (f:Account)-[r:SENT {txn_id: c.root_txn_id}]->(t:Account)
RETURN c.case_id AS key, r.txn_id AS txn_id, r.ref AS ref, 0 AS depth,
       f.account_id AS from_id, t.account_id AS to_id, t.account_ref AS to_ref,
       r.amount AS amount, toString(r.occurred_at) AS occurred_at, r.amount AS upper_bound, [r.txn_id] AS path`;

// One hop for a whole frontier: every transfer leaving the account a frontier row reached,
// strictly later than that row and within the window. Uses the account_id uniqueness index.
export const STEP_CYPHER = `
UNWIND $frontier AS f
MATCH (a:Account {account_id: f.to_id})-[r:SENT]->(t:Account)
WHERE r.occurred_at > datetime(f.at)
  AND r.occurred_at <= datetime(f.at) + duration({hours: $window})
  AND NOT r.txn_id IN f.path
RETURN f.key AS key, f.txn_id AS parent_txn_id, f.ref AS parent_ref,
       r.txn_id AS txn_id, r.ref AS ref, a.account_id AS from_id, a.account_ref AS from_ref,
       t.account_id AS to_id, t.account_ref AS to_ref, r.amount AS amount, toString(r.occurred_at) AS occurred_at,
       CASE WHEN r.amount < f.ub THEN r.amount ELSE f.ub END AS upper_bound, f.path + r.txn_id AS path`;

// Breadth-first expansion, level by level, for one or many roots (each root has its own `key`).
// run(cypher, params) -> array of plain row objects. Returns Map(key -> rows), roots included.
export async function expandFromRoots(run, roots) {
  const found = new Map();                      // key -> Map(txn_id -> row)
  for (const r of roots) found.set(r.key, new Map([[r.txn_id, { ...r, depth: 0 }]]));
  let frontier = roots;
  for (let depth = 1; frontier.length > 0; depth++) {
    if (depth > SAFETY_LEVELS) throw new Error(`trace exceeded ${SAFETY_LEVELS} hops: graph data looks corrupt`);
    const rows = await run(STEP_CYPHER, {
      window: WINDOW_HOURS,
      frontier: frontier.map(f => ({ key: f.key, txn_id: f.txn_id, ref: f.ref, to_id: f.to_id,
                                     at: f.occurred_at, ub: f.upper_bound, path: f.path })),
    });
    // Per (key, transfer): keep the row with the largest upper bound at this depth; on a tie, the later parent
    // transfer (PostgreSQL breaks such ties in no fixed order, so both answers are equally valid).
    const best = new Map();
    for (const r of rows) {
      if (found.get(r.key).has(r.txn_id)) continue;           // already reached at a shallower depth
      const id = `${r.key}|${r.txn_id}`, prev = best.get(id);
      if (!prev || r.upper_bound > prev.upper_bound
          || (r.upper_bound === prev.upper_bound && r.parent_txn_id > prev.parent_txn_id)) best.set(id, r);
    }
    frontier = [];
    for (const r of best.values()) {
      const row = { ...r, depth };
      found.get(r.key).set(r.txn_id, row);
      frontier.push(row);
    }
  }
  return new Map([...found].map(([k, m]) => [k, [...m.values()]]));
}

// The candidate trace from one disputed transfer, sorted like the PostgreSQL version.
export async function traceFrom(run, txnId) {
  const [root] = await run(ROOT_CYPHER, { txn: txnId });
  if (!root) return null;                       // not synced to Neo4j yet
  const rows = (await expandFromRoots(run, [{ ...root, key: 'trace' }])).get('trace');
  return rows.map(r => { const out = { ...r }; delete out.key; return out; })
             .sort((a, b) => a.depth - b.depth || Date.parse(a.occurred_at) - Date.parse(b.occurred_at));
}

// Accounts reached by the money of two or more open cases (same time rules as the trace).
export async function sharedMuleAccounts(run) {
  const roots = await run(OPEN_CASE_ROOTS_CYPHER, {});
  if (!roots.length) return [];
  const byCase = await expandFromRoots(run, roots);
  const casesByAccount = new Map();
  for (const [caseId, rows] of byCase) {
    for (const accountId of new Set(rows.map(r => r.to_id))) {
      if (!casesByAccount.has(accountId)) casesByAccount.set(accountId, new Set());
      casesByAccount.get(accountId).add(caseId);
    }
  }
  const shared = [...casesByAccount].filter(([, cs]) => cs.size >= 2);
  if (!shared.length) return [];
  const details = await run(
    'MATCH (a:Account) WHERE a.account_id IN $ids RETURN a.account_id AS account_id, a.account_ref AS account_ref, a.owner AS owner, a.balance AS balance',
    { ids: shared.map(([id]) => id) });
  const info = new Map(details.map(d => [d.account_id, d]));
  return shared
    .map(([id, cs]) => ({ ...info.get(id), account_id: id, case_ids: [...cs].sort((x, y) => x - y), case_count: cs.size }))
    .sort((a, b) => b.case_count - a.case_count || String(a.account_ref).localeCompare(String(b.account_ref)));
}
