import { requirePageRole } from '@/lib/auth';
import { query } from '@/lib/db';
import Link from 'next/link';
import { inr, when } from '@/lib/format';
import StatusBadge, { statusLabel } from '@/components/StatusBadge';

export default async function SupervisorDashboard() {
  await requirePageRole('SUPERVISOR');
  await query('SELECT refresh_case_summary()');   // refreshes the materialized view only if its data changed

  const totals = await query<{ status: string; n: string }>(
    'SELECT status, COUNT(*) AS n FROM supervisor_case_summary GROUP BY status ORDER BY status');
  const [money] = await query<{ reported: string; verified: string; allocated: string; refunded: string }>(
    `SELECT COALESCE(SUM(reported_amount),0) AS reported, COALESCE(SUM(verified_loss),0) AS verified,
            COALESCE(SUM(allocated),0) AS allocated, COALESCE(SUM(refunded),0) AS refunded FROM supervisor_case_summary`);
  const summary = await query<{ case_id: string; status: string; priority: number; reported_amount: string;
    verified_loss: string | null; allocated: string; refunded: string; created_at: Date }>(
    'SELECT * FROM supervisor_case_summary ORDER BY created_at DESC, case_id DESC LIMIT 8');
  // Work waiting for a supervisor, each with the page that handles it.
  const [todo] = await query<{ to_review: string; unassigned: string; freeze_requests: string; to_verify: string; to_allocate: string }>(
    `SELECT (SELECT COUNT(*) FROM fraud_cases WHERE status = 'SUBMITTED') AS to_review,
            (SELECT COUNT(*) FROM fraud_cases c WHERE c.status = 'UNDER_REVIEW' AND NOT EXISTS
               (SELECT 1 FROM case_assignments a WHERE a.case_id = c.case_id AND a.ended_at IS NULL)) AS unassigned,
            (SELECT COUNT(*) FROM account_freezes WHERE status = 'REQUESTED') AS freeze_requests,
            (SELECT COUNT(*) FROM fraud_cases WHERE status = 'INVESTIGATING' AND verified_loss IS NULL) AS to_verify,
            (SELECT COUNT(*) FROM fraud_cases c WHERE c.status = 'RECOVERY' AND NOT EXISTS
               (SELECT 1 FROM recovery_allocations r WHERE r.case_id = c.case_id AND r.status <> 'CANCELLED')) AS to_allocate`);
  const [frozen] = await query<{ active: string; amount: string }>(
    "SELECT COUNT(*) AS active, COALESCE(SUM(frozen_amount), 0) AS amount FROM account_freezes WHERE status = 'ACTIVE'");
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

  const n = (v: string | number) => Number(v);
  const totalCases = totals.reduce((a, t) => a + n(t.n), 0);
  const STATUS_ORDER = ['SUBMITTED', 'UNDER_REVIEW', 'INVESTIGATING', 'RECOVERY', 'CLOSED', 'REJECTED'];
  const STATUS_COLOR: Record<string, string> = { SUBMITTED: '#98a2b3', UNDER_REVIEW: '#6941c6', INVESTIGATING: '#1f5fbf',
    RECOVERY: '#d97706', CLOSED: '#067647', REJECTED: '#b42318' };
  const byStatus = STATUS_ORDER.map(s => ({ s, n: n(totals.find(t => t.status === s)?.n ?? 0) }));
  const maxStatus = Math.max(1, ...byStatus.map(b => b.n));
  const funnel = [
    { label: 'Reported', v: n(money.reported), c: '#98a2b3' }, { label: 'Verified', v: n(money.verified), c: '#6941c6' },
    { label: 'Allocated', v: n(money.allocated), c: '#d97706' }, { label: 'Refunded', v: n(money.refunded), c: '#067647' },
  ];
  const maxF = Math.max(1, funnel[0].v);
  const recoveryRate = n(money.verified) > 0 ? Math.round(100 * n(money.refunded) / n(money.verified)) : 0;
  const TODO = [
    { label: 'New complaints to review', count: todo.to_review, href: '/supervisor/cases?status=SUBMITTED' },
    { label: 'Cases waiting for an investigator', count: todo.unassigned, href: '/supervisor/cases?status=UNDER_REVIEW&assigned=no' },
    { label: 'Freeze requests to approve', count: todo.freeze_requests, href: '/supervisor/freezes?tab=requests' },
    { label: 'Losses to verify', count: todo.to_verify, href: '/supervisor/cases?status=INVESTIGATING' },
    { label: 'Recovery cases with no allocation', count: todo.to_allocate, href: '/supervisor/freezes?tab=active' },
  ];
  const violations = rules.reduce((a, r) => a + n(r.violations), 0);

  return (
    <>
      <div className="page-head"><div><h1>Dashboard</h1><p>Recovery at a glance, and what needs your decision.</p></div></div>

      <div className="grid" style={{ marginBottom: 20 }}>
        <div className="stat t-accent"><span className="muted">Cases</span><b>{totalCases}</b>
          <small>{totalCases - n(totals.find(t => t.status === 'CLOSED')?.n ?? 0) - n(totals.find(t => t.status === 'REJECTED')?.n ?? 0)} open</small></div>
        <div className="stat t-warn"><span className="muted">Reported losses</span><b>{inr(money.reported)}</b><small>{inr(money.verified)} verified</small></div>
        <div className="stat t-violet"><span className="muted">Frozen now</span><b>{inr(frozen.amount)}</b><small>{frozen.active} active freezes</small></div>
        <div className="stat t-ok"><span className="muted">Refunded</span><b>{inr(money.refunded)}</b><small>{recoveryRate}% of verified losses</small></div>
      </div>

      <div className="grid-2" style={{ marginBottom: 20 }}>
        <div className="card">
          <h2>Needs your attention</h2>
          <div className="todo">{TODO.map(t => (
            <Link key={t.label} className="item" href={t.href}><span>{t.label}</span>
              <span className={'count' + (n(t.count) ? '' : ' zero')}>{t.count}</span></Link>
          ))}</div>
        </div>
        <div className="card">
          <h2>Cases by status</h2>
          <div className="bars">{byStatus.map(b => (
            <Link key={b.s} href={`/supervisor/cases?status=${b.s}`} className="bar-row" style={{ color: 'inherit' }}>
              <span>{statusLabel(b.s)}</span>
              <span className="track"><span style={{ width: `${100 * b.n / maxStatus}%`, background: STATUS_COLOR[b.s] }} /></span>
              <span className="val">{b.n}</span>
            </Link>
          ))}</div>
        </div>
      </div>

      <div className="card">
        <div className="card-head"><h2>Money through the recovery pipeline</h2>
          <span className="muted">Each stage is limited by the one before it (enforced by the constraint engine)</span></div>
        <div className="funnel">{funnel.map(f => (
          <div className="step" key={f.label}><span>{f.label}</span>
            <span><span className="fill" style={{ display: 'block', width: `${100 * f.v / maxF}%`, background: f.c }} /></span>
            <span className="amt">{inr(f.v)}</span></div>
        ))}</div>
      </div>

      <div className="card">
        <div className="card-head"><h2>Latest cases</h2><Link href="/supervisor/cases">All cases →</Link></div>
        <div className="table-wrap"><table>
          <thead><tr><th>Case</th><th>Status</th><th>Priority</th><th>Reported</th><th>Verified</th><th>Allocated</th><th>Refunded</th><th>Filed</th></tr></thead>
          <tbody>{summary.map(s => (
            <tr key={s.case_id}><td><Link href={`/supervisor/cases/${s.case_id}`}>#{s.case_id}</Link></td><td><StatusBadge status={s.status} /></td><td><span className={`prio prio-${s.priority}`}>{s.priority}</span></td>
              <td>{inr(s.reported_amount)}</td><td>{inr(s.verified_loss)}</td><td>{inr(s.allocated)}</td>
              <td>{inr(s.refunded)}</td><td>{when(s.created_at)}</td></tr>
          ))}
          {summary.length === 0 && <tr><td colSpan={8} className="empty">No cases yet.</td></tr>}</tbody>
        </table></div>
      </div>

      <div className="grid-2" style={{ marginBottom: 20 }}>
        <div className="card">
          <h2>Shared mule accounts</h2>
          <p className="muted">Accounts holding confirmed money from two or more open cases.</p>
          <table>
            <thead><tr><th>Account</th><th>Open cases</th><th>Disputed inflow</th></tr></thead>
            <tbody>{mules.map(m => <tr key={m.account_ref}><td>{m.account_ref}</td><td>{m.open_cases}</td><td>{inr(m.disputed_inflow)}</td></tr>)}
            {mules.length === 0 && <tr><td colSpan={3} className="empty">No account is shared by two open cases.</td></tr>}</tbody>
          </table>
        </div>
        <div className="card">
          <h2>Investigator workload</h2>
          <table>
            <thead><tr><th>Rank</th><th>Investigator</th><th>Open cases</th></tr></thead>
            <tbody>{workload.map(w => <tr key={w.full_name}><td>{w.workload_rank}</td><td>{w.full_name}</td><td>{w.open_cases}</td></tr>)}
            {workload.length === 0 && <tr><td colSpan={3} className="empty">No open assignments.</td></tr>}</tbody>
          </table>
        </div>
      </div>

      <div className="card">
        <div className="card-head"><h2>Money rules (constraint engine)</h2>
          <span className={'badge ' + (violations ? 's-REJECTED' : 's-CLOSED')}>{violations ? `${violations} violations` : 'All rules hold'}</span></div>
        <p className="muted">Each rule was registered once; the engine generated its lock, check and parent triggers.</p>
        <div className="table-wrap"><table>
          <thead><tr><th>Rule</th><th>Definition</th><th>Triggers</th><th>Current violations</th></tr></thead>
          <tbody>{rules.map(r => (
            <tr key={r.name}><td>{r.name}</td><td><code>{r.rule}</code></td><td>{r.triggers}</td>
              <td className={Number(r.violations) ? 'error' : 'ok'}>{r.violations}</td></tr>
          ))}</tbody>
        </table></div>
      </div>
    </>
  );
}
