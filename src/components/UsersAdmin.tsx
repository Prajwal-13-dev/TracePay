'use client';
// Supervisor user management: add a user with any role, change roles, deactivate/reactivate, reset passwords.
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { friendlyError } from '@/lib/friendly';

export type UserRow = { id: number; email: string; name: string; phone: string | null; role: string; active: boolean;
                        created_at: string; open_cases: number; accounts: string | null; total: number };

const ROLES = [
  { value: 'CUSTOMER', label: 'Customer' },
  { value: 'INVESTIGATOR', label: 'Investigator' },
  { value: 'SUPERVISOR', label: 'Supervisor' },
];
const roleLabel = (r: string) => ROLES.find(x => x.value === r)?.label ?? r;

async function send(url: string, method: string, body: unknown) {
  const res = await fetch(url, { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const data = await res.json().catch(() => ({}));
  return res.ok ? { ok: true as const, data } : { ok: false as const, error: friendlyError(data, res.status) };
}

export default function UsersAdmin({ users, meId, filters, total, page, pageSize }: {
  users: UserRow[]; meId: number; filters: { role: string; q: string; inactive: boolean };
  total: number; page: number; pageSize: number;
}) {
  const pages = Math.max(1, Math.ceil(total / pageSize));
  const pageLink = (p: number) => '?' + new URLSearchParams({ role: filters.role, ...(filters.q ? { q: filters.q } : {}),
                                                              ...(filters.inactive ? { inactive: '1' } : {}), page: String(p) });
  const router = useRouter();
  const [showAdd, setShowAdd] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [busy, setBusy] = useState(false);

  async function addUser(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = e.currentTarget;
    const f = new FormData(form);
    setBusy(true); setMsg(null);
    const r = await send('/api/users', 'POST', {
      fullName: f.get('fullName'), email: f.get('email'), phone: f.get('phone'),
      role: f.get('role'), password: f.get('password'),
    });
    setBusy(false);
    if (!r.ok) { setMsg({ ok: false, text: r.error }); return; }
    setMsg({ ok: true, text: `${f.get('fullName')} was added as ${roleLabel(String(f.get('role')))}. They can sign in with the password you set.` });
    form.reset();
    setShowAdd(false);
    router.refresh();
  }

  return (
    <div className="card">
      <div className="card-head">
        <h2>Users <span className="muted" style={{ fontWeight: 400 }}>· {total} found</span></h2>
        <button type="button" onClick={() => { setShowAdd(!showAdd); setMsg(null); }}>{showAdd ? 'Cancel' : '+ Add user'}</button>
      </div>

      {showAdd && (
        <form className="add-user" onSubmit={addUser}>
          <div className="form-grid">
            <div><label htmlFor="u-name">Full name</label><input id="u-name" name="fullName" required minLength={2} maxLength={100} /></div>
            <div><label htmlFor="u-email">Email</label><input id="u-email" name="email" type="email" required /></div>
            <div><label htmlFor="u-phone">Mobile (optional)</label><input id="u-phone" name="phone" pattern="[6-9][0-9]{9}" placeholder="9876543210" /></div>
            <div><label htmlFor="u-role">Role</label>
              <select id="u-role" name="role" defaultValue="INVESTIGATOR">
                {ROLES.map(r => <option key={r.value} value={r.value}>{r.label}</option>)}
              </select></div>
            <div><label htmlFor="u-pw">Temporary password (8+ characters)</label>
              <input id="u-pw" name="password" type="text" required minLength={8} autoComplete="off" /></div>
          </div>
          <p className="muted">Customers added here also get a bank account. Share the temporary password with the person directly.</p>
          <button disabled={busy}>{busy ? 'Adding…' : 'Add user'}</button>
        </form>
      )}
      {msg && <p className={msg.ok ? 'ok' : 'error'} role="status">{msg.text}</p>}

      <form className="filters" method="get" style={{ marginTop: 14 }}>
        <div><label>Search</label><input name="q" defaultValue={filters.q} placeholder="Name or email" /></div>
        <div><label>Show</label>
          <select name="role" defaultValue={filters.role}>
            <option value="staff">Staff (investigators and supervisors)</option>
            {ROLES.map(r => <option key={r.value} value={r.value}>{r.label}s only</option>)}
            <option value="all">Everyone</option>
          </select></div>
        <div><label>Status</label>
          <select name="inactive" defaultValue={filters.inactive ? '1' : '0'}>
            <option value="0">Active only</option><option value="1">Include deactivated</option>
          </select></div>
        <button className="secondary">Filter</button>
      </form>

      <div className="table-wrap"><table style={{ marginTop: 16 }}>
        <thead><tr><th>Name</th><th>Role</th><th>Accounts / open cases</th><th>Status</th><th>Actions</th></tr></thead>
        <tbody>
          {users.map(u => <UserRowView key={u.id} u={u} isMe={u.id === meId} onDone={(text, ok) => { setMsg({ ok, text }); if (ok) router.refresh(); }} />)}
          {users.length === 0 && <tr><td colSpan={5} className="empty">No users match.</td></tr>}
        </tbody>
      </table></div>
      {pages > 1 && (
        <div className="pager">
          {page > 1 ? <a className="btn secondary" href={pageLink(page - 1)}>← Previous</a> : <span />}
          <span className="muted">Page {page} of {pages}</span>
          {page < pages ? <a className="btn secondary" href={pageLink(page + 1)}>Next →</a> : <span />}
        </div>
      )}
    </div>
  );
}

function UserRowView({ u, isMe, onDone }: { u: UserRow; isMe: boolean; onDone: (text: string, ok: boolean) => void }) {
  const [role, setRole] = useState(u.role);
  const [busy, setBusy] = useState(false);
  const [pwOpen, setPwOpen] = useState(false);

  async function patch(body: Record<string, unknown>, success: string, confirmText?: string) {
    if (confirmText && !window.confirm(confirmText)) return false;
    setBusy(true);
    const r = await send(`/api/users/${u.id}`, 'PATCH', body);
    setBusy(false);
    onDone(r.ok ? success : r.error, r.ok);
    return r.ok;
  }

  return (
    <tr style={u.active ? undefined : { opacity: 0.6 }}>
      <td><b>{u.name}</b>{isMe && <span className="badge" style={{ marginLeft: 6 }}>you</span>}
        <div className="muted">{u.email}{u.phone ? ` · ${u.phone}` : ''}</div></td>
      <td>
        {isMe ? roleLabel(u.role) : (
          <span className="inline-actions">
            <select value={role} onChange={e => setRole(e.target.value)} aria-label={`Role of ${u.name}`} disabled={busy}>
              {ROLES.map(r => <option key={r.value} value={r.value}>{r.label}</option>)}
            </select>
            {role !== u.role && (
              <button type="button" disabled={busy} onClick={async () => {
                const ok = await patch({ role }, `${u.name} is now ${roleLabel(role)}.`,
                  u.role === 'INVESTIGATOR' && u.open_cases > 0
                    ? `${u.name} has ${u.open_cases} open case(s). Changing the role unassigns them. Continue?` : undefined);
                if (!ok) setRole(u.role);
              }}>Save</button>
            )}
          </span>
        )}
      </td>
      <td className="muted">{u.accounts ?? '—'}{u.role === 'INVESTIGATOR' && <div>{u.open_cases} open case(s)</div>}</td>
      <td>{u.active ? <span className="badge s-ACTIVE">Active</span> : <span className="badge s-DECLINED">Deactivated</span>}</td>
      <td>
        {!isMe && (
          <span className="inline-actions">
            {u.active
              ? <button type="button" className="secondary" disabled={busy} onClick={() => patch({ active: false }, `${u.name} was deactivated and can no longer sign in.`,
                  `Deactivate ${u.name}? They are signed out at once${u.open_cases ? ` and their ${u.open_cases} open case(s) become unassigned` : ''}.`)}>Deactivate</button>
              : <button type="button" className="secondary" disabled={busy} onClick={() => patch({ active: true }, `${u.name} was reactivated.`)}>Reactivate</button>}
            <button type="button" className="ghost" disabled={busy} onClick={() => setPwOpen(!pwOpen)}>Reset password</button>
          </span>
        )}
        {pwOpen && (
          <form className="inline" style={{ marginTop: 6 }} onSubmit={async e => {
            e.preventDefault();
            const form = e.currentTarget;
            const pw = String(new FormData(form).get('password'));
            if (await patch({ password: pw }, `New password set for ${u.name}.`)) { form.reset(); setPwOpen(false); }
          }}>
            <div className="field"><input name="password" type="text" minLength={8} required placeholder="New password" aria-label="New password" autoComplete="off" /></div>
            <button disabled={busy}>Set</button>
          </form>
        )}
      </td>
    </tr>
  );
}
