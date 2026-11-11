'use client';
import { useState } from 'react';
import Link from 'next/link';

export default function RegisterPage() {
  const [error, setError] = useState('');
  const [done, setDone] = useState<string | null>(null);

  async function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError('');
    const f = new FormData(e.currentTarget);
    const res = await fetch('/api/auth/register', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ fullName: f.get('fullName'), email: f.get('email'),
                             phone: f.get('phone'), password: f.get('password') }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) { setError(data.issues?.join('\n') ?? data.error ?? `Sign-up failed (HTTP ${res.status}).`); return; }
    setDone(data.accountRef ?? '');
  }

  if (done !== null) return (
    <div className="card narrow">
      <p className="ok">Your TracePay account is ready.</p>
      {done && <p>Your bank account number is <b>{done}</b>. You can send money and report fraud after signing in.</p>}
      <Link className="btn" href="/login">Sign in</Link>
    </div>
  );
  return (
    <div className="card narrow">
      <h2>Create a customer account</h2>
      <form method="post" onSubmit={onSubmit}>
        <label htmlFor="fullName">Full name</label>
        <input id="fullName" name="fullName" required minLength={2} maxLength={100} />
        <label htmlFor="email">Email</label>
        <input id="email" name="email" type="email" required />
        <label htmlFor="phone">Mobile (optional)</label>
        <input id="phone" name="phone" pattern="[6-9][0-9]{9}" placeholder="9876543210" />
        <label htmlFor="password">Password (8+ characters)</label>
        <input id="password" name="password" type="password" required minLength={8} />
        <p><button>Create account</button></p>
        {error && <p className="error">{error}</p>}
      </form>
    </div>
  );
}
