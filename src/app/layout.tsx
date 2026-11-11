import type { Metadata } from 'next';
import Link from 'next/link';
import './globals.css';
import { getSession } from '@/lib/auth';
import { homeFor, Role } from '@/lib/session';
import LogoutButton from '@/components/LogoutButton';
import NavLinks from '@/components/NavLinks';

export const metadata: Metadata = { title: 'TracePay', description: 'Fraud recovery coordination' };

const NAV: Record<Role, { href: string; label: string; exact?: boolean }[]> = {
  CUSTOMER: [{ href: '/customer', label: 'My complaints', exact: true }, { href: '/customer/send', label: 'Send money' },
             { href: '/customer/new', label: 'Report fraud' }],
  INVESTIGATOR: [{ href: '/investigator', label: 'Case queue' }],
  SUPERVISOR: [
    { href: '/supervisor', label: 'Dashboard', exact: true },
    { href: '/supervisor/cases', label: 'Cases' },
    { href: '/supervisor/freezes', label: 'Freezes & recovery' },
    { href: '/supervisor/transactions', label: 'Transactions' },
    { href: '/supervisor/users', label: 'Users' },
    { href: '/supervisor/audit', label: 'Audit log' },
  ],
};
const ROLE_LABEL: Record<Role, string> = { CUSTOMER: 'Customer', INVESTIGATOR: 'Investigator', SUPERVISOR: 'Supervisor' };

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const user = await getSession();
  const initials = user?.name.split(/\s+/).map(w => w[0]).slice(0, 2).join('').toUpperCase();
  return (
    <html lang="en">
      <body>
        <header className="top">
          <Link href={user ? homeFor(user.role) : '/login'} className="brand"><span className="logo">₹</span>TracePay</Link>
          {user && <NavLinks links={NAV[user.role]} />}
          <span className="spacer" />
          {user ? (
            <div className="who">
              <span className="avatar" aria-hidden>{initials}</span>
              <span className="name">{user.name}</span>
              <span className="badge">{ROLE_LABEL[user.role]}</span>
              <LogoutButton />
            </div>
          ) : (
            <Link href="/register">Create account</Link>
          )}
        </header>
        <main>{children}</main>
      </body>
    </html>
  );
}
