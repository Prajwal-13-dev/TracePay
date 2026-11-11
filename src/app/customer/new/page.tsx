import { requirePageRole } from '@/lib/auth';
import { query } from '@/lib/db';
import ComplaintWizard, { Transfer } from '@/components/ComplaintWizard';

export default async function NewComplaint({ searchParams }: { searchParams: Promise<{ draft?: string; txn?: string }> }) {
  const user = await requirePageRole('CUSTOMER');
  const sp = await searchParams;
  const draftId = Number(sp.draft);
  const preselect = Number(sp.txn);
  // Only the signed-in customer's own transfers that have no complaint yet.
  const transfers = await query<Transfer>(
    `SELECT t.txn_id::int, t.external_ref AS ref, d.account_ref AS to_ref, u.full_name AS to_owner,
            t.amount::float8 AS amount, t.occurred_at::text AS occurred_at
     FROM transactions t
     JOIN accounts s ON s.account_id = t.source_account_id
     JOIN accounts d ON d.account_id = t.destination_account_id JOIN users u ON u.user_id = d.user_id
     WHERE s.user_id = $1 AND t.channel <> 'RECOVERY' AND NOT EXISTS (SELECT 1 FROM fraud_cases c WHERE c.disputed_txn_id = t.txn_id)
     ORDER BY t.occurred_at DESC`, [user.id]);
  const [draft] = Number.isInteger(draftId) && draftId > 0 ? await query<{ draft_id: number; disputed_txn_id: number | null; narrative: string;
                                                                           reported_amount: number | null; scam_type: string | null }>(
    `SELECT draft_id::int, disputed_txn_id::int, narrative, reported_amount::float8, scam_type
     FROM draft_complaints WHERE draft_id = $1 AND customer_id = $2`,
    [draftId, user.id]) : [];
  return (
    <>
      <div className="page-head"><div><h1>Report a fraudulent transfer</h1>
        <p>Four short steps. Report as soon as possible: the sooner we trace the money, the more we can freeze.</p></div></div>
      <ComplaintWizard transfers={transfers} draft={draft}
                       preselect={Number.isInteger(preselect) && transfers.some(t => t.txn_id === preselect) ? preselect : undefined} />
    </>
  );
}
