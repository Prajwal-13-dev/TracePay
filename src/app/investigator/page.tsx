import Link from 'next/link';
import StatusBadge from '@/components/StatusBadge';
import { requirePageRole } from '@/lib/auth';
import { query } from '@/lib/db';
import { inr, when } from '@/lib/format';
import SharedMules from '@/components/SharedMules';

const PAGE = 25;
const TABS = [
  { key: 'mine', label: 'Assigned to me' },
  { key: 'open', label: 'All open' },
  { key: 'closed', label: 'Closed' },
] as const;
type Tab = typeof TABS[number]['key'];

export default async function InvestigatorQueue({ searchParams }: {
  searchParams: Promise<{ tab?: string; status?: string; priority?: string; min?: string; q?: string; page?: string }>;
}) {
  const user = await requirePageRole('INVESTIGATOR');
  const sp = await searchParams;
  const tab: Tab = TABS.some(t => t.key === sp.tab) ? sp.tab as Tab : 'mine';
  const statuses = await query<{ code: string; label: string; is_open: boolean }>('SELECT code, label, is_open FROM case_status ORDER BY sort_order');
  const page = Math.max(1, Number(sp.page) || 1);

  // Filters become parameters ($n), never string-concatenated values.
  const where: string[] = []; const params: unknown[] = [];
  const add = (sql: string, v: unknown) => { params.push(v); where.push(sql.replace('?', '$' + params.length)); };
  if (tab === 'mine') add('EXISTS (SELECT 1 FROM case_assignments a WHERE a.case_id = c.case_id AND a.ended_at IS NULL AND a.investigator_id = ?)', user.id);
  if (tab === 'open') where.push("c.status NOT IN ('CLOSED', 'REJECTED')");
  if (tab === 'closed') where.push("c.status IN ('CLOSED', 'REJECTED')");
  if (sp.status && statuses.some(s => s.code === sp.status)) add('c.status = ?', sp.status);
  if (sp.priority && /^[1-5]$/.test(sp.priority)) add('c.priority = ?', Number(sp.priority));
  if (sp.min && Number(sp.min) > 0) add('c.reported_amount >= ?', Number(sp.min));
  let rank = 'NULL::real', snippet = 'NULL::text', order = "CASE c.status WHEN 'UNDER_REVIEW' THEN 0 WHEN 'INVESTIGATING' THEN 1 ELSE 2 END, c.priority, c.created_at DESC";
  if (sp.q?.trim()) {
    params.push(sp.q.trim());
    const q = `websearch_to_tsquery('english', $${params.length})`;
    where.push(`c.search_vector @@ ${q}`);
    rank = `ts_rank_cd(c.search_vector, ${q}, 32)`;
    snippet = `ts_headline('english', c.narrative, ${q}, 'StartSel=<<, StopSel=>>, MaxWords=25')`;
    order = 'rank DESC';
  }
  params.push((page - 1) * PAGE);
  const rows = await query<{ case_id: string; status: string; priority: number; reported_amount: string; created_at: Date;
                             customer: string; txn_ref: string; investigator: string | null; rank: number | null; snippet: string | null; total: string }>(
    `SELECT c.case_id, c.status, c.priority, c.reported_amount, c.created_at, u.full_name AS customer,
            t.external_ref AS txn_ref, iu.full_name AS investigator, ${rank} AS rank, ${snippet} AS snippet, count(*) OVER () AS total
     FROM fraud_cases c JOIN users u ON u.user_id = c.customer_id JOIN transactions t ON t.txn_id = c.disputed_txn_id
     LEFT JOIN case_assignments ca ON ca.case_id = c.case_id AND ca.ended_at IS NULL
     LEFT JOIN users iu ON iu.user_id = ca.investigator_id
     ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
     ORDER BY ${order} LIMIT ${PAGE} OFFSET $${params.length}`, params);
  const total = Number(rows[0]?.total ?? 0);
  const pages = Math.max(1, Math.ceil(total / PAGE));
  const [counts] = await query<{ mine: number; open: number; closed: number }>(
    `SELECT count(*) FILTER (WHERE EXISTS (SELECT 1 FROM case_assignments a WHERE a.case_id = c.case_id AND a.ended_at IS NULL AND a.investigator_id = $1))::int AS mine,
            count(*) FILTER (WHERE c.status NOT IN ('CLOSED', 'REJECTED'))::int AS open,
            count(*) FILTER (WHERE c.status IN ('CLOSED', 'REJECTED'))::int AS closed
     FROM fraud_cases c`, [user.id]);
  const keep = { ...(sp.q ? { q: sp.q } : {}), ...(sp.status ? { status: sp.status } : {}), ...(sp.priority ? { priority: sp.priority } : {}), ...(sp.min ? { min: sp.min } : {}) };
  const link = (over: Record<string, string>) => '?' + new URLSearchParams({ tab, ...keep, ...over });

  return (
    <>
    <div className="card">
      <h2>Case queue</h2>
      <nav className="tabs" aria-label="Which cases">
        {TABS.map(t => (
          <Link key={t.key} href={'?' + new URLSearchParams({ tab: t.key })} className={t.key === tab ? 'on' : undefined}>
            {t.label}<span className="count">{counts[t.key]}</span>
          </Link>
        ))}
      </nav>
      <form className="filters" method="get">
        <input type="hidden" name="tab" value={tab} />
        <div style={{ flex: 2 }}><label>Keyword search</label><input name="q" defaultValue={sp.q} placeholder='courier "customs fee" -refund' /></div>
        <div><label>Status</label>
          <select name="status" defaultValue={sp.status ?? ''}>
            <option value="">Any</option>{statuses.filter(s => tab === 'closed' ? !s.is_open : tab === 'open' ? s.is_open : true)
              .map(s => <option key={s.code} value={s.code}>{s.label}</option>)}
          </select></div>
        <div><label>Priority</label>
          <select name="priority" defaultValue={sp.priority ?? ''}>
            <option value="">Any</option>{[1, 2, 3, 4, 5].map(p => <option key={p}>{p}</option>)}
          </select></div>
        <div><label>Min amount (₹)</label><input name="min" type="number" min="0" defaultValue={sp.min} /></div>
        <button className="secondary">Filter</button>
      </form>
      {tab === 'mine' && counts.mine === 0 && <p className="callout info">No cases are assigned to you right now. A supervisor assigns new cases; meanwhile you can browse <Link href="?tab=open">all open cases</Link>.</p>}
      <div className="table-wrap"><table style={{ marginTop: 16 }}>
        <thead><tr><th>Case</th><th>Customer</th><th>Transfer</th><th>Amount</th><th>Priority</th><th>Status</th>{tab !== 'mine' && <th>Investigator</th>}<th>Filed</th>{sp.q && <th>Match</th>}</tr></thead>
        <tbody>
          {rows.map(r => (
            <tr key={r.case_id} className="clickable">
              <td><Link href={`/investigator/cases/${r.case_id}`}>#{r.case_id}</Link></td>
              <td>{r.customer}</td><td>{r.txn_ref}</td><td>{inr(r.reported_amount)}</td><td><span className={`prio prio-${r.priority}`}>{r.priority}</span></td>
              <td><StatusBadge status={r.status} />{tab === 'mine' && r.status === 'UNDER_REVIEW' && <div className="muted">waiting for you to accept</div>}</td>
              {tab !== 'mine' && <td>{r.investigator ?? <span className="muted">unassigned</span>}</td>}
              <td>{when(r.created_at)}</td>
              {sp.q && <td className="muted">{r.snippet} ({Number(r.rank).toFixed(3)})</td>}
            </tr>
          ))}
          {rows.length === 0 && <tr><td colSpan={9} className="muted">No cases match.</td></tr>}
        </tbody>
      </table></div>
      {pages > 1 && (
        <div className="pager">
          {page > 1 ? <Link className="btn secondary" href={link({ page: String(page - 1) })}>← Previous</Link> : <span />}
          <span className="muted">Page {page} of {pages} · {total} cases</span>
          {page < pages ? <Link className="btn secondary" href={link({ page: String(page + 1) })}>Next →</Link> : <span />}
        </div>
      )}
    </div>
    <SharedMules />
    </>
  );
}
