// FR-02: customer saves a draft complaint.
import { z } from 'zod';
import { route, id } from '@/lib/api';
import { withTx } from '@/lib/db';

const Body = z.object({ disputedTxnId: id.optional().or(z.literal('').transform(() => undefined)),
                        narrative: z.string().max(5000) });

export const POST = route(['CUSTOMER'], Body, ({ user, body }) =>
  withTx(user, async c => {
    const r = await c.query(
      'INSERT INTO draft_complaints (customer_id, disputed_txn_id, narrative) VALUES ($1, $2, $3) RETURNING draft_id',
      [user.id, body.disputedTxnId ?? null, body.narrative]);
    return { draftId: r.rows[0].draft_id };
  }));
