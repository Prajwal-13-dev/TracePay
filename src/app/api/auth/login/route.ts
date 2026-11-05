import { NextResponse } from 'next/server';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { query } from '@/lib/db';
import { toResponse } from '@/lib/errors';
import { SESSION_COOKIE, cookieOptions, homeFor, signSession, type Role } from '@/lib/session';

const Body = z.object({ email: z.string().trim().email().max(200), password: z.string().min(1).max(200) });

export async function POST(req: Request) {
  try {
    const { email, password } = Body.parse(await req.json());
    const rows = await query<{ user_id: string; full_name: string; email: string; password_hash: string;
                               role: Role; is_active: boolean }>(
      'SELECT user_id, full_name, email, password_hash, role, is_active FROM users WHERE email = $1', [email]);
    const u = rows[0];
    // Same message for unknown email and wrong password: do not reveal which accounts exist.
    if (!u || !u.is_active || !(await bcrypt.compare(password, u.password_hash))) {
      return NextResponse.json({ error: 'wrong email or password' }, { status: 401 });
    }
    const user = { id: Number(u.user_id), role: u.role, name: u.full_name, email: u.email };
    const res = NextResponse.json({ ok: true, role: user.role, home: homeFor(user.role) });
    res.cookies.set(SESSION_COOKIE, await signSession(user), cookieOptions);
    return res;
  } catch (e) {
    return toResponse(e);
  }
}
