// Supervisor-only: proves role checks on the API (customer -> 403) and reads the materialized view.
import { NextResponse } from 'next/server';
import { requireRole } from '@/lib/auth';
import { query } from '@/lib/db';
import { toResponse } from '@/lib/errors';

export async function GET() {
  try {
    await requireRole('SUPERVISOR');
    await query('REFRESH MATERIALIZED VIEW CONCURRENTLY supervisor_case_summary');
    const rows = await query('SELECT * FROM supervisor_case_summary ORDER BY case_id');
    return NextResponse.json(rows);
  } catch (e) {
    return toResponse(e);
  }
}
