// Server-only Neo4j access. Credentials come from .env (NEO4J_URI, NEO4J_USER, NEO4J_PASSWORD).
import 'server-only';
import neo4j, { Driver } from 'neo4j-driver';

const g = globalThis as unknown as { neo4jDriver?: Driver };

export function graphDriver(): Driver {
  if (!g.neo4jDriver) {
    g.neo4jDriver = neo4j.driver(
      process.env.NEO4J_URI ?? 'bolt://localhost:7687',
      neo4j.auth.basic(process.env.NEO4J_USER ?? 'neo4j', process.env.NEO4J_PASSWORD ?? ''),
      { disableLosslessIntegers: true, connectionTimeout: 2000, maxTransactionRetryTime: 2000, maxConnectionPoolSize: 20 },
    );
  }
  return g.neo4jDriver;
}

// After a connection failure, skip Neo4j for 30 s so pages fall back to PostgreSQL instantly.
let offlineUntil = 0;
const QUERY_TIMEOUT_MS = 8000;

// Read query -> plain objects.
export async function cypher<T = Record<string, unknown>>(text: string, params: Record<string, unknown> = {}) {
  if (Date.now() < offlineUntil) throw new Error('Neo4j marked offline (retrying in a few seconds)');
  try {
    // A page never waits more than QUERY_TIMEOUT_MS on Neo4j: on timeout the caller falls back to PostgreSQL.
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`Neo4j query took longer than ${QUERY_TIMEOUT_MS} ms`)), QUERY_TIMEOUT_MS);
    });
    try {
      const { records } = await Promise.race([
        graphDriver().executeQuery(text, params, { routing: neo4j.routing.READ }), timeout]);
      return records.map(r => r.toObject() as T);
    } finally {
      clearTimeout(timer);
    }
  } catch (e) {
    if ((e as { code?: string }).code === 'ServiceUnavailable') offlineUntil = Date.now() + 30_000;
    throw e;
  }
}
