'use client';
// Role navigation; highlights the section you are in.
import Link from 'next/link';
import { usePathname } from 'next/navigation';

export default function NavLinks({ links }: { links: { href: string; label: string; exact?: boolean }[] }) {
  const path = usePathname();
  return (
    <nav className="roles" aria-label="Main">
      {links.map(l => {
        const on = l.exact ? path === l.href : path === l.href || path.startsWith(l.href + '/');
        return <Link key={l.href} href={l.href} className={on ? 'active' : undefined} aria-current={on ? 'page' : undefined}>{l.label}</Link>;
      })}
    </nav>
  );
}
