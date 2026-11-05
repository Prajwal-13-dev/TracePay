import { NextResponse } from 'next/server';
import { getSession } from '@/lib/auth';

export async function GET() {
  const user = await getSession();
  return user ? NextResponse.json(user) : NextResponse.json({ error: 'not signed in' }, { status: 401 });
}
