import { requirePageRole } from '@/lib/auth';
import { query } from '@/lib/db';
import { inr, when } from '@/lib/format';
import ActionForm from '@/components/ActionForm';

export default async function CustomerHome() {
  const user = await requirePageRole('CUSTOMER');
  // Every query filters by the signed-in customer: other customers' data is never selected.
  const transfers = await query<{ txn_id: string; external_ref: string; to_ref: string; amount: string;
                                  occurred_at: Date; case_id: string | null }>(
    `SELECT t.txn_id, t.external_ref, d.account_ref AS to_ref, t.amount, t.occurred_at, c.case_id
     FROM transactions t
     JOIN accounts s ON s.account_id = t.source_account_id
     JOIN accounts d ON d.account_id = t.destination_account_id
     LEFT JOIN fraud_cases c ON c.disputed_txn_id = t.txn_id
     WHERE s.user_id = $1 ORDER BY t.occurred_at DESC`, [user.id]);
  const drafts = await query<{ draft_id: string; txn_ref: string | null; disputed_txn_id: string | null;
                               narrative: string; created_at: Date }>(
    `SELECT d.draft_id, t.external_ref AS txn_ref, d.disputed_txn_id, d.narrative, d.created_at
     FROM draft_complaints d LEFT JOIN transactions t ON t.txn_id = d.disputed_txn_id
     WHERE d.customer_id = $1 ORDER BY d.created_at DESC`, [user.id]);
  const cases = await query<{ case_id: string; txn_ref: string; reported_amount: string; status: string;
                              verified_loss: string | null; refunded: string; created_at: Date; last_change: Date | null }>(
    `SELECT c.case_id, t.external_ref AS txn_ref, c.reported_amount, c.status, c.verified_loss, c.created_at,
            COALESCE((SELECT SUM(r.amount) FROM refunds r JOIN recovery_allocations a USING (allocation_id)
                      WHERE a.case_id = c.case_id AND r.status = 'PROCESSED'), 0) AS refunded,
            (SELECT MAX(changed_at) FROM case_status_history h WHERE h.case_id = c.case_id) AS last_change
     FROM fraud_cases c JOIN transactions t ON t.txn_id = c.disputed_txn_id
     WHERE c.customer_id = $1 ORDER BY c.created_at DESC`, [user.id]);

  const reportable = transfers.filter(t => !t.case_id)
    .map(t => ({ value: t.txn_id, label: `${t.external_ref} · ${inr(t.amount)} to ${t.to_ref}` }));

  return (
    <>
      <div className="card">
        <h2>My cases</h2>
        <table>
          <thead><tr><th>Case</th><th>Transfer</th><th>Reported</th><th>Status</th><th>Verified loss</th><th>Refunded</th><th>Updated</th></tr></thead>
          <tbody>
            {cases.map(c => (
              <tr key={c.case_id}>
                <td>#{c.case_id}</td><td>{c.txn_ref}</td><td>{inr(c.reported_amount)}</td>
                <td><span className="badge">{c.status}</span></td><td>{inr(c.verified_loss)}</td>
                <td>{inr(c.refunded)}</td><td>{when(c.last_change ?? c.created_at)}</td>
              </tr>
            ))}
            {cases.length === 0 && <tr><td colSpan={7} className="muted">No complaints yet.</td></tr>}
          </tbody>
        </table>
      </div>

      <div className="card">
        <h2>Report a fraudulent transfer</h2>
        {reportable.length === 0 ? <p className="muted">Every transfer you made already has a case.</p> : (
          <ActionForm endpoint="/api/cases" submit="Submit complaint" fields={[
            { name: 'disputedTxnId', label: 'Transfer', type: 'select', options: reportable, required: true },
            { name: 'reportedAmount', label: 'Amount lost (₹)', type: 'number', required: true },
            { name: 'narrative', label: 'What happened? (30+ characters)', type: 'textarea', required: true },
          ]} />
        )}
        <h3>…or save a draft</h3>
        <ActionForm endpoint="/api/drafts" submit="Save draft" fields={[
          { name: 'disputedTxnId', label: 'Transfer (optional)', type: 'select',
            options: [{ value: '', label: '—' }, ...reportable] },
          { name: 'narrative', label: 'Notes so far', type: 'textarea' },
        ]} />
      </div>

      <div className="card">
        <h2>My drafts</h2>
        <table>
          <thead><tr><th>Draft</th><th>Transfer</th><th>Narrative</th><th>Submit</th><th></th></tr></thead>
          <tbody>
            {drafts.map(d => (
              <tr key={d.draft_id}>
                <td>#{d.draft_id}<div className="muted">{when(d.created_at)}</div></td>
                <td>{d.txn_ref ?? '—'}</td>
                <td style={{ maxWidth: 320 }}>{d.narrative || <span className="muted">(empty)</span>}</td>
                <td>
                  {d.disputed_txn_id ? (
                    <ActionForm inline endpoint="/api/cases" submit="Submit" extra={{
                      disputedTxnId: Number(d.disputed_txn_id), narrative: d.narrative, draftId: Number(d.draft_id) }}
                      fields={[{ name: 'reportedAmount', label: 'Amount (₹)', type: 'number', required: true }]} />
                  ) : <span className="muted">pick a transfer first</span>}
                </td>
                <td><ActionForm inline endpoint={`/api/drafts/${d.draft_id}`} method="DELETE" submit="Delete"
                                confirm="Delete this draft?" /></td>
              </tr>
            ))}
            {drafts.length === 0 && <tr><td colSpan={5} className="muted">No drafts.</td></tr>}
          </tbody>
        </table>
      </div>

      <div className="card">
        <h2>My transfers</h2>
        <table>
          <thead><tr><th>Ref</th><th>To account</th><th>Amount</th><th>When</th><th>Case</th></tr></thead>
          <tbody>
            {transfers.map(t => (
              <tr key={t.txn_id}>
                <td>{t.external_ref}</td><td>{t.to_ref}</td><td>{inr(t.amount)}</td>
                <td>{when(t.occurred_at)}</td><td>{t.case_id ? `#${t.case_id}` : '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
