// FR-14: exactly-once refund. The client sends an Idempotency-Key header; a replay returns the same refund.
import { z } from 'zod';
import { route, id, money } from '@/lib/api';
import { withTx } from '@/lib/db';
import { HttpError } from '@/lib/auth';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const POST = route(['SUPERVISOR'], z.object({ allocationId: id, amount: money }), ({ user, body, req }) =>
  withTx(user, async c => {
    const key = req.headers.get('Idempotency-Key') ?? '';
    if (!UUID.test(key)) throw new HttpError(400, 'Idempotency-Key header (uuid) is required');
    const r = await c.query('SELECT process_refund($1, $2, $3, $4) AS refund_id',
                            [body.allocationId, body.amount, key, user.id]);
    return { refundId: r.rows[0].refund_id };
  }));
