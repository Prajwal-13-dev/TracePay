// Request body shared by POST /api/drafts and PATCH /api/drafts/[id].
import { z } from 'zod';
import { id, money } from './api';

export const DraftBody = z.object({
  disputedTxnId: id.nullable().optional(),
  narrative: z.string().max(5000),
  reportedAmount: money.nullable().optional(),
  scamType: z.string().trim().max(60).nullable().optional(),
});
