// Supervisor case page: everything about one case on one screen, with the supervisor's decisions in a side panel.
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requirePageRole } from '@/lib/auth';
import { query } from '@/lib/db';
import { inr, when } from '@/lib/format';
import StatusBadge, { statusLabel } from '@/components/StatusBadge';
import CaseTimeline from '@/components/CaseTimeline';
import ActionForm from '@/components/ActionForm';
import TraceGraph from '@/components/TraceGraph';
import { caseTraceGraph } from '@/lib/traceGraph';

export default async function SupervisorCase({ params }: { params: Promise<{ id: string }> }) {
  await requirePageRole('SUPERVISOR');
  const caseId = Number((await params).id);
  if (!Number.isInteger(caseId) || caseId <= 0) notFound();

  const [c] = await query<{ case_id: string; status: string; priority: number; reported_amount: string; verified_loss: string | null;
    verified_by: string | null; narrative: string; investigator_notes: string | null; created_at: Date; disputed_txn_id: string;
    customer: string; customer_email: string; customer_phone: string | null; txn_ref: string; txn_amount: string; txn_at: Date;
    from_ref: string; to_ref: string; to_owner: string; investigator: string | null; investigator_id: string | null; assigned_at: Date | null }>(
    `SELECT c.case_id, c.status, c.priority, c.reported_amount, c.verified_loss, vb.full_name AS verified_by, c.narrative,
            c.investigator_notes, c.created_at, c.disputed_txn_id,
            cu.full_name AS customer, cu.email AS customer_email, cu.phone AS customer_phone,
            t.external_ref AS txn_ref, t.amount AS txn_amount, t.occurred_at AS txn_at,
            sa.account_ref AS from_ref, da.account_ref AS to_ref, du.full_name AS to_owner,
            iu.full_name AS investigator, a.investigator_id, a.assigned_at
     FROM fraud_cases c
     JOIN users cu ON cu.user_id = c.customer_id
     JOIN transactions t ON t.txn_id = c.disputed_txn_id
     JOIN accounts sa ON sa.account_id = t.source_account_id
     JOIN accounts da ON da.account_id = t.destination_account_id JOIN users du ON du.user_id = da.user_id
     LEFT JOIN users vb ON vb.user_id = c.verified_by
     LEFT JOIN case_assignments a ON a.case_id = c.case_id AND a.ended_at IS NULL
     LEFT JOIN users iu ON iu.user_id = a.investigator_id
     WHERE c.case_id = $1`, [caseId]);
  if (!c) notFound();

  const [history, investigators, nextStatuses, links, freezes, allocations, audit, graph] = await Promise.all([
    query<{ to_status: string; from_status: string; changed_at: Date; by: string | null; note: string | null }>(
      `SELECT h.to_status, h.from_status, h.changed_at, u.full_name AS by, h.note
       FROM case_status_history h LEFT JOIN users u ON u.user_id = h.changed_by WHERE h.case_id = $1 ORDER BY h.changed_at`, [caseId]),
    query<{ user_id: string; full_name: string; open_cases: number }>(
      `SELECT u.user_id, u.full_name,
              (SELECT count(*) FROM case_assignments a JOIN fraud_cases fc USING (case_id)
               WHERE a.investigator_id = u.user_id AND a.ended_at IS NULL AND fc.status NOT IN ('CLOSED', 'REJECTED'))::int AS open_cases
       FROM users u WHERE u.role = 'INVESTIGATOR' AND u.is_active ORDER BY open_cases, u.full_name`),
    query<{ to_status: string }>(
      `SELECT t.to_status FROM case_status_transitions t JOIN case_status s ON s.code = t.to_status
       WHERE t.from_status = $1 AND t.allowed_role = 'SUPERVISOR' AND t.to_status <> 'UNDER_REVIEW' ORDER BY s.sort_order`, [c.status]),
    query<{ link_id: string; from_ref: string; to_ref: string; attributed_amount: string; method: string; linked_at: Date }>(
      `SELECT l.link_id, ft.external_ref AS from_ref, tt.external_ref AS to_ref, l.attributed_amount, l.method, l.linked_at
       FROM fund_flow_links l
       JOIN trace_nodes fn ON fn.node_id = l.from_node_id JOIN transactions ft ON ft.txn_id = fn.txn_id
       JOIN trace_nodes tn ON tn.node_id = l.to_node_id JOIN transactions tt ON tt.txn_id = tn.txn_id
       WHERE l.case_id = $1 ORDER BY tt.occurred_at, l.link_id`, [caseId]),
    query<{ freeze_id: string; account_ref: string; frozen_amount: string; status: string; requested_at: Date; expires_at: Date | null }>(
      `SELECT f.freeze_id, a.account_ref, f.frozen_amount, f.status, f.requested_at, f.expires_at
       FROM account_freezes f JOIN accounts a USING (account_id) WHERE f.requested_for_case = $1 ORDER BY f.freeze_id`, [caseId]),
    query<{ allocation_id: string; freeze_id: string; account_ref: string; amount: string; status: string; refunded: string; credit_ref: string | null }>(
      `SELECT ra.allocation_id, ra.freeze_id, a.account_ref, ra.amount, ra.status,
              COALESCE((SELECT SUM(r.amount) FROM refunds r WHERE r.allocation_id = ra.allocation_id AND r.status = 'PROCESSED'), 0) AS refunded,
              ct.external_ref AS credit_ref
       FROM recovery_allocations ra JOIN account_freezes f USING (freeze_id) JOIN accounts a ON a.account_id = f.account_id
       LEFT JOIN transactions ct ON ct.txn_id = ra.credit_txn_id
       WHERE ra.case_id = $1 ORDER BY ra.allocation_id`, [caseId]),
    query<{ audit_id: string; at: Date; actor: string | null; entity_type: string; action: string; changes: string | null }>(
      `SELECT l.audit_id, l.at, u.full_name AS actor, l.entity_type, l.action,
              (SELECT string_agg(n.key || ': ' || COALESCE(l.old_row ->> n.key, '∅') || ' → ' || COALESCE(n.value #>> '{}', '∅'), '; ')
               FROM jsonb_each(l.new_row) n WHERE l.old_row IS NOT NULL AND l.old_row -> n.key IS DISTINCT FROM n.value) AS changes
       FROM audit_log l LEFT JOIN users u ON u.user_id = l.actor_id
       WHERE (l.entity_type = 'fraud_cases' AND l.entity_id = $1)
          OR (l.entity_type IN ('case_assignments', 'trace_nodes', 'fund_flow_links', 'recovery_allocations')
              AND (COALESCE(l.new_row, l.old_row) ->> 'case_id')::bigint = $1)
          OR (l.entity_type = 'account_freezes' AND (COALESCE(l.new_row, l.old_row) ->> 'requested_for_case')::bigint = $1)
       ORDER BY l.audit_id DESC LIMIT 40`, [caseId]),
    caseTraceGraph(caseId, Number(c.disputed_txn_id)),
  ]);

  const open = !['CLOSED', 'REJECTED'].includes(c.status);
  const allocated = allocations.filter(a => a.status !== 'CANCELLED').reduce((s, a) => s + Number(a.amount), 0);
  const refunded = allocations.reduce((s, a) => s + Number(a.refunded), 0);

  return (
    <>
      <p><Link href="/supervisor/cases">← All cases</Link></p>
      <div className="page-head">
        <div><h1>Case #{c.case_id} <StatusBadge status={c.status} /> <span className={`prio prio-${c.priority}`} title="Priority">{c.priority}</span></h1>
          <p>Filed {when(c.created_at)} by {c.customer} · {c.investigator ? `Investigator: ${c.investigator}` : 'No investigator assigned'}</p></div>
      </div>

      <div className="case-layout">
        <div>
          <div className="grid" style={{ marginBottom: 20 }}>
            <div className="stat"><span className="muted">Reported</span><b>{inr(c.reported_amount)}</b><small>of a {inr(c.txn_amount)} transfer</small></div>
            <div className="stat"><span className="muted">Verified loss</span><b>{inr(c.verified_loss)}</b><small>{c.verified_by ? `by ${c.verified_by}` : 'not verified yet'}</small></div>
            <div className="stat"><span className="muted">Allocated</span><b>{inr(allocated)}</b></div>
            <div className="stat t-ok"><span className="muted">Refunded</span><b>{inr(refunded)}</b></div>
          </div>

          <div className="card">
            <h2>Complaint</h2>
            <dl className="review">
              <dt>Customer</dt><dd>{c.customer} · {c.customer_email}{c.customer_phone ? ` · ${c.customer_phone}` : ''}</dd>
              <dt>Disputed transfer</dt><dd>{c.txn_ref}: {inr(c.txn_amount)} from {c.from_ref} to {c.to_ref} ({c.to_owner}), {when(c.txn_at)}</dd>
              <dt>What happened</dt><dd>{c.narrative}</dd>
              <dt>Investigator notes</dt><dd>{c.investigator_notes || <span className="muted">none yet</span>}</dd>
            </dl>
            <CaseTimeline status={c.status} createdAt={c.created_at} history={history} />
            {history.length > 0 && (
              <ul className="history">{history.map((h, i) => (
                <li key={i}><b>{statusLabel(h.from_status)} → {statusLabel(h.to_status)}</b> · {when(h.changed_at)}{h.by ? ` · ${h.by}` : ''}
                  {h.note && <div className="muted">“{h.note}”</div>}</li>
              ))}</ul>
            )}
          </div>

          <div className="card">
            <h2>Money trail</h2>
            <p className="muted">Read-only view of the investigator&apos;s trace. Green arrows are confirmed for this case.</p>
            <TraceGraph caseId={caseId} graph={graph} fifo={{}} canWork={false} canFreeze={false} />
            <h3>Confirmed links</h3>
            <div className="table-wrap"><table>
              <thead><tr><th>From</th><th>To</th><th>Amount</th><th>Method</th><th>When</th></tr></thead>
              <tbody>{links.map(l => <tr key={l.link_id}><td>{l.from_ref}</td><td>{l.to_ref}</td><td>{inr(l.attributed_amount)}</td><td>{l.method}</td><td>{when(l.linked_at)}</td></tr>)}
              {links.length === 0 && <tr><td colSpan={5} className="muted">No links confirmed yet.</td></tr>}</tbody>
            </table></div>
          </div>

          <div className="card">
            <div className="card-head"><h2>Freezes and recovery</h2><Link href="/supervisor/freezes">Freeze desk →</Link></div>
            <div className="table-wrap"><table>
              <thead><tr><th>Freeze</th><th>Account</th><th>Amount</th><th>Status</th><th>Requested</th><th>Expires</th></tr></thead>
              <tbody>{freezes.map(f => <tr key={f.freeze_id}><td>#{f.freeze_id}</td><td>{f.account_ref}</td><td>{inr(f.frozen_amount)}</td>
                <td><StatusBadge status={f.status} /></td><td>{when(f.requested_at)}</td><td>{when(f.expires_at)}</td></tr>)}
              {freezes.length === 0 && <tr><td colSpan={6} className="muted">No freezes requested for this case.</td></tr>}</tbody>
            </table></div>
            {allocations.length > 0 && (<>
              <h3>Allocations</h3>
              <div className="table-wrap"><table>
                <thead><tr><th>Allocation</th><th>From</th><th>Amount</th><th>Refunded</th><th>Status</th></tr></thead>
                <tbody>{allocations.map(a => <tr key={a.allocation_id}><td>#{a.allocation_id}</td><td>freeze #{a.freeze_id} · {a.account_ref}</td>
                  <td>{inr(a.amount)}</td><td>{inr(a.refunded)}{a.credit_ref && <div className="muted">credited to victim ({a.credit_ref})</div>}</td>
                  <td><StatusBadge status={a.status} /></td></tr>)}</tbody>
              </table></div>
            </>)}
          </div>

          <div className="card">
            <h2>Audit trail for this case</h2>
            <div className="table-wrap"><table>
              <thead><tr><th>When</th><th>Who</th><th>What</th><th>Changes</th></tr></thead>
              <tbody>{audit.map(r => <tr key={r.audit_id}><td>{when(r.at)}</td><td>{r.actor ?? 'system'}</td>
                <td>{r.entity_type.replace(/_/g, ' ')} · {r.action.toLowerCase()}</td>
                <td className="muted" style={{ maxWidth: 380 }}>{r.changes ?? (r.action === 'INSERT' ? 'created' : '')}</td></tr>)}</tbody>
            </table></div>
          </div>
        </div>

        <aside className="side-panel">
          <div className="card">
            <h2>Decisions</h2>
            {!open && <p className="muted">This case is {c.status.toLowerCase()}; no further decisions.</p>}
            {open && (<>
              <h3>{c.investigator ? 'Reassign' : 'Assign'} investigator</h3>
              {investigators.length === 0 ? <p className="muted">No active investigators. <Link href="/supervisor/users">Add one</Link>.</p> : (
                <ActionForm endpoint={`/api/cases/${caseId}/assign`} submit={c.investigator ? 'Reassign' : 'Assign'}
                  success="Assignment saved"
                  fields={[{ name: 'investigatorId', label: 'Investigator', type: 'select', defaultValue: c.investigator_id ?? undefined,
                             options: investigators.map(i => ({ value: i.user_id, label: `${i.full_name} (${i.open_cases} open)` })) }]} />
              )}

              <h3>Priority</h3>
              <ActionForm endpoint={`/api/cases/${caseId}/priority`} method="PATCH" submit="Set priority" success="Priority updated"
                fields={[{ name: 'priority', label: '1 = most urgent', type: 'select', defaultValue: c.priority,
                           options: [1, 2, 3, 4, 5].map(p => ({ value: p, label: `${p}${p === 1 ? ' (urgent)' : p === 5 ? ' (low)' : ''}` })) }]} />

              {['INVESTIGATING', 'RECOVERY'].includes(c.status) && (<>
                <h3>Verify the loss</h3>
                <ActionForm endpoint={`/api/cases/${caseId}/verify`} submit="Verify" success="Verified loss saved"
                  fields={[{ name: 'amount', label: `Amount (at most ${inr(c.reported_amount)})`, type: 'number', required: true,
                             max: Number(c.reported_amount), defaultValue: c.verified_loss ?? c.reported_amount }]} />
              </>)}

              {nextStatuses.length > 0 && (<>
                <h3>Move the case</h3>
                {c.status === 'INVESTIGATING' && !c.verified_loss && <p className="muted">Verify the loss before moving to Recovery.</p>}
                <ActionForm endpoint={`/api/cases/${caseId}/status`} submit="Move" success="Status changed"
                  fields={[{ name: 'to', label: 'New status', type: 'select', options: nextStatuses.map(s => ({ value: s.to_status, label: statusLabel(s.to_status) })) },
                           { name: 'note', label: 'Message to the customer (required to reject)', type: 'textarea',
                             placeholder: 'e.g. The transfer was authorised by you and is not a fraud.' }]} />
              </>)}
              {c.status === 'SUBMITTED' && <p className="muted">Assigning an investigator moves the case to Under review.</p>}
            </>)}
          </div>
        </aside>
      </div>
    </>
  );
}
