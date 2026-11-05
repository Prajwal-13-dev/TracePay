// FR-06: move a case. The trigger enforce_case_transition decides if this role may take this step (TP003).
import { z } from 'zod';
import { route, idParam, assertAssigned } from '@/lib/api';
import { withTx } from '@/lib/db';
import { HttpError } from '@/lib/auth';

const Body = z.object({ to: z.enum(['UNDER_REVIEW', 'INVESTIGATING', 'RECOVERY', 'CLOSED', 'REJECTED']) });

export const POST = route(['INVESTIGATOR', 'SUPERVISOR'], Body, ({ user, body, params }) =>
  withTx(user, async c => {
    const caseId = idParam(params);
    await assertAssigned(c, caseId, user);
    const r = await c.query('UPDATE fraud_cases SET status = $2 WHERE case_id = $1', [caseId, body.to]);
    if (!r.rowCount) throw new HttpError(404, 'case not found');
  }));
