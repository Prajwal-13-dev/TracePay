// FR-07: start the trace (root node = disputed transfer, inflow = reported amount).
import { z } from 'zod';
import { route, idParam, assertAssigned } from '@/lib/api';
import { withTx } from '@/lib/db';

export const POST = route(['INVESTIGATOR'], z.object({}), ({ user, params }) =>
  withTx(user, async c => {
    const caseId = idParam(params);
    await assertAssigned(c, caseId, user);
    await c.query('CALL start_trace($1)', [caseId]);
  }));
