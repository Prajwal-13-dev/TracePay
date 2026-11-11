// Supervisor case list: search, filter, sort and page through cases. Decisions are made on each case's page.
import Link from 'next/link';
import StatusBadge from '@/components/StatusBadge';
import { requirePageRole } from '@/lib/auth';
import { query } from '@/lib/db';
import { inr, when } from '@/lib/format';

const PAGE = 25;
const SORTS: Record<string, string> = {
  priority: 'c.priority, c.created_at DESC',
  newest: 'c.created_at DESC',
  oldest: 'c.created_at',
  amount: 'c.reported_amount DESC',
};

type SP = { status?: string; priority?: string; q?: string; assigned?: string; sort?: string; page?: string };

export default async function SupervisorCases({ searchParams }: { searchParams: Promise<SP> }) {
  await requirePageRole('SUPERVISOR');
  const sp = await searchParams;
  const statuses = await query<{ code: string; label: string }>('SELECT code, label FROM case_status ORDER BY sort_order');
  const status = statuses.some(s => s.code === sp.status) ? sp.status! : null;
  const priority = /^[1-5]$/.test(sp.priority ?? '') ? Number(sp.priority) : null;
  const q = sp.q?.trim() || null;
  const assigned = sp.assigned === 'yes' || sp.assigned === 'no' ? sp.assigned : null;
  const sort = SORTS[sp.sort ?? ''] ? sp.sort! : 'priority';
  const page = Math.max(1, Number(sp.page) || 1);

  // Filters are parameters ($n), never string-concatenated values. A number in the search box finds that case id.
  const cases = await query<{ case_id: string; status: string; priority: number; reported_amount: string; verified_loss: string | null;
    customer: string; txn_ref: string; investigator: string | null; created_at: Date; total: string }>(
    `SELECT c.case_id, c.status, c.priority, c.reported_amount, c.verified_loss, c.created_at,
            u.full_name AS customer, t.external_ref AS txn_ref, i.full_name AS investigator, count(*) OVER () AS total
     FROM fraud_cases c
     JOIN users u ON u.user_id = c.customer_id
     JOIN transactions t ON t.txn_id = c.disputed_txn_id
     LEFT JOIN case_assignments a ON a.case_id = c.case_id AND a.ended_at IS NULL
     LEFT JOIN users i ON i.user_id = a.investigator_id
     WHERE ($1::text IS NULL OR c.status = $1)
       AND ($2::int IS NULL OR c.priority = $2)
       AND ($3::text IS NULL OR c.search_vector @@ websearch_to_tsquery('english', $3) OR u.full_name ILIKE '%' || $3 || '%'
            OR t.external_ref ILIKE $3 OR c.case_id::text = $3)
       AND ($4::text IS NULL OR ($4 = 'yes') = (a.case_id IS NOT NULL))
     ORDER BY ${SORTS[sort]} LIMIT ${PAGE} OFFSET $5`, [status, priority, q, assigned, (page - 1) * PAGE]);
  const total = Number(cases[0]?.total ?? 0);
  const pages = Math.max(1, Math.ceil(total / PAGE));
  const base = { ...(status ? { status } : {}), ...(priority ? { priority: String(priority) } : {}), ...(q ? { q } : {}),
                 ...(assigned ? { assigned } : {}), sort };
  const link = (over: Record<string, string>) => '?' + new URLSearchParams({ ...base, ...over });

  return (
    <div className="card">
      <div className="card-head"><h2>Cases</h2><span className="muted">{total} found</span></div>
      <form className="filters" method="get">
        <div style={{ flex: 2 }}><label>Search</label><input name="q" defaultValue={q ?? ''} placeholder='Case #, customer, transfer ref or words: courier "customs fee"' /></div>
        <div><label>Status</label>
          <select name="status" defaultValue={status ?? ''}>
            <option value="">Any</option>{statuses.map(s => <option key={s.code} value={s.code}>{s.label}</option>)}
          </select></div>
        <div><label>Priority</label>
          <select name="priority" defaultValue={priority ?? ''}>
            <option value="">Any</option>{[1, 2, 3, 4, 5].map(p => <option key={p}>{p}</option>)}
          </select></div>
        <div><label>Investigator</label>
          <select name="assigned" defaultValue={assigned ?? ''}>
            <option value="">Any</option><option value="yes">Assigned</option><option value="no">Unassigned</option>
          </select></div>
        <div><label>Sort by</label>
          <select name="sort" defaultValue={sort}>
            <option value="priority">Priority</option><option value="newest">Newest</option><option value="oldest">Oldest</option><option value="amount">Largest amount</option>
          </select></div>
        <button className="secondary">Apply</button>
      </form>
      <div className="table-wrap"><table style={{ marginTop: 16 }}>
        <thead><tr><th>Case</th><th>Customer / transfer</th><th>Reported</th><th>Verified</th><th>Status</th><th>Investigator</th><th>Filed</th></tr></thead>
        <tbody>{cases.map(c => (
          <tr key={c.case_id} className="clickable">
            <td><Link href={`/supervisor/cases/${c.case_id}`}>#{c.case_id}</Link> <span className={`prio prio-${c.priority}`} title="Priority">{c.priority}</span></td>
            <td>{c.customer}<div className="muted">{c.txn_ref}</div></td>
            <td>{inr(c.reported_amount)}</td>
            <td>{inr(c.verified_loss)}</td>
            <td><StatusBadge status={c.status} /></td>
            <td>{c.investigator ?? <span className="muted">unassigned</span>}</td>
            <td>{when(c.created_at)}</td>
          </tr>
        ))}
        {cases.length === 0 && <tr><td colSpan={7} className="empty">No cases match.</td></tr>}</tbody>
      </table></div>
      {pages > 1 && (
        <div className="pager">
          {page > 1 ? <Link className="btn secondary" href={link({ page: String(page - 1) })}>← Previous</Link> : <span />}
          <span className="muted">Page {page} of {pages}</span>
          {page < pages ? <Link className="btn secondary" href={link({ page: String(page + 1) })}>Next →</Link> : <span />}
        </div>
      )}
    </div>
  );
}
