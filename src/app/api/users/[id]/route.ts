// Supervisor changes a user's role, deactivates/reactivates them, or sets a new password.
// Rules (enforced by trigger guard_user_update): supervisors only, never yourself,
// never the last active supervisor. Deactivating an investigator ends their open assignments.
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { route, idParam } from '@/lib/api';
import { withTx } from '@/lib/db';
import { HttpError } from '@/lib/auth';

const Body = z.object({
  role: z.enum(['CUSTOMER', 'INVESTIGATOR', 'SUPERVISOR']).optional(),
  active: z.boolean().optional(),
  password: z.string().min(8, 'at least 8 characters').max(200).optional(),
});

export const PATCH = route(['SUPERVISOR'], Body, async ({ user, body, params }) => {
  const id = idParam(params);
  if (body.role === undefined && body.active === undefined && body.password === undefined) {
    throw new HttpError(400, 'nothing to change');
  }
  const hash = body.password ? await bcrypt.hash(body.password, 12) : null;
  return withTx(user, async c => {
    if (body.role !== undefined) await c.query('CALL set_user_role($1, $2)', [id, body.role]);
    if (body.active !== undefined) await c.query('CALL set_user_active($1, $2)', [id, body.active]);
    if (hash) await c.query('CALL set_user_password($1, $2)', [id, hash]);
  });
});
