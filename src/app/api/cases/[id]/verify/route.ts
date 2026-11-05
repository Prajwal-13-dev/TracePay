// FR-11: verify loss (CHECK verified_loss <= reported_amount; rule allocation_within_loss guards lowering).
import { z } from 'zod';
import { route, idParam, money } from '@/lib/api';
import { withTx } from '@/lib/db';

export const POST = route(['SUPERVISOR'], z.object({ amount: money }), ({ user, body, params }) =>
  withTx(user, async c => {
    await c.query('CALL verify_loss($1, $2, $3)', [idParam(params), body.amount, user.id]);
  }));
