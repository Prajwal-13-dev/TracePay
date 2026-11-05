// FR-03: submit a complaint. The DB trigger check_complaint rejects someone else's transfer or an
// amount above the transfer (TP005); UNIQUE(disputed_txn_id) rejects a second case (23505).
import { z } from 'zod';
import { route, id, money } from '@/lib/api';
import { withTx } from '@/lib/db';
import { afterCaseInsert } from '@/lib/case-hooks';

const Body = z.object({
  disputedTxnId: id,
  reportedAmount: money,
  narrative: z.string().trim().min(30, 'describe what happened in at least 30 characters').max(5000),
  draftId: id.optional(),
});

export const POST = route(['CUSTOMER'], Body, ({ user, body }) =>
  withTx(user, async c => {
    const r = await c.query(
      `INSERT INTO fraud_cases (customer_id, disputed_txn_id, reported_amount, narrative)
       VALUES ($1, $2, $3, $4) RETURNING case_id`,
      [user.id, body.disputedTxnId, body.reportedAmount, body.narrative]);
    const caseId = r.rows[0].case_id as number;
    if (body.draftId) {
      await c.query('DELETE FROM draft_complaints WHERE draft_id = $1 AND customer_id = $2', [body.draftId, user.id]);
    }
    await afterCaseInsert(c, caseId, body.narrative);   // Phase 9 adds the embedding here
    return { caseId };
  }));
