'use client';
import { useRef, useState, Suspense } from 'react';
import Link from 'next/link';
import { useRouter, useSearchParams } from 'next/navigation';

// Demo sign-in shortcuts: development builds only (or NEXT_PUBLIC_SHOW_DEMO=1 for a presentation build).
const SHOW_DEMO = process.env.NODE_ENV !== 'production' || process.env.NEXT_PUBLIC_SHOW_DEMO === '1';
const DEMO = [
  { email: 'v1@demo.in', label: 'Victim 1 (customer)' }, { email: 'v2@demo.in', label: 'Victim 2 (customer)' },
  { email: 'inv@demo.in', label: 'Investigator' }, { email: 'sup1@demo.in', label: 'Supervisor 1' },
  { email: 'sup2@demo.in', label: 'Supervisor 2' },
];

function LoginForm() {
  const router = useRouter();
  const denied = useSearchParams().get('denied');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const email = useRef<HTMLInputElement>(null);
  const password = useRef<HTMLInputElement>(null);

  async function signIn(e?: React.FormEvent) {
    e?.preventDefault();
    setBusy(true); setError('');
    const res = await fetch('/api/auth/login', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: email.current?.value, password: password.current?.value }),
    });
    const data = await res.json().catch(() => ({}));
    setBusy(false);
    if (!res.ok) { setError(res.status === 401 ? 'Wrong email or password.' : data.error ?? 'Sign-in failed.'); return; }
    router.push(data.home);
    router.refresh();
  }

  return (
    <div className="auth-wrap">
      <div className="auth-side">
        <h1>TracePay</h1>
        <p>Fraud recovery, coordinated. Trace where stolen money went, freeze it, and refund victims fairly.</p>
        <ul>
          <li>Follow the money across accounts on an interactive graph</li>
          <li>Never count, freeze or refund the same rupee twice</li>
          <li>Every step recorded in an audit log</li>
        </ul>
      </div>
      <div className="auth-form">
        <h2>Sign in</h2>
        {denied && <p className="callout warn">You don&apos;t have access to that page. Sign in with a different account.</p>}
        <form method="post" onSubmit={signIn}>
          <label htmlFor="email">Email</label>
          <input ref={email} id="email" name="email" type="email" required autoComplete="email" />
          <label htmlFor="password">Password</label>
          <input ref={password} id="password" name="password" type="password" required autoComplete="current-password" />
          <p><button disabled={busy} style={{ width: '100%' }}>{busy ? 'Signing in…' : 'Sign in'}</button></p>
          {error && <p className="error" role="alert">{error}</p>}
        </form>
        <p className="muted">New here? <Link href="/register">Create a customer account</Link></p>
        {SHOW_DEMO && <div style={{ borderTop: '1px solid var(--line)', marginTop: 18, paddingTop: 14 }}>
          <span className="muted">Demo accounts (password Demo@1234): click to fill in</span>
          <div className="demo-users">{DEMO.map(d => (
            <button key={d.email} type="button" className="secondary" onClick={() => {
              if (email.current) email.current.value = d.email;
              if (password.current) password.current.value = 'Demo@1234';
            }}>{d.label}</button>
          ))}</div>
        </div>}
      </div>
    </div>
  );
}

export default function LoginPage() {
  return <Suspense><LoginForm /></Suspense>;
}
