// Send money (record_transfer). Customers: from their own account, now. Supervisors: between any two
// accounts, optionally backdated (to build demo laundering chains). The trigger apply_transfer moves
// the money and refuses overdrafts, frozen money and closed accounts.
import { z } from 'zod';
import { route, money } from '@/lib/api';
import { withTx } from '@/lib/db';

const Ref = z.string().trim().toUpperCase().regex(/^TP[0-9]{10}$/, 'account number looks like TP0000000000');
const Body = z.object({
  fromRef: Ref,
  toRef: Ref,
  amount: money,
  channel: z.enum(['UPI', 'IMPS', 'NEFT', 'CARD']),
  occurredAt: z.string().datetime({ offset: true }).optional().or(z.literal('').transform(() => undefined)),
});

export const POST = route(['CUSTOMER', 'SUPERVISOR'], Body, ({ user, body }) =>
  withTx(user, async c => {
    // Two statements: a function in WHERE would run once per row scanned (sending money many times), and the
    // row it inserts is not visible to the rest of the statement that called it.
    const x = await c.query('SELECT record_transfer($1, $2, $3, $4, $5) AS id',
                            [body.fromRef, body.toRef, body.amount, body.channel, body.occurredAt ?? null]);
    const r = await c.query('SELECT txn_id::int, external_ref, amount, occurred_at FROM transactions WHERE txn_id = $1', [x.rows[0].id]);
    const t = r.rows[0];
    return { txnId: t.txn_id, ref: t.external_ref, amount: t.amount, occurredAt: t.occurred_at };
  }));
