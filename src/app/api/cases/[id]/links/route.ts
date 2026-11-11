// FR-08: confirm a fund-flow link. Rules txn_capacity and node_outflow can reject it (TP001 + excess).
import { z } from 'zod';
import { route, idParam, assertAssigned, id, money } from '@/lib/api';
import { withTx } from '@/lib/db';

const Body = z.object({ fromTxn: id, toTxn: id, amount: money, method: z.enum(['MANUAL', 'FIFO']) });

export const POST = route(['INVESTIGATOR'], Body, ({ user, body, params }) =>
  withTx(user, async c => {
    const caseId = idParam(params);
    await assertAssigned(c, caseId, user);
    await c.query('CALL confirm_link($1, $2, $3, $4, $5, $6)',
                  [caseId, body.fromTxn, body.toTxn, body.amount, body.method, user.id]);
  }));
