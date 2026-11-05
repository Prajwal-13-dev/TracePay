import { requirePageRole } from '@/lib/auth';
import { query } from '@/lib/db';
import { inr, when } from '@/lib/format';

export default async function SupervisorDashboard() {
  await requirePageRole('SUPERVISOR');
  await query('REFRESH MATERIALIZED VIEW CONCURRENTLY supervisor_case_summary');

  const totals = await query<{ status: string; n: string }>(
    'SELECT status, COUNT(*) AS n FROM supervisor_case_summary GROUP BY status ORDER BY status');
  const [money] = await query<{ reported: string; verified: string; allocated: string; refunded: string }>(
    `SELECT COALESCE(SUM(reported_amount),0) AS reported, COALESCE(SUM(verified_loss),0) AS verified,
            COALESCE(SUM(allocated),0) AS allocated, COALESCE(SUM(refunded),0) AS refunded FROM supervisor_case_summary`);
  const summary = await query<{ case_id: string; status: string; priority: number; reported_amount: string;
    verified_loss: string | null; allocated: string; refunded: string; created_at: Date }>(
    'SELECT * FROM supervisor_case_summary ORDER BY priority, created_at DESC LIMIT 50');
  // JOIN + GROUP BY + HAVING + ORDER BY: mule accounts reached by more than one open case
  const mules = await query<{ account_ref: string; open_cases: string; disputed_inflow: string }>(
    `SELECT a.account_ref, COUNT(DISTINCT n.case_id) AS open_cases, SUM(n.inflow_amount) AS disputed_inflow
     FROM trace_nodes n JOIN transactions t ON t.txn_id = n.txn_id
     JOIN accounts a ON a.account_id = t.destination_account_id JOIN fraud_cases c ON c.case_id = n.case_id
     WHERE c.status IN ('INVESTIGATING', 'RECOVERY')
     GROUP BY a.account_ref HAVING COUNT(DISTINCT n.case_id) > 1 ORDER BY disputed_inflow DESC`);
  // Window function: investigator workload ranking
  const workload = await query<{ full_name: string; open_cases: string; workload_rank: string }>(
    `SELECT u.full_name, COUNT(*) AS open_cases, DENSE_RANK() OVER (ORDER BY COUNT(*) DESC) AS workload_rank
     FROM case_assignments ca JOIN users u ON u.user_id = ca.investigator_id JOIN fraud_cases c ON c.case_id = ca.case_id
     WHERE ca.ended_at IS NULL AND c.status NOT IN ('CLOSED', 'REJECTED')
     GROUP BY u.user_id, u.full_name ORDER BY workload_rank`);
  // Invariant console: each engine rule and how many parents currently violate it
  const rules = await query<{ name: string; rule: string; triggers: string; violations: string }>(
    `SELECT d.name,
            'SUM(' || d.child_table::text || '.' || d.child_quantity || COALESCE(' WHERE ' || d.status_column || ' IN ' || array_to_string(d.included_status, '/'), '')
              || ') ' || d.relation || ' ' || d.parent_table::text || '.' || d.parent_quantity AS rule,
            (SELECT COUNT(*) FROM pg_trigger t WHERE t.tgname LIKE 'inv\\_' || d.name || '\\_%') AS triggers,
            (SELECT COUNT(*) FROM verify_invariant(d.name)) AS violations
     FROM invariant_definitions d ORDER BY d.invariant_id`);

  return (
    <>
      <div className="grid">
        <div className="stat"><span className="muted">Reported</span><b>{inr(money.reported)}</b></div>
        <div className="stat"><span className="muted">Verified</span><b>{inr(money.verified)}</b></div>
        <div className="stat"><span className="muted">Allocated</span><b>{inr(money.allocated)}</b></div>
        <div className="stat"><span className="muted">Refunded</span><b>{inr(money.refunded)}</b></div>
        {totals.map(t => <div className="stat" key={t.status}><span className="muted">{t.status}</span><b>{t.n}</b></div>)}
      </div>

      <div className="card" style={{ marginTop: 20 }}>
        <h2>Invariant console</h2>
        <p className="muted">Each rule was registered once; the engine generated its lock, check and parent triggers.</p>
        <table>
          <thead><tr><th>Rule</th><th>Definition</th><th>Triggers</th><th>Current violations</th></tr></thead>
          <tbody>{rules.map(r => (
            <tr key={r.name}><td>{r.name}</td><td><code>{r.rule}</code></td><td>{r.triggers}</td>
              <td className={Number(r.violations) ? 'error' : 'ok'}>{r.violations}</td></tr>
          ))}</tbody>
        </table>
      </div>

      <div className="card">
        <h2>Cases (materialized view)</h2>
        <table>
          <thead><tr><th>Case</th><th>Status</th><th>Priority</th><th>Reported</th><th>Verified</th><th>Allocated</th><th>Refunded</th><th>Filed</th></tr></thead>
          <tbody>{summary.map(s => (
            <tr key={s.case_id}><td>#{s.case_id}</td><td><span className="badge">{s.status}</span></td><td>{s.priority}</td>
              <td>{inr(s.reported_amount)}</td><td>{inr(s.verified_loss)}</td><td>{inr(s.allocated)}</td>
              <td>{inr(s.refunded)}</td><td>{when(s.created_at)}</td></tr>
          ))}
          {summary.length === 0 && <tr><td colSpan={8} className="muted">No cases yet.</td></tr>}</tbody>
        </table>
      </div>

      <div className="card">
        <h2>Shared mule accounts</h2>
        <table>
          <thead><tr><th>Account</th><th>Open cases</th><th>Disputed inflow</th></tr></thead>
          <tbody>{mules.map(m => <tr key={m.account_ref}><td>{m.account_ref}</td><td>{m.open_cases}</td><td>{inr(m.disputed_inflow)}</td></tr>)}
          {mules.length === 0 && <tr><td colSpan={3} className="muted">No account is shared by two open cases.</td></tr>}</tbody>
        </table>
        <h3>Investigator workload</h3>
        <table>
          <thead><tr><th>Rank</th><th>Investigator</th><th>Open cases</th></tr></thead>
          <tbody>{workload.map(w => <tr key={w.full_name}><td>{w.workload_rank}</td><td>{w.full_name}</td><td>{w.open_cases}</td></tr>)}
          {workload.length === 0 && <tr><td colSpan={3} className="muted">No open assignments.</td></tr>}</tbody>
        </table>
      </div>
    </>
  );
}
