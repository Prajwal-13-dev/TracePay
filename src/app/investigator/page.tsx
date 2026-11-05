import { requirePageRole } from '@/lib/auth';
import { query } from '@/lib/db';

export default async function InvestigatorHome() {
  await requirePageRole('INVESTIGATOR');
  const rows = await query<{ status: string; n: string }>(
    'SELECT status, COUNT(*) AS n FROM fraud_cases GROUP BY status ORDER BY status');
  return (
    <div className="card">
      <h2>Investigator workspace</h2>
      <p className="muted">Case queue and trace workspace arrive in Phase 8.</p>
      <table>
        <thead><tr><th>Status</th><th>Cases</th></tr></thead>
        <tbody>
          {rows.map(r => <tr key={r.status}><td>{r.status}</td><td>{r.n}</td></tr>)}
          {rows.length === 0 && <tr><td colSpan={2} className="muted">No cases yet.</td></tr>}
        </tbody>
      </table>
    </div>
  );
}
