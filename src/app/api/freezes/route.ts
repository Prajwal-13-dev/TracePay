// FR-12: investigator requests a freeze on an account the case's trace reached.
import { z } from 'zod';
import { route, assertAssigned, id, money } from '@/lib/api';
import { withTx } from '@/lib/db';

export const POST = route(['INVESTIGATOR'], z.object({ caseId: id, accountId: id, amount: money }), ({ user, body }) =>
  withTx(user, async c => {
    await assertAssigned(c, body.caseId, user);
    const r = await c.query('SELECT request_freeze($1, $2, $3, $4) AS freeze_id',
                            [body.caseId, body.accountId, body.amount, user.id]);
    return { freezeId: r.rows[0].freeze_id };
  }));
