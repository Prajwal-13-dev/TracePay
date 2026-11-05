import { requirePageRole } from '@/lib/auth';
import { query } from '@/lib/db';
import { inr, when } from '@/lib/format';
import ActionForm from '@/components/ActionForm';

export default async function FreezeDesk() {
  const user = await requirePageRole('SUPERVISOR');
  await query('CALL expire_freezes()');   // lazy expiry before showing capacity

  const requests = await query<{ freeze_id: string; account_ref: string; balance: string; frozen_amount: string;
    case_id: string; requested_by: string; requested_by_id: string; requested_at: Date }>(
    `SELECT f.freeze_id, a.account_ref, a.balance, f.frozen_amount, f.requested_for_case AS case_id,
            u.full_name AS requested_by, f.requested_by AS requested_by_id, f.requested_at
     FROM account_freezes f JOIN accounts a USING (account_id) JOIN users u ON u.user_id = f.requested_by
     WHERE f.status = 'REQUESTED' ORDER BY f.requested_at`);
  const active = await query<{ freeze_id: string; account_id: string; account_ref: string; frozen_amount: string;
    allocated: string; remaining: string; expires_at: Date }>(
    `SELECT fc.*, a.account_ref FROM freeze_capacity fc JOIN accounts a USING (account_id) ORDER BY fc.freeze_id`);
  // Cases in RECOVERY that traced money into each frozen account, with how much they traced there
  const claimants = await query<{ freeze_id: string; case_id: string; traced: string; verified_loss: string }>(
    `SELECT f.freeze_id, c.case_id, SUM(n.inflow_amount) AS traced, c.verified_loss
     FROM active_freezes f
     JOIN transactions t ON t.destination_account_id = f.account_id
     JOIN trace_nodes n ON n.txn_id = t.txn_id
     JOIN fraud_cases c ON c.case_id = n.case_id AND c.status = 'RECOVERY'
     GROUP BY f.freeze_id, c.case_id, c.verified_loss ORDER BY c.case_id`);
  const allocations = await query<{ allocation_id: string; freeze_id: string; account_ref: string; case_id: string;
    amount: string; status: string; refunded: string; allocated_at: Date }>(
    `SELECT ra.allocation_id, ra.freeze_id, a.account_ref, ra.case_id, ra.amount, ra.status, ra.allocated_at,
            COALESCE((SELECT SUM(r.amount) FROM refunds r WHERE r.allocation_id = ra.allocation_id AND r.status = 'PROCESSED'), 0) AS refunded
     FROM recovery_allocations ra JOIN account_freezes f USING (freeze_id) JOIN accounts a ON a.account_id = f.account_id
     ORDER BY ra.allocation_id DESC LIMIT 100`);

  return (
    <>
      <div className="card">
        <h2>Freeze requests</h2>
        <p className="muted">Four-eyes rule: you cannot approve a freeze you requested (enforced by a CHECK on the table).</p>
        <table>
          <thead><tr><th>Freeze</th><th>Account (balance)</th><th>Amount</th><th>Case</th><th>Requested by</th><th>Decision</th></tr></thead>
          <tbody>{requests.map(r => (
            <tr key={r.freeze_id}>
              <td>#{r.freeze_id}<div className="muted">{when(r.requested_at)}</div></td>
              <td>{r.account_ref}<div className="muted">{inr(r.balance)}</div></td>
              <td>{inr(r.frozen_amount)}</td><td>#{r.case_id}</td>
              <td>{r.requested_by}{Number(r.requested_by_id) === user.id && <div className="error">you</div>}</td>
              <td>
                <ActionForm inline endpoint={`/api/freezes/${r.freeze_id}/decision`} extra={{ approve: true }} submit="Approve"
                            fields={[{ name: 'days', label: 'Days', type: 'number', defaultValue: 7, step: '1' }]} />
                <ActionForm inline endpoint={`/api/freezes/${r.freeze_id}/decision`} extra={{ approve: false }} submit="Decline" />
              </td>
            </tr>
          ))}
          {requests.length === 0 && <tr><td colSpan={6} className="muted">No pending requests.</td></tr>}</tbody>
        </table>
      </div>

      <div className="card">
        <h2>Active freezes: allocation desk</h2>
        <table>
          <thead><tr><th>Freeze</th><th>Account</th><th>Frozen</th><th>Allocated</th><th>Remaining</th><th>Expires</th><th>Allocate</th><th></th></tr></thead>
          <tbody>{active.map(f => {
            const opts = claimants.filter(c => c.freeze_id === f.freeze_id)
              .map(c => ({ value: c.case_id, label: `#${c.case_id} (traced ${inr(c.traced)}, loss ${inr(c.verified_loss)})` }));
            return (
              <tr key={f.freeze_id}>
                <td>#{f.freeze_id}</td><td>{f.account_ref}</td><td>{inr(f.frozen_amount)}</td>
                <td>{inr(f.allocated)}</td><td>{inr(f.remaining)}</td><td>{when(f.expires_at)}</td>
                <td>{opts.length ? (
                  <ActionForm inline endpoint="/api/allocations" submit="Allocate" extra={{ freezeId: Number(f.freeze_id) }}
                              fields={[{ name: 'caseId', label: 'Case', type: 'select', options: opts },
                                       { name: 'amount', label: '₹', type: 'number', required: true }]} />
                ) : <span className="muted">no case in RECOVERY traced here</span>}</td>
                <td><ActionForm inline endpoint={`/api/freezes/${f.freeze_id}/settle`} submit="Settle"
                                confirm="Settle this freeze? Unpaid allocations are cancelled and refunds are debited." /></td>
              </tr>
            );
          })}
          {active.length === 0 && <tr><td colSpan={8} className="muted">No active freezes.</td></tr>}</tbody>
        </table>
      </div>

      <div className="card">
        <h2>Allocations and refunds</h2>
        <p className="muted">Each refund carries a fresh idempotency key; a repeated request returns the same refund.</p>
        <table>
          <thead><tr><th>Allocation</th><th>Freeze / account</th><th>Case</th><th>Amount</th><th>Refunded</th><th>Status</th><th>Refund</th></tr></thead>
          <tbody>{allocations.map(a => (
            <tr key={a.allocation_id}>
              <td>#{a.allocation_id}<div className="muted">{when(a.allocated_at)}</div></td>
              <td>#{a.freeze_id} · {a.account_ref}</td><td>#{a.case_id}</td><td>{inr(a.amount)}</td>
              <td>{inr(a.refunded)}</td><td><span className="badge">{a.status}</span></td>
              <td>{a.status === 'ACTIVE' && (
                <ActionForm inline idempotent endpoint="/api/refunds" submit="Refund" extra={{ allocationId: Number(a.allocation_id) }}
                            fields={[{ name: 'amount', label: '₹', type: 'number', required: true,
                                       defaultValue: (Number(a.amount) - Number(a.refunded)).toFixed(2) }]} />)}</td>
            </tr>
          ))}
          {allocations.length === 0 && <tr><td colSpan={7} className="muted">No allocations yet.</td></tr>}</tbody>
        </table>
      </div>
    </>
  );
}
