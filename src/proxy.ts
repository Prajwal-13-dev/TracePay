// Runs before every page in the three role areas: no valid session cookie -> /login.
// The role check happens in each page (requirePageRole), against the CURRENT role in the database,
// because the role inside the cookie can be out of date after a supervisor changes it.
import { NextResponse, type NextRequest } from 'next/server';
import { SESSION_COOKIE, verifySession } from '@/lib/session';

export async function proxy(request: NextRequest) {
  const user = await verifySession(request.cookies.get(SESSION_COOKIE)?.value);
  if (!user) return NextResponse.redirect(new URL('/login', request.url));
  return NextResponse.next();
}

export const config = { matcher: ['/customer/:path*', '/investigator/:path*', '/supervisor/:path*'] };
