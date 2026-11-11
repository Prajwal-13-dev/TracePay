// Public sign-up. Always creates a CUSTOMER (create_user + trigger force_customer_role enforce it too)
// and opens the customer's first bank account in the same transaction, so they can send money at once.
import { NextResponse } from 'next/server';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { withTx, DEMO_OPENING_BALANCE } from '@/lib/db';
import { toResponse } from '@/lib/errors';

const Body = z.object({
  fullName: z.string().trim().min(2).max(100),
  email: z.string().trim().email().max(200),
  phone: z.string().regex(/^[6-9][0-9]{9}$/, '10-digit Indian mobile number').optional().or(z.literal('')),
  password: z.string().min(8, 'at least 8 characters').max(200),
});

export async function POST(req: Request) {
  try {
    const b = Body.parse(await req.json());
    const hash = await bcrypt.hash(b.password, 12);        // cost 12; plain text never stored or logged
    const accountRef = await withTx(null, async c => {
      const u = await c.query('SELECT create_user($1, $2, $3, $4) AS user_id', [b.email, b.fullName, b.phone || null, hash]);
      // Two statements: a function in WHERE would run once per row scanned, and a row inserted by a function
      // is not visible to the rest of the statement that called it.
      const o = await c.query('SELECT open_account($1, $2) AS id', [u.rows[0].user_id, DEMO_OPENING_BALANCE]);
      const a = await c.query('SELECT account_ref FROM accounts WHERE account_id = $1', [o.rows[0].id]);
      return a.rows[0].account_ref as string;
    });
    return NextResponse.json({ ok: true, accountRef }, { status: 201 });
  } catch (e) {
    return toResponse(e);
  }
}
