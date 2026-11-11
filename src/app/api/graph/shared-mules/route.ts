// Accounts that two or more open cases' money reaches (Neo4j multi-source path query).
import { NextResponse } from 'next/server';
import { requireRole } from '@/lib/auth';
import { toResponse } from '@/lib/errors';
import { sharedMules } from '@/lib/graph';

export async function GET() {
  try {
    await requireRole('INVESTIGATOR', 'SUPERVISOR');
    const rows = await sharedMules();
    if (rows === null) return NextResponse.json({ error: 'graph service offline' }, { status: 503 });
    return NextResponse.json(rows);
  } catch (e) {
    return toResponse(e);
  }
}
