// Recipient check before sending money: account number -> owner's name (masked for customers).
import { NextResponse } from 'next/server';
import { requireRole } from '@/lib/auth';
import { query } from '@/lib/db';
import { toResponse } from '@/lib/errors';

const mask = (name: string) => name.split(/\s+/).map(w => w[0] + '*'.repeat(Math.max(0, w.length - 1))).join(' ');

export async function GET(req: Request) {
  try {
    const user = await requireRole('CUSTOMER', 'SUPERVISOR');
    const ref = new URL(req.url).searchParams.get('ref')?.trim().toUpperCase() ?? '';
    if (!/^TP[0-9]{10}$/.test(ref)) return NextResponse.json({ error: 'account number looks like TP0000000000' }, { status: 400 });
    const [a] = await query<{ account_ref: string; full_name: string; status: string }>(
      'SELECT a.account_ref, u.full_name, a.status FROM accounts a JOIN users u USING (user_id) WHERE a.account_ref = $1', [ref]);
    if (!a) return NextResponse.json({ error: 'no account with that number' }, { status: 404 });
    return NextResponse.json({ ref: a.account_ref, owner: user.role === 'SUPERVISOR' ? a.full_name : mask(a.full_name), status: a.status });
  } catch (e) {
    return toResponse(e);
  }
}
