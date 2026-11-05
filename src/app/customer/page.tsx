import { requirePageRole } from '@/lib/auth';
import { query } from '@/lib/db';

export default async function CustomerHome() {
  const user = await requirePageRole('CUSTOMER');
  // Customer queries always filter by the session user: someone else's data is never selected.
  const transfers = await query<{ external_ref: string; to_ref: string; amount: string; occurred_at: Date }>(
    `SELECT t.external_ref, d.account_ref AS to_ref, t.amount, t.occurred_at
     FROM transactions t
     JOIN accounts s ON s.account_id = t.source_account_id
     JOIN accounts d ON d.account_id = t.destination_account_id
     WHERE s.user_id = $1
     ORDER BY t.occurred_at DESC`, [user.id]);
  return (
    <div className="card">
      <h2>My transfers</h2>
      <p className="muted">Complaint forms arrive in Phase 8.</p>
      <table>
        <thead><tr><th>Ref</th><th>To account</th><th>Amount (₹)</th><th>When</th></tr></thead>
        <tbody>
          {transfers.map(t => (
            <tr key={t.external_ref}>
              <td>{t.external_ref}</td><td>{t.to_ref}</td>
              <td>{Number(t.amount).toLocaleString('en-IN')}</td>
              <td>{new Date(t.occurred_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' })}</td>
            </tr>
          ))}
          {transfers.length === 0 && <tr><td colSpan={4} className="muted">No transfers.</td></tr>}
        </tbody>
      </table>
    </div>
  );
}
