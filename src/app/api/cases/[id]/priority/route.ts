// Supervisor sets a case's priority (1 = most urgent). Audited by the fraud_cases audit trigger.
import { z } from 'zod';
import { route, idParam } from '@/lib/api';
import { withTx } from '@/lib/db';
import { HttpError } from '@/lib/auth';

export const PATCH = route(['SUPERVISOR'], z.object({ priority: z.coerce.number().int().min(1).max(5) }), ({ user, body, params }) =>
  withTx(user, async c => {
    const r = await c.query('UPDATE fraud_cases SET priority = $2 WHERE case_id = $1', [idParam(params), body.priority]);
    if (!r.rowCount) throw new HttpError(404, 'case not found');
  }));
