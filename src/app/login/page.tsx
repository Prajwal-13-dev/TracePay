'use client';
import { useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { Suspense } from 'react';

function LoginForm() {
  const router = useRouter();
  const denied = useSearchParams().get('denied');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  async function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setBusy(true); setError('');
    const form = new FormData(e.currentTarget);
    const res = await fetch('/api/auth/login', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: form.get('email'), password: form.get('password') }),
    });
    const data = await res.json();
    setBusy(false);
    if (!res.ok) { setError(data.error ?? 'sign-in failed'); return; }
    router.push(data.home);
    router.refresh();
  }

  return (
    <div className="card narrow">
      <h2>Sign in</h2>
      {denied && <p className="error">You do not have access to that page.</p>}
      <form method="post" onSubmit={onSubmit}>
        <label htmlFor="email">Email</label>
        <input id="email" name="email" type="email" required autoComplete="email" />
        <label htmlFor="password">Password</label>
        <input id="password" name="password" type="password" required autoComplete="current-password" />
        <p><button disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</button></p>
        {error && <p className="error">{error}</p>}
      </form>
      <p className="muted">Demo: v1@demo.in, inv@demo.in, sup1@demo.in (password Demo@1234)</p>
    </div>
  );
}

export default function LoginPage() {
  return <Suspense><LoginForm /></Suspense>;
}
