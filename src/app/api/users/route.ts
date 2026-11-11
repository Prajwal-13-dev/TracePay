// Supervisor user management: list users, create a user with any role.
// The database decides who may create staff (create_user + trigger force_customer_role).
import { NextResponse } from 'next/server';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { route } from '@/lib/api';
import { requireRole } from '@/lib/auth';
import { query, withTx, DEMO_OPENING_BALANCE } from '@/lib/db';
import { toResponse } from '@/lib/errors';

const ROLES = ['CUSTOMER', 'INVESTIGATOR', 'SUPERVISOR'] as const;

export async function GET(req: Request) {
  try {
    await requireRole('SUPERVISOR');
    const u = new URL(req.url);
    const role = u.searchParams.get('role');
    const q = u.searchParams.get('q')?.trim();
    const rows = await query(
      `SELECT user_id::int, email, full_name, phone, role, is_active, created_at
       FROM users
       WHERE ($1::user_role IS NULL OR role = $1) AND ($2::text IS NULL OR full_name ILIKE '%' || $2 || '%' OR email ILIKE '%' || $2 || '%')
       ORDER BY role, full_name LIMIT 200`,
      [role && (ROLES as readonly string[]).includes(role) ? role : null, q || null]);
    return NextResponse.json(rows);
  } catch (e) {
    return toResponse(e);
  }
}

const Body = z.object({
  fullName: z.string().trim().min(2).max(100),
  email: z.string().trim().email().max(200),
  phone: z.string().regex(/^[6-9][0-9]{9}$/, '10-digit Indian mobile number').optional().or(z.literal('')),
  role: z.enum(ROLES),
  password: z.string().min(8, 'at least 8 characters').max(200),
});

export const POST = route(['SUPERVISOR'], Body, async ({ user, body }) => {
  const hash = await bcrypt.hash(body.password, 12);
  return withTx(user, async c => {
    const r = await c.query('SELECT create_user($1, $2, $3, $4, $5) AS user_id',
                            [body.email, body.fullName, body.phone || null, hash, body.role]);
    const userId = Number(r.rows[0].user_id);
    // Customers get a bank account straight away (same as public sign-up).
    if (body.role === 'CUSTOMER') await c.query('SELECT open_account($1, $2)', [userId, DEMO_OPENING_BALANCE]);
    return { userId };
  });
});
