import StatusBadge from '@/components/StatusBadge';
import { requirePageRole } from '@/lib/auth';
import { query } from '@/lib/db';
import { inr, when } from '@/lib/format';
import ActionForm from '@/components/ActionForm';
import Link from 'next/link';

const TABS = [
  { key: 'requests', label: 'Requests' }, { key: 'active', label: 'Active freezes' },
  { key: 'allocations', label: 'Allocations & refunds' }, { key: 'closed', label: 'Closed' },
] as const;

export default async function FreezeDesk({ searchParams }: { searchParams: Promise<{ tab?: string }> }) {
  const user = await requirePageRole('SUPERVISOR');
  const askedTab = (await searchParams).tab;
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
  // Every case linked to each active freeze: cases whose confirmed trace reached the frozen account,
  // plus the case the freeze was requested for. Only RECOVERY cases with traced money can be allocated;
  // for the rest the desk says what is missing.
  const claimants = await query<{ freeze_id: string; case_id: string; status: string; traced: string;
    verified_loss: string | null; allocated: string }>(
    `WITH linked AS (
       SELECT f.freeze_id, f.account_id, n.case_id
       FROM active_freezes f
       JOIN transactions t ON t.destination_account_id = f.account_id
       JOIN trace_nodes n ON n.txn_id = t.txn_id
       UNION
       SELECT f.freeze_id, f.account_id, f.requested_for_case FROM active_freezes f)
     SELECT l.freeze_id, c.case_id, c.status, c.verified_loss,
            COALESCE((SELECT SUM(n.inflow_amount) FROM trace_nodes n JOIN transactions t ON t.txn_id = n.txn_id
                      WHERE n.case_id = c.case_id AND t.destination_account_id = l.account_id), 0) AS traced,
            COALESCE((SELECT SUM(ra.amount) FROM recovery_allocations ra JOIN account_freezes af USING (freeze_id)
                      WHERE ra.case_id = c.case_id AND af.account_id = l.account_id AND ra.status IN ('ACTIVE', 'PAID')), 0) AS allocated
     FROM linked l JOIN fraud_cases c ON c.case_id = l.case_id
     ORDER BY l.freeze_id, c.case_id`);
  const blocker = (c: { status: string; traced: string; verified_loss: string | null; allocated: string }) =>
    Number(c.traced) <= 0 ? 'no confirmed trace into this account: confirm the links first'
    : c.status === 'INVESTIGATING' && !c.verified_loss ? 'verify the loss, then move the case to Recovery (Cases page)'
    : c.status === 'INVESTIGATING' ? 'move the case to Recovery (Cases page)'
    : c.status !== 'RECOVERY' ? `case is ${c.status.toLowerCase().replace('_', ' ')}`
    : Number(c.allocated) >= Number(c.traced) ? 'everything this case traced here is already allocated'
    : null;
  // Freezes that are no longer active, with what they recovered
  const closed = await query<{ freeze_id: string; account_ref: string; case_id: string; frozen_amount: string;
    status: string; allocated: string; paid: string; requested_at: Date }>(
    `SELECT f.freeze_id, a.account_ref, f.requested_for_case AS case_id, f.frozen_amount, f.status, f.requested_at,
            COALESCE((SELECT SUM(ra.amount) FROM recovery_allocations ra WHERE ra.freeze_id = f.freeze_id AND ra.status IN ('ACTIVE', 'PAID')), 0) AS allocated,
            COALESCE((SELECT SUM(r.amount) FROM refunds r JOIN recovery_allocations ra USING (allocation_id)
                      WHERE ra.freeze_id = f.freeze_id AND r.status = 'PROCESSED'), 0) AS paid
     FROM account_freezes f JOIN accounts a USING (account_id)
     WHERE f.status NOT IN ('REQUESTED', 'ACTIVE') OR f.expires_at <= now()
     ORDER BY f.freeze_id DESC LIMIT 50`);
  const allocations = await query<{ allocation_id: string; freeze_id: string; account_ref: string; case_id: string;
    amount: string; status: string; refunded: string; allocated_at: Date; credit_ref: string | null; victim_ref: string | null }>(
    `SELECT ra.allocation_id, ra.freeze_id, a.account_ref, ra.case_id, ra.amount, ra.status, ra.allocated_at,
            COALESCE((SELECT SUM(r.amount) FROM refunds r WHERE r.allocation_id = ra.allocation_id AND r.status = 'PROCESSED'), 0) AS refunded,
            ct.external_ref AS credit_ref, va.account_ref AS victim_ref
     FROM recovery_allocations ra JOIN account_freezes f USING (freeze_id) JOIN accounts a ON a.account_id = f.account_id
     LEFT JOIN transactions ct ON ct.txn_id = ra.credit_txn_id
     LEFT JOIN accounts va ON va.account_id = ct.destination_account_id
     ORDER BY ra.allocation_id DESC LIMIT 100`);

  const counts: Record<string, number> = { requests: requests.length, active: active.length, allocations: allocations.filter(a => a.status === 'ACTIVE').length, closed: closed.length };
  const tab = TABS.some(t => t.key === askedTab) ? askedTab! : requests.length ? 'requests' : 'active';

  return (
    <>
      <div className="page-head"><div><h1>Freezes &amp; recovery</h1>
        <p>Approve freeze requests, share frozen money between cases, refund victims and settle.</p></div></div>
      <nav className="tabs" aria-label="Freeze desk sections">
        {TABS.map(t => (
          <Link key={t.key} href={`?tab=${t.key}`} className={t.key === tab ? 'on' : undefined}>
            {t.label}<span className="count">{counts[t.key]}</span>
          </Link>
        ))}
      </nav>

      {tab === 'requests' && (
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
                <ActionForm inline endpoint={`/api/freezes/${r.freeze_id}/decision`} extra={{ approve: true }} submit="Approve" success="Approved"
                            fields={[{ name: 'days', label: 'Days', type: 'number', defaultValue: 7, step: '1', min: 1, max: 90 }]} />
                <ActionForm inline endpoint={`/api/freezes/${r.freeze_id}/decision`} extra={{ approve: false }} submit="Decline" variant="secondary"
                            success="Declined" confirm="Decline this freeze request?" />
              </td>
            </tr>
          ))}
          {requests.length === 0 && <tr><td colSpan={6} className="muted">No pending requests.</td></tr>}</tbody>
        </table>
      </div>
      )}

      {tab === 'active' && (
      <div className="card">
        <h2>Active freezes: allocation desk</h2>
        <p className="muted">While a freeze is active the whole account is blocked: it can receive money but cannot send any.
          Settling pays out only the refunded amount; the rest stays with the account holder.</p>
        <table>
          <thead><tr><th>Freeze</th><th>Account</th><th>Frozen</th><th>Allocated</th><th>Remaining</th><th>Expires</th><th>Allocate</th><th></th></tr></thead>
          <tbody>{active.map(f => {
            const linked = claimants.filter(c => c.freeze_id === f.freeze_id);
            const ready = linked.filter(c => !blocker(c));
            const waiting = linked.filter(c => blocker(c));
            const opts = ready.map(c => ({ value: c.case_id,
              label: `#${c.case_id} (can take ${inr(Math.min(Number(c.traced) - Number(c.allocated), Number(f.remaining)))}, loss ${inr(c.verified_loss)})` }));
            const nothingAllocated = Number(f.allocated) === 0;
            return (
              <tr key={f.freeze_id}>
                <td>#{f.freeze_id}</td><td>{f.account_ref}<div><span className="badge s-ACTIVE">outgoing blocked</span></div></td><td>{inr(f.frozen_amount)}</td>
                <td>{inr(f.allocated)}</td><td>{inr(f.remaining)}</td><td>{when(f.expires_at)}</td>
                <td>{opts.length > 0 && (
                  <ActionForm inline endpoint="/api/allocations" submit="Allocate" extra={{ freezeId: Number(f.freeze_id) }}
                              fields={[{ name: 'caseId', label: 'Case', type: 'select', options: opts },
                                       { name: 'amount', label: '₹', type: 'number', required: true }]} />)}
                  {waiting.map(c => (
                    <div key={c.case_id} className="muted" style={{ fontSize: 13, marginTop: 4 }}>
                      #{c.case_id} not ready: {blocker(c)}
                    </div>))}
                  {linked.length === 0 && <span className="muted">no case is linked to this account yet</span>}</td>
                <td>{nothingAllocated && (
                  <ActionForm inline endpoint={`/api/freezes/${f.freeze_id}/release`} submit="Release" success="Freeze released"
                              confirm={`Release this freeze? ${inr(f.frozen_amount)} becomes available to the account holder again.`} />)}
                  <ActionForm inline variant={nothingAllocated ? 'secondary' : undefined}
                                endpoint={`/api/freezes/${f.freeze_id}/settle`} submit="Settle"
                                confirm={nothingAllocated
                                  ? `Nothing has been allocated from this freeze. Settling now recovers nothing for any victim (use Release to end the hold). Settle anyway?`
                                  : 'Settle this freeze? Refunded money is transferred to each victim\'s account; unpaid allocations are cancelled and the rest of the hold is released.'} /></td>
              </tr>
            );
          })}
          {active.length === 0 && <tr><td colSpan={8} className="muted">No active freezes.</td></tr>}</tbody>
        </table>
      </div>
      )}

      {tab === 'allocations' && (
      <div className="card">
        <h2>Allocations and refunds</h2>
        <p className="muted">Each refund carries a fresh idempotency key; a repeated request returns the same refund.</p>
        <table>
          <thead><tr><th>Allocation</th><th>Freeze / account</th><th>Case</th><th>Amount</th><th>Refunded</th><th>Status</th><th>Refund</th></tr></thead>
          <tbody>{allocations.map(a => (
            <tr key={a.allocation_id}>
              <td>#{a.allocation_id}<div className="muted">{when(a.allocated_at)}</div></td>
              <td>#{a.freeze_id} · {a.account_ref}</td><td>#{a.case_id}</td><td>{inr(a.amount)}</td>
              <td>{inr(a.refunded)}{a.credit_ref
                    ? <div className="ok" style={{ margin: 0, fontSize: 13 }}>credited to victim {a.victim_ref} ({a.credit_ref})</div>
                    : a.status === 'ACTIVE' && Number(a.refunded) > 0 && <div className="muted" style={{ fontSize: 13 }}>paid to the victim when the freeze is settled</div>}</td>
              <td><StatusBadge status={a.status} /></td>
              <td>{a.status === 'ACTIVE' && (
                <ActionForm inline idempotent endpoint="/api/refunds" submit="Refund" extra={{ allocationId: Number(a.allocation_id) }}
                            fields={[{ name: 'amount', label: '₹', type: 'number', required: true,
                                       defaultValue: (Number(a.amount) - Number(a.refunded)).toFixed(2) }]} />)}</td>
            </tr>
          ))}
          {allocations.length === 0 && <tr><td colSpan={7} className="muted">No allocations yet. Allocate from an active freeze
            above: the case must be in Recovery (loss verified) and must have traced money into that account.</td></tr>}</tbody>
        </table>
      </div>
      )}

      {tab === 'closed' && (
      <div className="card">
        <h2>Closed freezes</h2>
        <p className="muted">Settled, expired or declined freezes and what each one recovered.</p>
        <table>
          <thead><tr><th>Freeze</th><th>Account</th><th>Case</th><th>Frozen</th><th>Allocated</th><th>Refunded</th><th>Status</th></tr></thead>
          <tbody>{closed.map(f => (
            <tr key={f.freeze_id}>
              <td>#{f.freeze_id}<div className="muted">{when(f.requested_at)}</div></td><td>{f.account_ref}</td><td>#{f.case_id}</td>
              <td>{inr(f.frozen_amount)}</td><td>{inr(f.allocated)}</td>
              <td>{inr(f.paid)}{f.status === 'SETTLED' && Number(f.paid) === 0 && <div className="error">nothing recovered</div>}</td>
              <td><StatusBadge status={f.status} /></td>
            </tr>
          ))}
          {closed.length === 0 && <tr><td colSpan={7} className="muted">No closed freezes.</td></tr>}</tbody>
        </table>
      </div>
      )}
    </>
  );
}
