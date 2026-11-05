import { redirect } from 'next/navigation';
import { getSession } from '@/lib/auth';
import { homeFor } from '@/lib/session';

export default async function Home() {
  const user = await getSession();
  redirect(user ? homeFor(user.role) : '/login');
}
