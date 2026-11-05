// Server-side role checks. The proxy guards pages; every Route Handler checks AGAIN here,
// so hiding a button is never the only protection.
import 'server-only';
import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import { SESSION_COOKIE, verifySession, type Role, type SessionUser } from './session';

export class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

export async function getSession(): Promise<SessionUser | null> {
  return verifySession((await cookies()).get(SESSION_COOKIE)?.value);
}

// For Route Handlers: 401 if not signed in, 403 if the role is not allowed. No SQL runs before this.
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
