// The assigned investigator hands a case back (procedure hand_back_case): allowed before accepting it, or while
// investigating if no link or freeze is confirmed yet. The case waits for a supervisor to reassign it.
import { z } from 'zod';
import { route, idParam } from '@/lib/api';
import { withTx } from '@/lib/db';

export const POST = route(['INVESTIGATOR'], z.object({ reason: z.string().trim().min(5, 'say why (5+ characters)').max(500) }),
  ({ user, body, params }) =>
    withTx(user, async c => {
      await c.query('CALL hand_back_case($1, $2)', [idParam(params), body.reason]);
    }));
