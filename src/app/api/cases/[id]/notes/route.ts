// UPDATE demonstration: investigator notes (search_vector regenerates itself).
import { z } from 'zod';
import { route, idParam, assertAssigned } from '@/lib/api';
import { withTx } from '@/lib/db';

export const PATCH = route(['INVESTIGATOR'], z.object({ notes: z.string().max(5000) }), ({ user, body, params }) =>
  withTx(user, async c => {
    const caseId = idParam(params);
    await assertAssigned(c, caseId, user);
    await c.query('UPDATE fraud_cases SET investigator_notes = $2 WHERE case_id = $1', [caseId, body.notes]);
  }));
