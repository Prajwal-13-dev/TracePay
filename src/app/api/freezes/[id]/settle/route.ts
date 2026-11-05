// FR-14: settle the freeze (cancel unpaid allocations, mark SETTLED, debit the account).
import { z } from 'zod';
import { route, idParam } from '@/lib/api';
import { withTx } from '@/lib/db';

export const POST = route(['SUPERVISOR'], z.object({}), ({ user, params }) =>
  withTx(user, async c => {
    const r = await c.query('SELECT settle_freeze($1, $2) AS paid', [idParam(params), user.id]);
    return { paid: r.rows[0].paid };
  }));
