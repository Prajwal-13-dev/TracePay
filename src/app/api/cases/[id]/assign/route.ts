// FR-05: assign or reassign (procedure assign_case; trigger check_assignee rejects non-investigators).
import { z } from 'zod';
import { route, idParam, id } from '@/lib/api';
import { withTx } from '@/lib/db';

export const POST = route(['SUPERVISOR'], z.object({ investigatorId: id }), ({ user, body, params }) =>
  withTx(user, async c => {
    await c.query('CALL assign_case($1, $2, $3)', [idParam(params), body.investigatorId, user.id]);
  }));
