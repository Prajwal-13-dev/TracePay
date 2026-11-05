// Public sign-up. Always creates a CUSTOMER (the DB trigger force_customer_role enforces it too).
import { NextResponse } from 'next/server';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { query } from '@/lib/db';
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
    await query('INSERT INTO users (email, full_name, phone, password_hash) VALUES ($1, $2, $3, $4)',
                [b.email, b.fullName, b.phone || null, hash]);
    return NextResponse.json({ ok: true }, { status: 201 });
  } catch (e) {
    return toResponse(e);
  }
}
