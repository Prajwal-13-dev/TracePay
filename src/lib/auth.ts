// Server-side role checks. The proxy guards pages; every Route Handler checks AGAIN here,
// so hiding a button is never the only protection.
// The signed cookie says who you are; your role and active flag are re-read from the database on
// every request, so a role change or deactivation by a supervisor takes effect immediately.
import 'server-only';
import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import { query } from './db';
import { SESSION_COOKIE, verifySession, type Role, type SessionUser } from './session';

export class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

export async function getSession(): Promise<SessionUser | null> {
  const token = await verifySession((await cookies()).get(SESSION_COOKIE)?.value);
  if (!token) return null;
  const [u] = await query<{ role: Role; full_name: string; email: string }>(
    'SELECT role, full_name, email FROM users WHERE user_id = $1 AND is_active', [token.id]);
  if (!u) return null;                               // deactivated or deleted: treated as signed out
  return { id: token.id, role: u.role, name: u.full_name, email: u.email };
}

// For Route Handlers: 401 if not signed in, 403 if the role is not allowed. No SQL runs before this
// except the session lookup itself.
export async function requireRole(...roles: Role[]): Promise<SessionUser> {
  const user = await getSession();
  if (!user) throw new HttpError(401, 'not signed in');
  if (!roles.includes(user.role)) throw new HttpError(403, 'role ' + user.role + ' may not do this');
  return user;
}

// For pages: redirect instead of throwing.
export async function requirePageRole(...roles: Role[]): Promise<SessionUser> {
  const user = await getSession();
  if (!user) redirect('/login');
  if (!roles.includes(user.role)) redirect('/login?denied=1');
  return user;
}
