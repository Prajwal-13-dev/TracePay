import { requirePageRole } from '@/lib/auth';
import { query } from '@/lib/db';
import { inr, when } from '@/lib/format';
import SendMoneyForm from '@/components/SendMoneyForm';

const PAGE = 50;

export default async function Transactions({ searchParams }: { searchParams: Promise<{ q?: string; channel?: string; page?: string }> }) {
  await requirePageRole('SUPERVISOR');
  const sp = await searchParams;
  const q = sp.q?.trim().toUpperCase() || null;
  const channel = ['UPI', 'IMPS', 'NEFT', 'CARD', 'RECOVERY'].includes(sp.channel ?? '') ? sp.channel! : null;
  const page = Math.max(1, Number(sp.page) || 1);
  const rows = await query<{ txn_id: string; external_ref: string; from_ref: string; from_owner: string; to_ref: string; to_owner: string;
    amount: string; channel: string; occurred_at: Date; case_id: string | null; total: string }>(
    `SELECT t.txn_id, t.external_ref, s.account_ref AS from_ref, su.full_name AS from_owner, d.account_ref AS to_ref, du.full_name AS to_owner,
            t.amount, t.channel, t.occurred_at, c.case_id, count(*) OVER () AS total
     FROM transactions t
     JOIN accounts s ON s.account_id = t.source_account_id JOIN users su ON su.user_id = s.user_id
     JOIN accounts d ON d.account_id = t.destination_account_id JOIN users du ON du.user_id = d.user_id
     LEFT JOIN fraud_cases c ON c.disputed_txn_id = t.txn_id
     WHERE ($1::text IS NULL OR t.external_ref ILIKE '%' || $1 || '%' OR s.account_ref = $1 OR d.account_ref = $1)
       AND ($2::text IS NULL OR t.channel = $2)
     ORDER BY t.occurred_at DESC, t.txn_id DESC LIMIT ${PAGE} OFFSET $3`, [q, channel, (page - 1) * PAGE]);
  const total = Number(rows[0]?.total ?? 0);
  const pages = Math.max(1, Math.ceil(total / PAGE));
  const link = (p: number) => `?${new URLSearchParams({ ...(q ? { q } : {}), ...(channel ? { channel } : {}), page: String(p) })}`;

  return (
    <>
      <div className="page-head"><div><h1>Transactions</h1>
        <p>Record a transfer between any two accounts (for example to build a laundering chain for a demo) and browse every transfer.</p></div></div>
      <div className="card">
        <h2>Record a transfer</h2>
        <p className="muted">Balances move at once. Leave the date empty for &quot;now&quot;, or pick a past time to place it in a chain. Frozen money cannot be moved.</p>
        <SendMoneyForm supervisor />
      </div>
      <div className="card">
        <div className="card-head"><h2>All transfers</h2><span className="muted">{total} found</span></div>
        <form className="filters" method="get">
          <div><label>Reference or account</label><input name="q" defaultValue={q ?? ''} placeholder="T1, TX…, TP1000000003" /></div>
          <div><label>Channel</label>
            <select name="channel" defaultValue={channel ?? ''}>
              <option value="">Any</option>{['UPI', 'IMPS', 'NEFT', 'CARD', 'RECOVERY'].map(c => <option key={c}>{c}</option>)}
            </select></div>
          <button className="secondary">Filter</button>
        </form>
        <div className="table-wrap"><table style={{ marginTop: 16 }}>
          <thead><tr><th>Ref</th><th>From</th><th>To</th><th>Amount</th><th>Channel</th><th>When</th><th>Complaint</th></tr></thead>
          <tbody>{rows.map(r => (
            <tr key={r.txn_id}>
              <td>{r.external_ref}</td>
              <td>{r.from_ref}<div className="muted">{r.from_owner}</div></td>
              <td>{r.to_ref}<div className="muted">{r.to_owner}</div></td>
              <td>{inr(r.amount)}</td>
              <td>{r.channel === 'RECOVERY' ? <span className="badge s-PAID">Recovery</span> : r.channel}</td>
              <td>{when(r.occurred_at)}</td>
              <td>{r.case_id ? <a href={`/supervisor/cases/${r.case_id}`}>#{r.case_id}</a> : '—'}</td>
            </tr>
          ))}
          {rows.length === 0 && <tr><td colSpan={7} className="empty">No transfers match.</td></tr>}</tbody>
        </table></div>
        {pages > 1 && (
          <div className="pager">
            {page > 1 ? <a className="btn secondary" href={link(page - 1)}>← Newer</a> : <span />}
            <span className="muted">Page {page} of {pages}</span>
            {page < pages ? <a className="btn secondary" href={link(page + 1)}>Older →</a> : <span />}
          </div>
        )}
      </div>
    </>
  );
}
