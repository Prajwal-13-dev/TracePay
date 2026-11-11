import Link from 'next/link';
import { requirePageRole } from '@/lib/auth';
import { query } from '@/lib/db';
import { inr, when } from '@/lib/format';
import ActionForm from '@/components/ActionForm';
import StatusBadge from '@/components/StatusBadge';
import CaseTimeline from '@/components/CaseTimeline';

// What each status means for the customer, in plain words.
const NEXT: Record<string, string> = {
  SUBMITTED: 'We have your complaint. A supervisor will review it shortly.',
  UNDER_REVIEW: 'A supervisor is reviewing your complaint and assigning an investigator.',
  INVESTIGATING: 'An investigator is tracing where your money went and asking for it to be frozen.',
  RECOVERY: 'Your loss is verified. Frozen money is being shared out and refunded.',
  CLOSED: 'This complaint is closed.',
  REJECTED: 'This complaint was not accepted. Contact support if you think this is a mistake.',
};

export default async function CustomerHome() {
  const user = await requirePageRole('CUSTOMER');
  // Every query filters by the signed-in customer: other customers' data is never selected.
  const cases = await query<{ case_id: string; txn_ref: string; to_ref: string; reported_amount: string; status: string;
                              verified_loss: string | null; refunded: string; created_at: Date }>(
    `SELECT c.case_id, t.external_ref AS txn_ref, d.account_ref AS to_ref, c.reported_amount, c.status, c.verified_loss, c.created_at,
            COALESCE((SELECT SUM(r.amount) FROM refunds r JOIN recovery_allocations a USING (allocation_id)
                      WHERE a.case_id = c.case_id AND r.status = 'PROCESSED'), 0) AS refunded
     FROM fraud_cases c JOIN transactions t ON t.txn_id = c.disputed_txn_id
     JOIN accounts d ON d.account_id = t.destination_account_id
     WHERE c.customer_id = $1 ORDER BY c.created_at DESC`, [user.id]);
  const history = await query<{ case_id: string; to_status: string; changed_at: Date; note: string | null }>(
    `SELECT h.case_id, h.to_status, h.changed_at, h.note FROM case_status_history h
     JOIN fraud_cases c USING (case_id) WHERE c.customer_id = $1 ORDER BY h.changed_at`, [user.id]);
  const drafts = await query<{ draft_id: string; txn_ref: string | null; narrative: string; created_at: Date;
                               reported_amount: string | null; scam_type: string | null }>(
    `SELECT d.draft_id, t.external_ref AS txn_ref, d.narrative, d.created_at, d.reported_amount, d.scam_type
     FROM draft_complaints d LEFT JOIN transactions t ON t.txn_id = d.disputed_txn_id
     WHERE d.customer_id = $1 ORDER BY d.created_at DESC`, [user.id]);
  const accounts = await query<{ account_ref: string; balance: string; frozen: string; status: string; ifsc: string | null }>(
    `SELECT a.account_ref, a.balance, a.status, a.ifsc,
            COALESCE((SELECT SUM(f.frozen_amount) FROM account_freezes f WHERE f.account_id = a.account_id AND f.status = 'ACTIVE'), 0) AS frozen
     FROM accounts a WHERE a.user_id = $1 ORDER BY a.account_ref`, [user.id]);
  // Money in and out of the customer's accounts, newest first. Refund payments (RECOVERY) are shown, never reportable.
  const transfers = await query<{ txn_id: string; external_ref: string; direction: 'in' | 'out'; other_ref: string; other_owner: string;
                                  amount: string; channel: string; occurred_at: Date; case_id: string | null }>(
    `SELECT t.txn_id, t.external_ref, CASE WHEN s.user_id = $1 THEN 'out' ELSE 'in' END AS direction,
            CASE WHEN s.user_id = $1 THEN d.account_ref ELSE s.account_ref END AS other_ref,
            CASE WHEN s.user_id = $1 THEN du.full_name ELSE su.full_name END AS other_owner,
            t.amount, t.channel, t.occurred_at, c.case_id
     FROM transactions t
     JOIN accounts s ON s.account_id = t.source_account_id JOIN users su ON su.user_id = s.user_id
     JOIN accounts d ON d.account_id = t.destination_account_id JOIN users du ON du.user_id = d.user_id
     LEFT JOIN fraud_cases c ON c.disputed_txn_id = t.txn_id
     WHERE (s.user_id = $1 OR d.user_id = $1) AND NOT (s.user_id = $1 AND d.user_id = $1)
     ORDER BY t.occurred_at DESC LIMIT 100`, [user.id]);

  const totalLost = cases.reduce((s, c) => s + Number(c.reported_amount), 0);
  const totalBack = cases.reduce((s, c) => s + Number(c.refunded), 0);
  const open = cases.filter(c => !['CLOSED', 'REJECTED'].includes(c.status)).length;

  return (
    <>
      <div className="page-head">
        <div><h1>My complaints</h1><p>Follow each complaint from filing to refund.</p></div>
        <div className="inline-actions">
          <Link className="btn secondary" href="/customer/send">Send money</Link>
          <Link className="btn" href="/customer/new">+ Report a fraudulent transfer</Link>
        </div>
      </div>

      <div className="card">
        <div className="card-head"><h2>My accounts</h2><Link href="/customer/send">Send money →</Link></div>
        {accounts.length === 0 ? <p className="muted">You have no bank account yet. Ask a supervisor to open one.</p> : (
          <div className="grid">{accounts.map(a => (
            <div className="stat" key={a.account_ref}>
              <span className="muted">{a.account_ref}{a.ifsc && ` · IFSC ${a.ifsc}`}{a.status !== 'ACTIVE' && ' · closed'}</span>
              <b>{inr(a.balance)}</b>
              <small>{Number(a.frozen) > 0 ? `${inr(a.frozen)} frozen · ${inr(Number(a.balance) - Number(a.frozen))} available` : 'All available'}</small>
            </div>
          ))}</div>
        )}
      </div>

      <div className="grid" style={{ marginBottom: 20 }}>
        <div className="stat t-accent"><span className="muted">Open complaints</span><b>{open}</b></div>
        <div className="stat t-warn"><span className="muted">Reported lost</span><b>{inr(totalLost)}</b></div>
        <div className="stat t-ok"><span className="muted">Refunded to you</span><b>{inr(totalBack)}</b>
          {totalLost > 0 && <small>{Math.round(100 * totalBack / totalLost)}% of what you reported</small>}</div>
      </div>

      <div className="card">
        {cases.length === 0 ? (
          <div className="empty"><b>No complaints yet</b>If you were tricked into sending money, report it here as soon as possible.
            <p><Link className="btn" href="/customer/new">Report a fraudulent transfer</Link></p></div>
        ) : (
          <div className="case-list">
            {cases.map(c => {
              const base = Number(c.verified_loss ?? c.reported_amount);
              const pct = base > 0 ? Math.min(100, Math.round(100 * Number(c.refunded) / base)) : 0;
              return (
                <div className="case-card" key={c.case_id}>
                  <div className="top">
                    <div><div className="title">Complaint #{c.case_id}</div>
                      <div className="sub">Transfer {c.txn_ref} to {c.to_ref} · filed {when(c.created_at)}</div></div>
                    <StatusBadge status={c.status} />
                  </div>
                  <CaseTimeline status={c.status} createdAt={c.created_at} history={history.filter(h => h.case_id === c.case_id)} />
                  <div className="note">{NEXT[c.status]}</div>
                  {(() => {
                    const n = history.filter(h => h.case_id === c.case_id && h.to_status === c.status && h.note).at(-1);
                    return n && ['REJECTED', 'CLOSED'].includes(c.status)
                      ? <div className="callout info" style={{ marginTop: 8 }}><b>Message from TracePay:</b> {n.note}</div> : null;
                  })()}
                  <div className="money">
                    <div><span className="muted">Reported</span><b>{inr(c.reported_amount)}</b></div>
                    <div><span className="muted">Verified loss</span><b>{c.verified_loss ? inr(c.verified_loss) : 'Pending'}</b></div>
                    <div style={{ flex: 1, minWidth: 200 }}><span className="muted">Refunded</span><b>{inr(c.refunded)}</b>
                      <div className="progress" style={{ marginTop: 6 }} aria-label={`${pct}% refunded`}><span style={{ width: pct + '%' }} /></div></div>
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>

      {drafts.length > 0 && (
        <div className="card">
          <h2>Unfinished drafts</h2>
          <div className="table-wrap"><table>
            <thead><tr><th>Saved</th><th>Transfer</th><th>Amount / type</th><th>Description so far</th><th></th></tr></thead>
            <tbody>{drafts.map(d => (
              <tr key={d.draft_id}>
                <td>{when(d.created_at)}</td><td>{d.txn_ref ?? '—'}</td>
                <td>{d.reported_amount ? inr(d.reported_amount) : '—'}{d.scam_type && <div className="muted">{d.scam_type}</div>}</td>
                <td style={{ maxWidth: 380 }}>{d.narrative ? d.narrative.slice(0, 140) + (d.narrative.length > 140 ? '…' : '') : <span className="muted">(empty)</span>}</td>
                <td style={{ whiteSpace: 'nowrap' }}>
                  <Link className="btn secondary" href={`/customer/new?draft=${d.draft_id}`}>Continue</Link>{' '}
                  <ActionForm inline endpoint={`/api/drafts/${d.draft_id}`} method="DELETE" submit="Delete" variant="ghost" confirm="Delete this draft?" />
                </td>
              </tr>
            ))}</tbody>
          </table></div>
        </div>
      )}

      <div className="card">
        <h2>My transfers</h2>
        <div className="table-wrap"><table>
          <thead><tr><th>Ref</th><th></th><th>Other account</th><th>Amount</th><th>When</th><th>Complaint</th></tr></thead>
          <tbody>
            {transfers.map(t => (
              <tr key={t.txn_id}>
                <td>{t.external_ref}</td>
                <td>{t.channel === 'RECOVERY' ? <span className="badge s-PAID">Refund</span>
                  : t.direction === 'out' ? <span className="badge s-SUBMITTED">Sent</span> : <span className="badge s-ACTIVE">Received</span>}</td>
                <td>{t.other_ref}<div className="muted">{t.other_owner}</div></td>
                <td style={{ color: t.direction === 'in' ? 'var(--ok)' : undefined }}>{t.direction === 'in' ? '+' : '−'}{inr(t.amount)}</td>
                <td>{when(t.occurred_at)}</td>
                <td>{t.case_id ? `#${t.case_id}`
                  : t.direction === 'out' && t.channel !== 'RECOVERY' ? <Link href={`/customer/new?txn=${t.txn_id}`}>Report</Link> : ''}</td>
              </tr>
            ))}
            {transfers.length === 0 && <tr><td colSpan={6} className="empty">No transfers on your accounts.</td></tr>}
          </tbody>
        </table></div>
      </div>
    </>
  );
}
