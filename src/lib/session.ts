// Signed session cookie (JWT, HS256). HTTP-only, SameSite=Lax, Secure in production.
import { SignJWT, jwtVerify } from 'jose';

export type Role = 'CUSTOMER' | 'INVESTIGATOR' | 'SUPERVISOR';
export type SessionUser = { id: number; role: Role; name: string; email: string };

export const SESSION_COOKIE = 'tp_session';
const MAX_AGE = 60 * 60 * 8; // 8 hours

function key() {
  const secret = process.env.AUTH_SECRET;
  if (!secret || secret.length < 32) throw new Error('AUTH_SECRET must be set (32+ characters) in .env');
  return new TextEncoder().encode(secret);
}

export async function signSession(u: SessionUser): Promise<string> {
  return new SignJWT({ role: u.role, name: u.name, email: u.email })
    .setProtectedHeader({ alg: 'HS256' })
    .setSubject(String(u.id))
    .setIssuedAt()
    .setExpirationTime(`${MAX_AGE}s`)
    .sign(key());
}

export async function verifySession(token: string | undefined): Promise<SessionUser | null> {
  if (!token) return null;
  try {
    const { payload } = await jwtVerify(token, key(), { algorithms: ['HS256'] });
    return { id: Number(payload.sub), role: payload.role as Role,
             name: String(payload.name), email: String(payload.email) };
  } catch {
    return null;
  }
}

export const cookieOptions = {
  httpOnly: true,
  sameSite: 'lax' as const,
  secure: process.env.NODE_ENV === 'production',
  path: '/',
  maxAge: MAX_AGE,
};

export const homeFor = (role: Role) =>
  role === 'CUSTOMER' ? '/customer' : role === 'INVESTIGATOR' ? '/investigator' : '/supervisor';
