// FR-13: allocate frozen funds. Traced-amount cap + rules allocation_within_freeze / _within_loss.
import { z } from 'zod';
import { route, id, money } from '@/lib/api';
import { withTx } from '@/lib/db';

export const POST = route(['SUPERVISOR'], z.object({ freezeId: id, caseId: id, amount: money }), ({ user, body }) =>
  withTx(user, async c => {
    const r = await c.query('SELECT allocate_recovery($1, $2, $3, $4) AS allocation_id',
                            [body.freezeId, body.caseId, body.amount, user.id]);
    return { allocationId: r.rows[0].allocation_id };
  }));
