// Everything the interactive trace graph needs for one case:
// candidate paths (Neo4j, or the CTE fallback) overlaid with what PostgreSQL has confirmed.
import 'server-only';
import { query } from './db';
import { traceCandidates, Candidate } from './graph';

export type GraphAccount = { id: number; ref: string; owner: string; balance: number; frozen: number;
                             isVictim: boolean; isRoot: boolean; sharedCases: number };
export type GraphEdge = Candidate & {
  confirmed_inflow: number;      // this case's confirmed inflow on this transfer (0 = not confirmed)
  all_cases_inflow: number;      // every case's confirmed inflow (txn_capacity uses this)
  remaining_capacity: number;    // amount - all_cases_inflow
  parent_confirmed: boolean;     // a link can be confirmed only from a confirmed node
  parent_outflow_left: number;   // parent inflow minus what already left it (node_outflow)
};
export type CaseTraceGraph = { source: 'neo4j' | 'postgres'; accounts: GraphAccount[]; edges: GraphEdge[] };

export async function caseTraceGraph(caseId: number, disputedTxnId: number): Promise<CaseTraceGraph> {
  const { source, candidates } = await traceCandidates(disputedTxnId);
  const txnIds = candidates.map(c => c.txn_id);
  const accIds = [...new Set(candidates.flatMap(c => [c.from_id, c.to_id]))];

  const [nodes, accounts] = await Promise.all([
    query<{ txn_id: number; mine: number; all_cases: number; out_left: number }>(
      `SELECT t.txn_id::int,
              COALESCE(SUM(n.inflow_amount) FILTER (WHERE n.case_id = $1), 0)::float8 AS mine,
              COALESCE(SUM(n.inflow_amount), 0)::float8 AS all_cases,
              COALESCE(MAX(n.inflow_amount) FILTER (WHERE n.case_id = $1)
                - (SELECT COALESCE(SUM(l.attributed_amount), 0) FROM fund_flow_links l
                   JOIN trace_nodes x ON x.node_id = l.from_node_id
                   WHERE x.case_id = $1 AND x.txn_id = t.txn_id), 0)::float8 AS out_left
       FROM transactions t LEFT JOIN trace_nodes n ON n.txn_id = t.txn_id
       WHERE t.txn_id = ANY($2) GROUP BY t.txn_id`, [caseId, txnIds]),
    query<{ id: number; ref: string; owner: string; balance: number; frozen: number; shared: number }>(
      `SELECT a.account_id::int AS id, a.account_ref AS ref, u.full_name AS owner, a.balance::float8 AS balance,
              COALESCE((SELECT SUM(f.frozen_amount) FROM account_freezes f
                        WHERE f.account_id = a.account_id AND f.status = 'ACTIVE'), 0)::float8 AS frozen,
              (SELECT count(DISTINCT n.case_id) FROM trace_nodes n JOIN transactions t ON t.txn_id = n.txn_id
               WHERE t.destination_account_id = a.account_id)::int AS shared
       FROM accounts a JOIN users u USING (user_id) WHERE a.account_id = ANY($1)`, [accIds]),
  ]);

  const byTxn = new Map(nodes.map(n => [n.txn_id, n]));
  const root = candidates.find(c => c.depth === 0);
  const edges: GraphEdge[] = candidates.map(c => {
    const n = byTxn.get(c.txn_id);
    const p = c.parent_txn_id ? byTxn.get(c.parent_txn_id) : undefined;
    return {
      ...c,
      confirmed_inflow: n?.mine ?? 0,
      all_cases_inflow: n?.all_cases ?? 0,
      remaining_capacity: Math.max(0, c.amount - (n?.all_cases ?? 0)),
      parent_confirmed: !!p && p.mine > 0,
      parent_outflow_left: Math.max(0, p?.out_left ?? 0),
    };
  });

  return {
    source,
    edges,
    accounts: accounts.map(a => ({
      id: a.id, ref: a.ref, owner: a.owner, balance: a.balance, frozen: a.frozen,
      isVictim: a.id === root?.from_id, isRoot: a.id === root?.to_id, sharedCases: a.shared,
    })),
  };
}
