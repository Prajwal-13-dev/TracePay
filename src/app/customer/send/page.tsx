import { requirePageRole } from '@/lib/auth';
import { query } from '@/lib/db';
import SendMoneyForm, { type OwnAccount } from '@/components/SendMoneyForm';

export default async function SendMoney() {
  const user = await requirePageRole('CUSTOMER');
  const accounts = await query<OwnAccount>(
    `SELECT a.account_ref AS ref, a.balance::float8 AS balance,
            COALESCE((SELECT SUM(f.frozen_amount) FROM account_freezes f WHERE f.account_id = a.account_id AND f.status = 'ACTIVE'), 0)::float8 AS frozen
     FROM accounts a WHERE a.user_id = $1 AND a.status = 'ACTIVE' ORDER BY a.account_ref`, [user.id]);
  return (
    <>
      <div className="page-head"><div><h1>Send money</h1>
        <p>Transfer money from your account to any TracePay account. The recipient&apos;s name is shown before you send.</p></div></div>
      <div className="card">
        {accounts.length === 0
          ? <div className="empty"><b>You have no active account</b>Ask a supervisor to open one for you.</div>
          : <SendMoneyForm accounts={accounts} />}
      </div>
    </>
  );
}
