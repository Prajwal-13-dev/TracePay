// Server-only database access. Credentials come from DATABASE_URL (.env), never from code.
import 'server-only';
import { Pool, PoolClient, QueryResultRow } from 'pg';
import type { SessionUser } from './session';

const globalForPg = globalThis as unknown as { pgPool?: Pool };
export const pool = globalForPg.pgPool ?? new Pool({ connectionString: process.env.DATABASE_URL, max: 10 });
if (process.env.NODE_ENV !== 'production') globalForPg.pgPool = pool;   // survive hot reloads in dev

// Read-only query outside a transaction.
export async function query<T extends QueryResultRow = QueryResultRow>(text: string, params: unknown[] = []) {
  const res = await pool.query<T>(text, params);
  return res.rows;
}

// Every write runs in ONE transaction that carries the acting user's id (and role, for older triggers),
// so the state-machine and audit triggers know who acted. is_local = true: the settings
// vanish at COMMIT, so a pooled connection never leaks them to the next request.
// user = null is for public sign-up only (nobody is signed in yet).
export async function withTx<T>(user: SessionUser | null, fn: (c: PoolClient) => Promise<T>): Promise<T> {
  const c = await pool.connect();
  try {
    await c.query('BEGIN ISOLATION LEVEL READ COMMITTED');
    await c.query("SELECT set_config('app.user_id', $1, true), set_config('app.user_role', $2, true)",
                  [user ? String(user.id) : '', user?.role ?? '']);
    const out = await fn(c);
    await c.query('COMMIT');
    return out;
  } catch (e) {
    await c.query('ROLLBACK').catch(() => {});   // never hide the real error behind a failed rollback
    throw e;
  } finally {
    c.release();
  }
}

// Opening balance for accounts created at sign-up (demo money so a new customer can send a transfer).
export const DEMO_OPENING_BALANCE = Number(process.env.DEMO_OPENING_BALANCE ?? 100000);
