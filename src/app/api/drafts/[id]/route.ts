// FR-02: edit or DELETE a draft. Ownership is part of the WHERE clause: another customer's draft -> 404.
// Sending disputedTxnId: null clears the chosen transfer.
import { z } from 'zod';
import { route, idParam } from '@/lib/api';
import { withTx } from '@/lib/db';
import { HttpError } from '@/lib/auth';
import { DraftBody } from '@/lib/drafts';

export const PATCH = route(['CUSTOMER'], DraftBody, ({ user, body, params }) =>
  withTx(user, async c => {
    const r = await c.query(
      `UPDATE draft_complaints
       SET narrative = $3, disputed_txn_id = $4, reported_amount = $5, scam_type = $6
       WHERE draft_id = $1 AND customer_id = $2`,
      [idParam(params), user.id, body.narrative, body.disputedTxnId ?? null, body.reportedAmount ?? null, body.scamType || null]);
    if (!r.rowCount) throw new HttpError(404, 'draft not found');
  }));

export const DELETE = route(['CUSTOMER'], z.object({}), ({ user, params }) =>
  withTx(user, async c => {
    const r = await c.query('DELETE FROM draft_complaints WHERE draft_id = $1 AND customer_id = $2',
                            [idParam(params), user.id]);
    if (!r.rowCount) throw new HttpError(404, 'draft not found');
  }));
