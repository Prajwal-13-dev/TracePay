// One wrapper for every write endpoint: role check -> input validation (zod) -> handler -> error mapping.
import 'server-only';
import { NextResponse } from 'next/server';
import { z } from 'zod';
import type { PoolClient } from 'pg';
import { requireRole, HttpError } from './auth';
import { toResponse } from './errors';
import type { Role, SessionUser } from './session';

type Ctx<B> = { user: SessionUser; body: B; params: Record<string, string>; req: Request };

export function route<S extends z.ZodTypeAny>(roles: Role[], schema: S,
                                              fn: (ctx: Ctx<z.infer<S>>) => Promise<unknown>) {
  return async (req: Request, ctx: { params: Promise<Record<string, string>> }) => {
    try {
      const user = await requireRole(...roles);                       // 401 / 403 before any SQL
      const raw = req.method === 'DELETE' ? {} : await req.json().catch(() => ({}));
      const body = schema.parse(raw);                                  // 400 on bad input
      const params = (await ctx?.params) ?? {};
      const out = await fn({ user, body, params, req });
      return NextResponse.json(out ?? { ok: true });
    } catch (e) {
      return toResponse(e);
    }
  };
}

export const idParam = (params: Record<string, string>, key = 'id') => {
  const n = Number(params[key]);
  if (!Number.isInteger(n) || n <= 0) throw new HttpError(400, 'bad ' + key);
  return n;
};

export const money = z.coerce.number().positive().max(1e12).multipleOf(0.01);
export const id = z.coerce.number().int().positive();

// Investigators may act only on cases currently assigned to them.
export async function assertAssigned(c: PoolClient, caseId: number, user: SessionUser) {
  if (user.role !== 'INVESTIGATOR') return;
  const r = await c.query(
    'SELECT 1 FROM case_assignments WHERE case_id = $1 AND investigator_id = $2 AND ended_at IS NULL',
    [caseId, user.id]);
  if (!r.rowCount) throw new HttpError(403, 'this case is not assigned to you');
}
