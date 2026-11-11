// FR-02: customer saves a draft complaint. Every answer of the wizard is kept (transfer, amount, type, story).
// The trigger check_draft refuses a transfer the customer did not make (TP005).
import { route } from '@/lib/api';
import { withTx } from '@/lib/db';
import { DraftBody } from '@/lib/drafts';

export const POST = route(['CUSTOMER'], DraftBody, ({ user, body }) =>
  withTx(user, async c => {
    const r = await c.query(
      `INSERT INTO draft_complaints (customer_id, disputed_txn_id, narrative, reported_amount, scam_type)
       VALUES ($1, $2, $3, $4, $5) RETURNING draft_id`,
      [user.id, body.disputedTxnId ?? null, body.narrative, body.reportedAmount ?? null, body.scamType || null]);
    return { draftId: r.rows[0].draft_id };
  }));
