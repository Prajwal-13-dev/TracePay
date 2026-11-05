import Link from 'next/link';
import { requirePageRole } from '@/lib/auth';
import { query } from '@/lib/db';
import { inr, when } from '@/lib/format';

const STATUSES = ['SUBMITTED', 'UNDER_REVIEW', 'INVESTIGATING', 'RECOVERY', 'CLOSED', 'REJECTED'];

export default async function InvestigatorQueue({ searchParams }: {
  searchParams: Promise<{ status?: string; priority?: string; min?: string; q?: string; mine?: string }>;
}) {
  const user = await requirePageRole('INVESTIGATOR');
  const sp = await searchParams;
  const mine = sp.mine !== '0';
  // Filters become parameters ($n), never string-concatenated values.
  const where: string[] = []; const params: unknown[] = [];
  const add = (sql: string, v: unknown) => { params.push(v); where.push(sql.replace('?', '$' + params.length)); };
  if (mine) add('EXISTS (SELECT 1 FROM case_assignments a WHERE a.case_id = c.case_id AND a.ended_at IS NULL AND a.investigator_id = ?)', user.id);
  if (sp.status && STATUSES.includes(sp.status)) add('c.status = ?', sp.status);
  if (sp.priority && /^[1-5]$/.test(sp.priority)) add('c.priority = ?', Number(sp.priority));
  if (sp.min && Number(sp.min) > 0) add('c.reported_amount >= ?', Number(sp.min));
  let rank = 'NULL::real', snippet = 'NULL::text', order = 'c.priority, c.created_at DESC';
  if (sp.q?.trim()) {
    params.push(sp.q.trim());
    const q = `websearch_to_tsquery('english', $${params.length})`;
    where.push(`c.search_vector @@ ${q}`);
    rank = `ts_rank_cd(c.search_vector, ${q}, 32)`;
    snippet = `ts_headline('english', c.narrative, ${q}, 'StartSel=<<, StopSel=>>, MaxWords=25')`;
    order = 'rank DESC';
  }
  const rows = await query<{ case_id: string; status: string; priority: number; reported_amount: string;
                             created_at: Date; customer: string; txn_ref: string; rank: number | null; snippet: string | null }>(
    `SELECT c.case_id, c.status, c.priority, c.reported_amount, c.created_at, u.full_name AS customer,
            t.external_ref AS txn_ref, ${rank} AS rank, ${snippet} AS snippet
     FROM fraud_cases c JOIN users u ON u.user_id = c.customer_id JOIN transactions t ON t.txn_id = c.disputed_txn_id
     ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
     ORDER BY ${order} LIMIT 50`, params);

  return (
    <div className="card">
      <h2>Case queue</h2>
      <form className="filters" method="get">
        <div><label>Keyword search</label><input name="q" defaultValue={sp.q} placeholder='courier "customs fee" -refund' /></div>
        <div><label>Status</label>
          <select name="status" defaultValue={sp.status ?? ''}>
            <option value="">Any</option>{STATUSES.map(s => <option key={s}>{s}</option>)}
          </select></div>
        <div><label>Priority</label>
          <select name="priority" defaultValue={sp.priority ?? ''}>
            <option value="">Any</option>{[1, 2, 3, 4, 5].map(p => <option key={p}>{p}</option>)}
          </select></div>
        <div><label>Min amount (₹)</label><input name="min" type="number" defaultValue={sp.min} /></div>
        <div><label>Show</label>
          <select name="mine" defaultValue={mine ? '1' : '0'}>
            <option value="1">Assigned to me</option><option value="0">All cases</option>
          </select></div>
        <button>Filter</button>
      </form>
      <table style={{ marginTop: 16 }}>
        <thead><tr><th>Case</th><th>Customer</th><th>Transfer</th><th>Amount</th><th>Priority</th><th>Status</th><th>Filed</th>{sp.q && <th>Match</th>}</tr></thead>
        <tbody>
          {rows.map(r => (
            <tr key={r.case_id}>
              <td><Link href={`/investigator/cases/${r.case_id}`}>#{r.case_id}</Link></td>
              <td>{r.customer}</td><td>{r.txn_ref}</td><td>{inr(r.reported_amount)}</td><td>{r.priority}</td>
              <td><span className="badge">{r.status}</span></td><td>{when(r.created_at)}</td>
              {sp.q && <td className="muted">{r.snippet} ({Number(r.rank).toFixed(3)})</td>}
            </tr>
          ))}
          {rows.length === 0 && <tr><td colSpan={8} className="muted">No cases match.</td></tr>}
        </tbody>
      </table>
    </div>
  );
}
