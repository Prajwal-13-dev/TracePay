import { requirePageRole } from '@/lib/auth';
import { query } from '@/lib/db';
import { when } from '@/lib/format';

export default async function AuditLog({ searchParams }: { searchParams: Promise<{ entity?: string }> }) {
  await requirePageRole('SUPERVISOR');
  const { entity } = await searchParams;
  const rows = await query<{ audit_id: string; at: Date; actor: string | null; entity_type: string; entity_id: string;
    action: string; changes: string | null }>(
    `SELECT l.audit_id, l.at, u.full_name AS actor, l.entity_type, l.entity_id, l.action,
            (SELECT string_agg(n.key || ': ' || COALESCE(l.old_row ->> n.key, '∅') || ' → ' || COALESCE(n.value #>> '{}', '∅'), '; ')
             FROM jsonb_each(l.new_row) n
             WHERE l.old_row IS NOT NULL AND l.old_row -> n.key IS DISTINCT FROM n.value) AS changes
     FROM audit_log l LEFT JOIN users u ON u.user_id = l.actor_id
     WHERE ($1::text IS NULL OR l.entity_type = $1)
     ORDER BY l.audit_id DESC LIMIT 200`, [entity || null]);
  return (
    <div className="card">
      <h2>Audit log</h2>
      <p className="muted">Written by triggers in the same transaction as each change; UPDATE, DELETE and TRUNCATE are blocked.</p>
      <form className="filters" method="get">
        <div><label>Entity</label>
          <select name="entity" defaultValue={entity ?? ''}>
            <option value="">All</option>
            {['fraud_cases', 'case_assignments', 'trace_nodes', 'fund_flow_links', 'account_freezes', 'recovery_allocations', 'refunds', 'accounts', 'users']
              .map(e => <option key={e}>{e}</option>)}
          </select></div>
        <button>Filter</button>
      </form>
      <table style={{ marginTop: 16 }}>
        <thead><tr><th>#</th><th>When</th><th>Who</th><th>Entity</th><th>Action</th><th>Changed fields</th></tr></thead>
        <tbody>{rows.map(r => (
          <tr key={r.audit_id}><td>{r.audit_id}</td><td>{when(r.at)}</td><td>{r.actor ?? 'system'}</td>
            <td>{r.entity_type} #{r.entity_id}</td><td>{r.action}</td>
            <td className="muted" style={{ maxWidth: 380 }}>{r.changes ?? (r.action === 'INSERT' ? 'created' : '')}</td></tr>
        ))}
        {rows.length === 0 && <tr><td colSpan={6} className="muted">No entries.</td></tr>}</tbody>
      </table>
    </div>
  );
}
