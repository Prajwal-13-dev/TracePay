// FR-06: move a case. The trigger enforce_case_transition decides if this role may take this step (TP003)
// and records the optional note (shown to the customer, e.g. why a complaint was rejected).
import { z } from 'zod';
import { route, idParam, assertAssigned } from '@/lib/api';
import { withTx } from '@/lib/db';
import { HttpError } from '@/lib/auth';

const Body = z.object({
  to: z.enum(['UNDER_REVIEW', 'INVESTIGATING', 'RECOVERY', 'CLOSED', 'REJECTED']),
  note: z.string().trim().max(1000).optional(),
});

export const POST = route(['INVESTIGATOR', 'SUPERVISOR'], Body, ({ user, body, params }) =>
  withTx(user, async c => {
    const caseId = idParam(params);
    await assertAssigned(c, caseId, user);
    if (body.to === 'REJECTED' && !body.note) throw new HttpError(400, 'give the customer a reason for the rejection');
    if (body.note) await c.query("SELECT set_config('app.status_note', $1, true)", [body.note]);
    const r = await c.query('UPDATE fraud_cases SET status = $2 WHERE case_id = $1', [caseId, body.to]);
    if (!r.rowCount) throw new HttpError(404, 'case not found');
  }));
