import { requirePageRole } from '@/lib/auth';
import { query } from '@/lib/db';
import UsersAdmin, { type UserRow } from '@/components/UsersAdmin';

const ROLES = ['CUSTOMER', 'INVESTIGATOR', 'SUPERVISOR'];
const PAGE = 50;

export default async function UsersPage({ searchParams }: { searchParams: Promise<{ role?: string; q?: string; inactive?: string; page?: string }> }) {
  const me = await requirePageRole('SUPERVISOR');
  const sp = await searchParams;
  // Default view: staff only (customers are many). 'all' shows everyone.
  const view = sp.role === 'all' ? 'all' : sp.role && ROLES.includes(sp.role) ? sp.role : 'staff';
  const role = ROLES.includes(view) ? view : null;
  const q = sp.q?.trim() || null;
  const page = Math.max(1, Number(sp.page) || 1);
  const users = await query<UserRow>(
    `SELECT u.user_id::int AS id, u.email, u.full_name AS name, u.phone, u.role, u.is_active AS active, u.created_at::text,
            (SELECT count(*) FROM case_assignments a JOIN fraud_cases c USING (case_id)
             WHERE a.investigator_id = u.user_id AND a.ended_at IS NULL AND c.status NOT IN ('CLOSED', 'REJECTED'))::int AS open_cases,
            (SELECT string_agg(account_ref, ', ' ORDER BY account_ref) FROM accounts a WHERE a.user_id = u.user_id) AS accounts,
            count(*) OVER ()::int AS total
     FROM users u
     WHERE ($1::user_role IS NULL OR u.role = $1)
       AND ($4 <> 'staff' OR u.role <> 'CUSTOMER')
       AND ($2::text IS NULL OR u.full_name ILIKE '%' || $2 || '%' OR u.email ILIKE '%' || $2 || '%')
       AND ($3 OR u.is_active)
     ORDER BY CASE u.role WHEN 'SUPERVISOR' THEN 1 WHEN 'INVESTIGATOR' THEN 2 ELSE 3 END, u.full_name
     LIMIT ${PAGE} OFFSET $5`, [role, q, sp.inactive === '1', view, (page - 1) * PAGE]);
  const total = users[0]?.total ?? 0;
  const [counts] = await query<{ customers: number; investigators: number; supervisors: number; inactive: number }>(
    `SELECT count(*) FILTER (WHERE role = 'CUSTOMER' AND is_active)::int AS customers,
            count(*) FILTER (WHERE role = 'INVESTIGATOR' AND is_active)::int AS investigators,
            count(*) FILTER (WHERE role = 'SUPERVISOR' AND is_active)::int AS supervisors,
            count(*) FILTER (WHERE NOT is_active)::int AS inactive FROM users`);

  return (
    <>
      <div className="page-head"><div><h1>Users</h1>
        <p>Create staff accounts, change roles and deactivate people. Every change is recorded in the audit log.</p></div></div>
      <div className="grid" style={{ marginBottom: 20 }}>
        <div className="stat t-accent"><span className="muted">Supervisors</span><b>{counts.supervisors}</b></div>
        <div className="stat t-violet"><span className="muted">Investigators</span><b>{counts.investigators}</b></div>
        <div className="stat t-ok"><span className="muted">Customers</span><b>{counts.customers}</b></div>
        <div className="stat t-warn"><span className="muted">Deactivated</span><b>{counts.inactive}</b></div>
      </div>
      <UsersAdmin users={users} meId={me.id} total={total} page={page} pageSize={PAGE}
                  filters={{ role: view, q: q ?? '', inactive: sp.inactive === '1' }} />
    </>
  );
}
