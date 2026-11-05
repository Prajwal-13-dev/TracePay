// Runs before every page in the three role areas: no session -> /login, wrong role -> /login?denied=1.
import { NextResponse, type NextRequest } from 'next/server';
import { SESSION_COOKIE, verifySession, type Role } from '@/lib/session';

const AREA_ROLE: Record<string, Role> = {
  '/customer': 'CUSTOMER',
  '/investigator': 'INVESTIGATOR',
  '/supervisor': 'SUPERVISOR',
};

export async function proxy(request: NextRequest) {
  const area = Object.keys(AREA_ROLE).find(p => request.nextUrl.pathname.startsWith(p));
  if (!area) return NextResponse.next();
  const user = await verifySession(request.cookies.get(SESSION_COOKIE)?.value);
  if (!user) return NextResponse.redirect(new URL('/login', request.url));
  if (user.role !== AREA_ROLE[area]) return NextResponse.redirect(new URL('/login?denied=1', request.url));
  return NextResponse.next();
}

export const config = { matcher: ['/customer/:path*', '/investigator/:path*', '/supervisor/:path*'] };
