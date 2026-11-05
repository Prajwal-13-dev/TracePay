// FR-02: edit or DELETE a draft. Ownership is part of the WHERE clause: another customer's draft -> 404.
import { z } from 'zod';
import { route, idParam } from '@/lib/api';
import { withTx } from '@/lib/db';
import { HttpError } from '@/lib/auth';

export const PATCH = route(['CUSTOMER'], z.object({ narrative: z.string().max(5000) }), ({ user, body, params }) =>
  withTx(user, async c => {
    const r = await c.query('UPDATE draft_complaints SET narrative = $3 WHERE draft_id = $1 AND customer_id = $2',
                            [idParam(params), user.id, body.narrative]);
    if (!r.rowCount) throw new HttpError(404, 'draft not found');
  }));

export const DELETE = route(['CUSTOMER'], z.object({}), ({ user, params }) =>
  withTx(user, async c => {
    const r = await c.query('DELETE FROM draft_complaints WHERE draft_id = $1 AND customer_id = $2',
                            [idParam(params), user.id]);
    if (!r.rowCount) throw new HttpError(404, 'draft not found');
  }));
