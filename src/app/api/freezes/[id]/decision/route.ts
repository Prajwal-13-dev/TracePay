// FR-12: supervisor approves or declines. Four-eyes CHECK and rule freeze_within_balance apply.
import { z } from 'zod';
import { route, idParam } from '@/lib/api';
import { withTx } from '@/lib/db';

// approve must be a real JSON boolean: z.coerce.boolean() would turn the string "false" into true.
const Body = z.object({ approve: z.boolean(), days: z.coerce.number().int().min(1).max(90).default(7) });

export const POST = route(['SUPERVISOR'], Body, ({ user, body, params }) =>
  withTx(user, async c => {
    await c.query('CALL decide_freeze($1, $2, $3, now() + make_interval(days => $4))',
                  [idParam(params), body.approve, user.id, body.days]);
  }));
