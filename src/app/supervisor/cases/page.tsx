import { requirePageRole } from '@/lib/auth';
import { query } from '@/lib/db';
import { inr, when } from '@/lib/format';
import ActionForm from '@/components/ActionForm';

export default async function SupervisorCases({ searchParams }: { searchParams: Promise<{ status?: string }> }) {
  await requirePageRole('SUPERVISOR');
  const { status } = await searchParams;
  const cases = await query<{ case_id: string; status: string; priority: number; reported_amount: string;
    verified_loss: string | null; customer: string; txn_ref: string; investigator: string | null; created_at: Date;
    next_statuses: string[] | null }>(
    `SELECT c.case_id, c.status, c.priority, c.reported_amount, c.verified_loss, c.created_at,
            u.full_name AS customer, t.external_ref AS txn_ref, i.full_name AS investigator,
            (SELECT array_agg(to_status ORDER BY to_status) FROM case_status_transitions
             WHERE from_status = c.status AND allowed_role = 'SUPERVISOR' AND to_status <> 'UNDER_REVIEW') AS next_statuses
     FROM fraud_cases c
     JOIN users u ON u.user_id = c.customer_id
     JOIN transactions t ON t.txn_id = c.disputed_txn_id
     LEFT JOIN case_assignments a ON a.case_id = c.case_id AND a.ended_at IS NULL
     LEFT JOIN users i ON i.user_id = a.investigator_id
     WHERE ($1::text IS NULL OR c.status = $1)
     ORDER BY c.priority, c.created_at DESC`, [status || null]);
  const investigators = await query<{ user_id: string; full_name: string }>(
    "SELECT user_id, full_name FROM users WHERE role = 'INVESTIGATOR' AND is_active ORDER BY full_name");
  const invOptions = investigators.map(i => ({ value: i.user_id, label: i.full_name }));

  return (
    <div className="card">
      <h2>Cases</h2>
      <form className="filters" method="get">
        <div><label>Status</label>
          <select name="status" defaultValue={status ?? ''}>
            <option value="">Any</option>
            {['SUBMITTED', 'UNDER_REVIEW', 'INVESTIGATING', 'RECOVERY', 'CLOSED', 'REJECTED'].map(s => <option key={s}>{s}</option>)}
          </select></div>
        <button>Filter</button>
      </form>
      <table style={{ marginTop: 16 }}>
        <thead><tr><th>Case</th><th>Customer / transfer</th><th>Reported</th><th>Status</th><th>Assign</th><th>Verify loss</th><th>Move to</th></tr></thead>
        <tbody>{cases.map(c => (
          <tr key={c.case_id}>
            <td>#{c.case_id}<div className="muted">P{c.priority} · {when(c.created_at)}</div></td>
            <td>{c.customer}<div className="muted">{c.txn_ref}</div></td>
            <td>{inr(c.reported_amount)}<div className="muted">verified {inr(c.verified_loss)}</div></td>
            <td><span className="badge">{c.status}</span><div className="muted">{c.investigator ?? 'unassigned'}</div></td>
            <td>{!['CLOSED', 'REJECTED'].includes(c.status) && (
              <ActionForm inline endpoint={`/api/cases/${c.case_id}/assign`} submit={c.investigator ? 'Reassign' : 'Assign'}
                          fields={[{ name: 'investigatorId', label: 'Investigator', type: 'select', options: invOptions }]} />)}</td>
            <td>{['INVESTIGATING', 'RECOVERY'].includes(c.status) && (
              <ActionForm inline endpoint={`/api/cases/${c.case_id}/verify`} submit="Verify"
                          fields={[{ name: 'amount', label: '₹', type: 'number', required: true,
                                     defaultValue: c.verified_loss ?? c.reported_amount }]} />)}</td>
            <td>{c.next_statuses && (
              <ActionForm inline endpoint={`/api/cases/${c.case_id}/status`} submit="Move"
                          fields={[{ name: 'to', label: 'Status', type: 'select',
                                     options: c.next_statuses.map(s => ({ value: s, label: s })) }]} />)}</td>
          </tr>
        ))}
        {cases.length === 0 && <tr><td colSpan={7} className="muted">No cases.</td></tr>}</tbody>
      </table>
    </div>
  );
}
