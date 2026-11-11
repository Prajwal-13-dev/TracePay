// Fund tracing on the Neo4j transfer graph, with a PostgreSQL fallback.
//
// Neo4j only SUGGESTS where money went. Amounts are committed by confirm_link() in PostgreSQL,
// where the constraint engine (txn_capacity, node_outflow) enforces conservation.
import 'server-only';
import { cypher } from './neo4j';
import { query } from './db';

export type Candidate = {
  txn_id: number; ref: string; parent_txn_id: number | null; parent_ref: string | null; depth: number;
  from_id: number; from_ref: string; to_id: number; to_ref: string;
  amount: number; occurred_at: string; upper_bound: number; path: number[];
};
export type TraceResult = { source: 'neo4j' | 'postgres'; candidates: Candidate[] };

import { MAX_HOPS, WINDOW_HOURS, traceFrom, sharedMuleAccounts } from './graphQueries.mjs';
export { MAX_HOPS, WINDOW_HOURS };


// Each hop is one small Cypher query (see graphQueries.mjs for why).
const run = (text: string, params: Record<string, unknown>) => cypher(text, params);

async function traceNeo4j(txnId: number): Promise<Candidate[]> {
  const rows = await traceFrom(run, txnId);
  if (!rows) throw new Error(`transfer ${txnId} not in graph yet (is graph-sync running?)`);
  return rows as Candidate[];
}

async function tracePostgres(txnId: number): Promise<Candidate[]> {
  const rows = await query<Candidate>(
    `SELECT tc.txn_id::int, t.external_ref AS ref, tc.parent_txn_id::int, p.external_ref AS parent_ref, tc.depth,
            sa.account_id::int AS from_id, sa.account_ref AS from_ref, da.account_id::int AS to_id, da.account_ref AS to_ref,
            tc.amount::float8 AS amount, tc.occurred_at::text AS occurred_at, tc.upper_bound::float8 AS upper_bound,
            tc.path::int[] AS path
     FROM trace_candidates($1, $2::int, make_interval(hours => $3)) tc
     JOIN transactions t ON t.txn_id = tc.txn_id
     LEFT JOIN transactions p ON p.txn_id = tc.parent_txn_id
     JOIN accounts sa ON sa.account_id = tc.source_account_id
     JOIN accounts da ON da.account_id = tc.destination_account_id
     ORDER BY tc.depth, tc.occurred_at`, [txnId, MAX_HOPS, WINDOW_HOURS]);
  return rows;
}

// Neo4j first; if the graph service is down, the page still works from the recursive CTE.
export async function traceCandidates(txnId: number): Promise<TraceResult> {
  try {
    return { source: 'neo4j', candidates: await traceNeo4j(txnId) };
  } catch (e) {
    console.warn('Neo4j trace unavailable, using PostgreSQL CTE:', (e as Error).message);
    return { source: 'postgres', candidates: await tracePostgres(txnId) };
  }
}

export type SharedMule = { account_id: number; account_ref: string; owner: string | null; balance: number;
                           case_ids: number[]; case_count: number };

export async function sharedMules(): Promise<SharedMule[] | null> {
  try {
    return (await sharedMuleAccounts(run)) as SharedMule[];
  } catch (e) {
    console.warn('Neo4j shared-mule query unavailable:', (e as Error).message);
    return null;   // the UI shows "graph service offline"
  }
}
