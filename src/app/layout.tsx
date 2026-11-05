import type { Metadata } from 'next';
import Link from 'next/link';
import './globals.css';
import { getSession } from '@/lib/auth';
import { homeFor } from '@/lib/session';
import LogoutButton from '@/components/LogoutButton';

export const metadata: Metadata = { title: 'TracePay', description: 'Fraud recovery coordination' };

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const user = await getSession();
  return (
    <html lang="en">
      <body>
        <header className="top">
          <Link href={user ? homeFor(user.role) : '/login'} className="brand">TracePay</Link>
          <span className="spacer" />
          {user ? (
            <>
              <span className="muted">{user.name}</span>
              <span className="badge">{user.role}</span>
              <LogoutButton />
            </>
          ) : (
            <Link href="/register">Create account</Link>
          )}
        </header>
        <main>{children}</main>
      </body>
    </html>
  );
}
