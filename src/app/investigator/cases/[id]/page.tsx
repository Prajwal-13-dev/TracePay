import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requirePageRole } from '@/lib/auth';
import { query } from '@/lib/db';
import { inr, when } from '@/lib/format';
import ActionForm from '@/components/ActionForm';
import SimilarCases from '@/components/SimilarCases';

export default async function CaseWorkspace({ params }: { params: Promise<{ id: string }> }) {
  const user = await requirePageRole('INVESTIGATOR');
  const caseId = Number((await params).id);
  if (!Number.isInteger(caseId)) notFound();

  const [c] = await query<{ case_id: string; status: string; priority: number; reported_amount: string;
    verified_loss: string | null; narrative: string; investigator_notes: string | null; disputed_txn_id: string;
    txn_ref: string; customer: string; assigned_to_me: boolean }>(
    `SELECT c.*, t.external_ref AS txn_ref, u.full_name AS customer,
            EXISTS (SELECT 1 FROM case_assignments a WHERE a.case_id = c.case_id AND a.ended_at IS NULL
                    AND a.investigator_id = $2) AS assigned_to_me
     FROM fraud_cases c JOIN transactions t ON t.txn_id = c.disputed_txn_id JOIN users u ON u.user_id = c.customer_id
     WHERE c.case_id = $1`, [caseId, user.id]);
  if (!c) notFound();

  const candidates = await query<{ txn_id: string; ref: string; parent_ref: string | null; depth: number;
    from_ref: string; to_ref: string; amount: string; occurred_at: Date; upper_bound: string }>(
    `SELECT tc.txn_id, t.external_ref AS ref, p.external_ref AS parent_ref, tc.depth, sa.account_ref AS from_ref,
            da.account_ref AS to_ref, tc.amount, tc.occurred_at, tc.upper_bound
     FROM trace_candidates($1) tc
     JOIN transactions t ON t.txn_id = tc.txn_id
     LEFT JOIN transactions p ON p.txn_id = tc.parent_txn_id
     JOIN accounts sa ON sa.account_id = tc.source_account_id
     JOIN accounts da ON da.account_id = tc.destination_account_id
     ORDER BY tc.depth, tc.occurred_at`, [c.disputed_txn_id]);

  const nodes = await query<{ node_id: string; txn_id: string; ref: string; to_ref: string; is_root: boolean;
    inflow_amount: string; outflow: string; txn_amount: string; all_cases: string }>(
    `SELECT n.node_id, n.txn_id, t.external_ref AS ref, a.account_ref AS to_ref, n.is_root, n.inflow_amount,
            COALESCE((SELECT SUM(l.attributed_amount) FROM fund_flow_links l WHERE l.from_node_id = n.node_id), 0) AS outflow,
            t.amount AS txn_amount,
            (SELECT SUM(x.inflow_amount) FROM trace_nodes x WHERE x.txn_id = n.txn_id) AS all_cases
     FROM trace_nodes n JOIN transactions t ON t.txn_id = n.txn_id JOIN accounts a ON a.account_id = t.destination_account_id
     WHERE n.case_id = $1 ORDER BY t.occurred_at`, [caseId]);

  const links = await query<{ link_id: string; from_ref: string; to_ref: string; attributed_amount: string; method: string;
    linked_at: Date; running: string }>(
    `SELECT l.link_id, ft.external_ref AS from_ref, tt.external_ref AS to_ref, l.attributed_amount, l.method, l.linked_at,
            SUM(l.attributed_amount) OVER (ORDER BY tt.occurred_at, l.link_id) AS running
     FROM fund_flow_links l
     JOIN trace_nodes fn ON fn.node_id = l.from_node_id JOIN transactions ft ON ft.txn_id = fn.txn_id
     JOIN trace_nodes tn ON tn.node_id = l.to_node_id   JOIN transactions tt ON tt.txn_id = tn.txn_id
     WHERE l.case_id = $1 ORDER BY tt.occurred_at, l.link_id`, [caseId]);

  const fifo = await query<{ from_ref: string; to_ref: string; suggested_amount: string }>(
    `SELECT ft.external_ref AS from_ref, tt.external_ref AS to_ref, s.suggested_amount
     FROM trace_nodes n JOIN transactions ft ON ft.txn_id = n.txn_id
     CROSS JOIN LATERAL suggest_fifo($1, n.txn_id) s
     JOIN transactions tt ON tt.txn_id = s.to_txn_id
     WHERE n.case_id = $1 ORDER BY ft.occurred_at, tt.occurred_at`, [caseId]);

  const traceAccounts = await query<{ account_id: string; account_ref: string; balance: string; traced: string }>(
    `SELECT a.account_id, a.account_ref, a.balance, SUM(n.inflow_amount) AS traced
     FROM trace_nodes n JOIN transactions t ON t.txn_id = n.txn_id JOIN accounts a ON a.account_id = t.destination_account_id
     WHERE n.case_id = $1 GROUP BY a.account_id, a.account_ref, a.balance ORDER BY a.account_ref`, [caseId]);

  const freezes = await query<{ freeze_id: string; account_ref: string; frozen_amount: string; status: string; requested_at: Date }>(
    `SELECT f.freeze_id, a.account_ref, f.frozen_amount, f.status, f.requested_at
     FROM account_freezes f JOIN accounts a USING (account_id) WHERE f.requested_for_case = $1 ORDER BY f.freeze_id`, [caseId]);

  const canWork = c.assigned_to_me && c.status === 'INVESTIGATING';
  const nodeOptions = nodes.map(n => ({ value: n.txn_id, label: `${n.ref} (inflow ${inr(n.inflow_amount)})` }));
  const targetOptions = candidates.filter(t => t.depth > 0)
    .map(t => ({ value: t.txn_id, label: `${t.ref}: ${t.from_ref} → ${t.to_ref}, ${inr(t.amount)}` }));

  return (
    <>
      <p><Link href="/investigator">← Case queue</Link></p>
      <div className="card">
        <h2>Case #{c.case_id} <span className="badge">{c.status}</span></h2>
        <div className="grid">
          <div className="stat"><span className="muted">Customer</span><b>{c.customer}</b></div>
          <div className="stat"><span className="muted">Disputed transfer</span><b>{c.txn_ref}</b></div>
          <div className="stat"><span className="muted">Reported</span><b>{inr(c.reported_amount)}</b></div>
          <div className="stat"><span className="muted">Verified loss</span><b>{inr(c.verified_loss)}</b></div>
        </div>
        <p>{c.narrative}</p>
        {!c.assigned_to_me && <p className="error">This case is not assigned to you: view only.</p>}
        {c.assigned_to_me && c.status === 'UNDER_REVIEW' && (
          <ActionForm endpoint={`/api/cases/${caseId}/status`} extra={{ to: 'INVESTIGATING' }} submit="Accept and start investigating" />
        )}
        {c.assigned_to_me && (
          <>
            <h3>Investigator notes</h3>
            <ActionForm endpoint={`/api/cases/${caseId}/notes`} method="PATCH" submit="Save notes"
                        fields={[{ name: 'notes', label: 'Notes (searchable)', type: 'textarea', defaultValue: c.investigator_notes ?? '' }]} />
          </>
        )}
      </div>

      <div className="card">
        <h2>Candidate trace</h2>
        <p className="muted">Recursive query from {c.txn_ref}: forward in time, 72-hour window, up to 5 hops, each transfer once.
          &quot;Upper bound&quot; is a display ceiling, never written as attribution.</p>
        <table>
          <thead><tr><th>Depth</th><th>Transfer</th><th>From hop</th><th>From → To</th><th>Amount</th><th>Upper bound</th><th>When</th></tr></thead>
          <tbody>{candidates.map(t => (
            <tr key={t.txn_id}><td>{t.depth}</td><td>{t.ref}</td><td>{t.parent_ref ?? '—'}</td>
              <td>{t.from_ref} → {t.to_ref}</td><td>{inr(t.amount)}</td><td>{inr(t.upper_bound)}</td><td>{when(t.occurred_at)}</td></tr>
          ))}</tbody>
        </table>
        {canWork && nodes.length === 0 && (
          <p><ActionForm endpoint={`/api/cases/${caseId}/trace`} submit="Start trace (root = disputed transfer)" /></p>
        )}
      </div>

      <div className="card">
        <h2>Confirmed trace</h2>
        <table>
          <thead><tr><th>Transfer</th><th>Into account</th><th>This case&apos;s inflow</th><th>Sent onward</th><th>All cases on this transfer</th></tr></thead>
          <tbody>{nodes.map(n => (
            <tr key={n.node_id}><td>{n.ref}{n.is_root && <span className="badge"> root</span>}</td><td>{n.to_ref}</td>
              <td>{inr(n.inflow_amount)}</td><td>{inr(n.outflow)}</td><td>{inr(n.all_cases)} of {inr(n.txn_amount)}</td></tr>
          ))}
          {nodes.length === 0 && <tr><td colSpan={5} className="muted">Trace not started.</td></tr>}</tbody>
        </table>

        {fifo.length > 0 && (<>
          <h3>FIFO suggestions</h3>
          <table><thead><tr><th>From</th><th>To</th><th>Suggested</th></tr></thead>
            <tbody>{fifo.map(f => <tr key={f.from_ref + f.to_ref}><td>{f.from_ref}</td><td>{f.to_ref}</td><td>{inr(f.suggested_amount)}</td></tr>)}</tbody>
          </table>
        </>)}

        {canWork && nodes.length > 0 && (<>
          <h3>Confirm a link</h3>
          <ActionForm endpoint={`/api/cases/${caseId}/links`} submit="Confirm link" fields={[
            { name: 'fromTxn', label: 'From (confirmed node)', type: 'select', options: nodeOptions, required: true },
            { name: 'toTxn', label: 'To (next transfer)', type: 'select', options: targetOptions, required: true },
            { name: 'amount', label: 'Amount (₹)', type: 'number', required: true },
            { name: 'method', label: 'Method', type: 'select', options: ['MANUAL', 'FIFO', 'PROPORTIONAL'].map(m => ({ value: m, label: m })) },
          ]} />
        </>)}

        <h3>Confirmed links</h3>
        <table>
          <thead><tr><th>From</th><th>To</th><th>Amount</th><th>Method</th><th>Running total</th><th>When</th></tr></thead>
          <tbody>{links.map(l => (
            <tr key={l.link_id}><td>{l.from_ref}</td><td>{l.to_ref}</td><td>{inr(l.attributed_amount)}</td>
              <td>{l.method}</td><td>{inr(l.running)}</td><td>{when(l.linked_at)}</td></tr>
          ))}
          {links.length === 0 && <tr><td colSpan={6} className="muted">No links yet.</td></tr>}</tbody>
        </table>
      </div>

      <div className="card">
        <h2>Freezes</h2>
        <table>
          <thead><tr><th>Freeze</th><th>Account</th><th>Amount</th><th>Status</th><th>Requested</th></tr></thead>
          <tbody>{freezes.map(f => (
            <tr key={f.freeze_id}><td>#{f.freeze_id}</td><td>{f.account_ref}</td><td>{inr(f.frozen_amount)}</td>
              <td><span className="badge">{f.status}</span></td><td>{when(f.requested_at)}</td></tr>
          ))}
          {freezes.length === 0 && <tr><td colSpan={5} className="muted">No freezes requested.</td></tr>}</tbody>
        </table>
        {c.assigned_to_me && ['INVESTIGATING', 'RECOVERY'].includes(c.status) && traceAccounts.length > 0 && (<>
          <h3>Request a freeze</h3>
          <ActionForm endpoint="/api/freezes" submit="Request freeze" extra={{ caseId }} fields={[
            { name: 'accountId', label: 'Account on this trace', type: 'select', required: true,
              options: traceAccounts.map(a => ({ value: a.account_id, label: `${a.account_ref} (balance ${inr(a.balance)}, traced ${inr(a.traced)})` })) },
            { name: 'amount', label: 'Amount (₹)', type: 'number', required: true },
          ]} />
        </>)}
      </div>

      <SimilarCases caseId={caseId} />
    </>
  );
}
