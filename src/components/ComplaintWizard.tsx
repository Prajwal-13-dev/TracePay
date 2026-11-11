'use client';
// Four-step complaint form: transfer → amount → what happened → review.
// Drafts can be saved at any step; the database still checks ownership and amount on submit.
import { useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { friendlyError } from '@/lib/friendly';

export type Transfer = { txn_id: number; ref: string; to_ref: string; to_owner: string; amount: number; occurred_at: string };
type Draft = { draft_id: number; disputed_txn_id: number | null; narrative: string;
               reported_amount: number | null; scam_type: string | null };

const inr = (n: number) => '₹' + n.toLocaleString('en-IN', { maximumFractionDigits: 2 });
const when = (s: string) => new Date(s).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', dateStyle: 'medium', timeStyle: 'short' });
const STEPS = ['Transfer', 'Amount', 'What happened', 'Review'];
const SCAM_TYPES = ['Fake KYC / bank call', 'Fake job or task', 'Online shopping', 'Investment / trading app',
                    'Fake refund or courier', 'Loan app', 'Impersonation (friend or family)', 'Other'];
const MIN = 30, MAX = 5000;

export default function ComplaintWizard({ transfers, draft, preselect }: { transfers: Transfer[]; draft?: Draft; preselect?: number }) {
  const router = useRouter();
  // A draft may point at a transfer that has since been reported (or is no longer reportable): then start at step 1.
  const draftTxnGone = !!draft?.disputed_txn_id && !transfers.some(x => x.txn_id === draft.disputed_txn_id);
  const startTxn = preselect ?? (draftTxnGone ? null : draft?.disputed_txn_id ?? null);
  const [step, setStep] = useState(startTxn ? 1 : 0);
  const [txnId, setTxnId] = useState<number | null>(startTxn);
  const [amount, setAmount] = useState(draft?.reported_amount ? String(draft.reported_amount) : '');
  const [scamType, setScamType] = useState(draft?.scam_type ?? '');
  const [story, setStory] = useState(draft?.narrative ?? '');
  const [draftId, setDraftId] = useState<number | null>(draft?.draft_id ?? null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [done, setDone] = useState<{ caseId: string } | null>(null);

  const t = transfers.find(x => x.txn_id === txnId);
  const amt = Number(amount);
  const narrative = (scamType && !story.startsWith(scamType) ? `${scamType}: ` : '') + story.trim();
  const valid = [
    !!t,
    !!t && amt > 0 && amt <= t.amount && /^\d+(\.\d{1,2})?$/.test(amount),
    narrative.length >= MIN && narrative.length <= MAX,
    true,
  ];

  async function call(url: string, method: string, body: unknown) {
    setBusy(true); setMsg(null);
    const res = await fetch(url, { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    const data = await res.json().catch(() => ({}));
    setBusy(false);
    if (!res.ok) { setMsg({ ok: false, text: friendlyError(data, res.status) }); return null; }
    return data;
  }

  async function saveDraft() {
    // The draft keeps each answer separately, so every step comes back exactly as it was left.
    const body = { disputedTxnId: txnId, narrative: story.trim(), scamType: scamType || null,
                   reportedAmount: amt > 0 && /^\d+(\.\d{1,2})?$/.test(amount) ? amt : null };
    const data = draftId
      ? await call(`/api/drafts/${draftId}`, 'PATCH', body)
      : await call('/api/drafts', 'POST', body);
    if (!data) return;
    if (data.draftId) setDraftId(Number(data.draftId));
    setMsg({ ok: true, text: 'Draft saved. You can finish it later from "My complaints".' });
    router.refresh();
  }

  async function submit() {
    const data = await call('/api/cases', 'POST',
      { disputedTxnId: txnId, reportedAmount: amt, narrative, ...(draftId ? { draftId } : {}) });
    if (data) { setDone({ caseId: String(data.caseId) }); router.refresh(); }
  }

  if (done) return (
    <div className="card">
      <div className="callout ok"><b>Complaint #{done.caseId} submitted.</b></div>
      <h3>What happens next</h3>
      <ol className="muted">
        <li>A supervisor reviews your complaint and assigns an investigator.</li>
        <li>The investigator traces where your money went and asks banks to freeze it.</li>
        <li>Recovered money is refunded to you. You can follow every step on your complaints page.</li>
      </ol>
      <p><Link className="btn" href="/customer">Go to my complaints</Link></p>
    </div>
  );

  if (!transfers.length) return (
    <div className="card empty"><b>No transfers to report</b>Every transfer you made already has a complaint.
      <p><Link href="/customer">Back to my complaints</Link></p></div>
  );

  return (
    <div className="card">
      <div className="steps" aria-label="Progress">
        {STEPS.map((s, i) => (
          <span key={s} className={'st' + (i === step ? ' on' : i < step ? ' done' : '')}>
            <i>{i < step ? '✓' : i + 1}</i>{s}
          </span>
        ))}
      </div>

      {step === 0 && (<>
        {draftTxnGone && <div className="callout warn">The transfer saved in this draft already has a complaint. Pick another transfer, or delete the draft.</div>}
        <h2>Which transfer was fraudulent?</h2>
        <p className="muted">Pick the payment you were tricked into making.</p>
        <div className="choices" role="radiogroup">
          {transfers.map(x => (
            <button type="button" role="radio" aria-checked={x.txn_id === txnId} key={x.txn_id}
                    className={'choice' + (x.txn_id === txnId ? ' sel' : '')} onClick={() => setTxnId(x.txn_id)}>
              <b>{inr(x.amount)}</b>
              <span>to {x.to_owner} · {x.to_ref}</span>
              <span>{when(x.occurred_at)} · ref {x.ref}</span>
            </button>
          ))}
        </div>
      </>)}

      {step === 1 && t && (<>
        <h2>How much did you lose?</h2>
        <p className="muted">You sent {inr(t.amount)} to {t.to_owner} on {when(t.occurred_at)}. Enter the part that was lost to fraud.</p>
        <div style={{ maxWidth: 320 }}>
          <label htmlFor="amt">Amount lost (₹)</label>
          <input id="amt" inputMode="decimal" value={amount} placeholder="e.g. 25000" autoFocus
                 onChange={e => setAmount(e.target.value.replace(/[^\d.]/g, ''))} />
          <div className="demo-users" style={{ marginTop: 8 }}>
            <button type="button" className="secondary" onClick={() => setAmount(String(t.amount))}>Full amount ({inr(t.amount)})</button>
          </div>
          {amount && !valid[1] && <p className="error">Enter an amount between ₹1 and {inr(t.amount)}.</p>}
        </div>
      </>)}

      {step === 2 && (<>
        <h2>Tell us what happened</h2>
        <label>Type of fraud (optional)</label>
        <div className="demo-users">
          {SCAM_TYPES.map(s => (
            <button type="button" key={s} className={scamType === s ? '' : 'secondary'} onClick={() => setScamType(scamType === s ? '' : s)}>{s}</button>
          ))}
        </div>
        <label htmlFor="story">Your description</label>
        <textarea id="story" rows={7} value={story} maxLength={MAX} onChange={e => setStory(e.target.value)}
                  placeholder="Who contacted you, how, what they said, and why you made the payment." />
        <div className={'counter' + (narrative.length > 0 && narrative.length < MIN ? ' bad' : '')}>
          {narrative.length < MIN ? `${MIN - narrative.length} more characters needed` : `${narrative.length} / ${MAX}`}
        </div>
        <div className="tips">Helpful details:
          <ul><li>How they contacted you (call, SMS, WhatsApp, website) and any number or link</li>
              <li>What they promised or threatened</li><li>Anything you shared (OTP, screen-share, app installed)</li></ul>
        </div>
      </>)}

      {step === 3 && t && (<>
        <h2>Check and submit</h2>
        <dl className="review">
          <dt>Transfer</dt><dd>{inr(t.amount)} to {t.to_owner} ({t.to_ref}) on {when(t.occurred_at)}</dd>
          <dt>Amount lost</dt><dd><b>{inr(amt)}</b></dd>
          <dt>What happened</dt><dd>{narrative}</dd>
        </dl>
        <div className="callout info">By submitting, you confirm this information is true. You can&apos;t edit a complaint once it&apos;s submitted.</div>
      </>)}

      {msg && <p className={msg.ok ? 'ok' : 'error'}>{msg.text}</p>}

      <div className="wiz-nav">
        <div>{step > 0 && <button type="button" className="secondary" onClick={() => { setStep(step - 1); setMsg(null); }}>← Back</button>}</div>
        <div className="right">
          <button type="button" className="ghost" disabled={busy} onClick={saveDraft}>Save draft</button>
          {step < 3
            ? <button type="button" disabled={!valid[step]} onClick={() => { setStep(step + 1); setMsg(null); }}>Continue →</button>
            : <button type="button" disabled={busy || !valid.every(Boolean)} onClick={submit}>{busy ? 'Submitting…' : 'Submit complaint'}</button>}
        </div>
      </div>
    </div>
  );
}
