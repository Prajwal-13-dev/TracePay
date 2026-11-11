'use client';
// Send money. Customers pick one of their own accounts; supervisors type any source account and may set
// a past date/time (used to build demo laundering chains). The recipient's name is looked up before sending.
import { useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { friendlyError } from '@/lib/friendly';

export type OwnAccount = { ref: string; balance: number; frozen: number };
const inr = (n: number) => '₹' + n.toLocaleString('en-IN', { maximumFractionDigits: 2 });

export default function SendMoneyForm({ accounts, supervisor = false }: { accounts?: OwnAccount[]; supervisor?: boolean }) {
  const router = useRouter();
  const [from, setFrom] = useState(accounts?.[0]?.ref ?? '');
  const [to, setTo] = useState('');
  const [recipient, setRecipient] = useState<{ ok: boolean; text: string } | null>(null);
  const [amount, setAmount] = useState('');
  const [channel, setChannel] = useState('UPI');
  const [when, setWhen] = useState('');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [sent, setSent] = useState<{ txnId: number; ref: string } | null>(null);

  const own = accounts?.find(a => a.ref === from);
  const available = own ? own.balance - own.frozen : null;
  const amt = Number(amount);

  async function lookup(ref: string) {
    setRecipient(null);
    const r = ref.trim().toUpperCase();
    if (!/^TP[0-9]{10}$/.test(r)) return;
    const res = await fetch(`/api/accounts/lookup?ref=${r}`);
    const data = await res.json().catch(() => ({}));
    setRecipient(res.ok ? { ok: data.status === 'ACTIVE', text: data.status === 'ACTIVE' ? `Account holder: ${data.owner}` : 'This account is closed.' }
                        : { ok: false, text: data.error ?? 'Account not found.' });
  }

  async function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (!window.confirm(`Send ${inr(amt)} from ${from} to ${to.toUpperCase()}?`)) return;
    setBusy(true); setMsg(null); setSent(null);
    const res = await fetch('/api/transfers', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ fromRef: from, toRef: to, amount: amt, channel,
                             occurredAt: supervisor && when ? new Date(when).toISOString() : undefined }),
    });
    const data = await res.json().catch(() => ({}));
    setBusy(false);
    if (!res.ok) { setMsg({ ok: false, text: friendlyError(data, res.status) }); return; }
    setMsg({ ok: true, text: `Sent ${inr(amt)} to ${to.toUpperCase()}. Reference ${data.ref}.` });
    setSent({ txnId: data.txnId, ref: data.ref });
    setAmount(''); if (!supervisor) { setTo(''); setRecipient(null); }
    router.refresh();
  }

  return (
    <form onSubmit={onSubmit}>
      <div className="form-grid">
        <div>
          <label htmlFor="from">From account</label>
          {supervisor ? (
            <input id="from" value={from} onChange={e => setFrom(e.target.value.toUpperCase())} required pattern="TP[0-9]{10}" placeholder="TP1000000003" />
          ) : (
            <select id="from" value={from} onChange={e => setFrom(e.target.value)} required>
              {accounts?.map(a => <option key={a.ref} value={a.ref}>{a.ref} · available {inr(a.balance - a.frozen)}</option>)}
            </select>
          )}
        </div>
        <div>
          <label htmlFor="to">To account</label>
          <input id="to" value={to} required pattern="[Tt][Pp][0-9]{10}" placeholder="TP0000000000"
                 onChange={e => { setTo(e.target.value); setRecipient(null); }} onBlur={e => lookup(e.target.value)} />
          {recipient && <small className={recipient.ok ? 'ok' : 'error'} style={{ display: 'block', marginTop: 4 }}>{recipient.text}</small>}
        </div>
        <div>
          <label htmlFor="amount">Amount (₹)</label>
          <input id="amount" type="number" min="0.01" step="0.01" required value={amount} onChange={e => setAmount(e.target.value)}
                 max={available ?? undefined} placeholder="e.g. 5000" />
          {available !== null && <small className="muted">Available: {inr(available)}{own && own.frozen > 0 ? ` (${inr(own.frozen)} frozen)` : ''}</small>}
        </div>
        <div>
          <label htmlFor="channel">Channel</label>
          <select id="channel" value={channel} onChange={e => setChannel(e.target.value)}>
            {['UPI', 'IMPS', 'NEFT', 'CARD'].map(c => <option key={c}>{c}</option>)}
          </select>
        </div>
        {supervisor && (
          <div>
            <label htmlFor="when">Date and time (optional, for a past transfer)</label>
            <input id="when" type="datetime-local" value={when} onChange={e => setWhen(e.target.value)} />
          </div>
        )}
      </div>
      <p><button disabled={busy || (recipient !== null && !recipient.ok)}>{busy ? 'Sending…' : 'Send money'}</button></p>
      {msg && <p className={msg.ok ? 'ok' : 'error'} role="status">{msg.text}
        {sent && !supervisor && <> <Link href={`/customer/new?txn=${sent.txnId}`}>Was this a fraud? Report this transfer</Link></>}</p>}
    </form>
  );
}
