import { requirePageRole } from '@/lib/auth';
import { query } from '@/lib/db';

export default async function SupervisorHome() {
  await requirePageRole('SUPERVISOR');
  const rules = await query<{ name: string; parent_table: string; child_table: string; relation: string }>(
    'SELECT name, parent_table::text, child_table::text, relation FROM invariant_definitions ORDER BY invariant_id');
  return (
    <div className="card">
      <h2>Supervisor console</h2>
      <p className="muted">Freeze desk, allocation and dashboard arrive in Phase 8. Registered money rules:</p>
      <table>
        <thead><tr><th>Rule</th><th>Child total</th><th></th><th>Parent limit</th></tr></thead>
        <tbody>
          {rules.map(r => (
            <tr key={r.name}><td>{r.name}</td><td>{r.child_table}</td><td>{r.relation}</td><td>{r.parent_table}</td></tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
