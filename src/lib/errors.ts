// Maps database and validation errors to HTTP responses (handbook 20.2).
import { NextResponse } from 'next/server';
import { ZodError } from 'zod';
import { HttpError } from './auth';

type PgError = { code?: string; message?: string; detail?: string };

const PG_STATUS: Record<string, number> = {
  TP001: 409,   // money rule (engine invariant) broken
  TP002: 409,   // business rule
  TP003: 422,   // illegal case status transition
  TP004: 409,   // append-only table
  TP005: 422,   // complaint rule
  '23505': 409, // unique violation
  '23514': 422, // CHECK violation
  '23503': 422, // foreign key violation
  '40001': 503, // serialization failure: retry
  '40P01': 503, // deadlock detected: retry
};

export function toResponse(e: unknown) {
  if (e instanceof HttpError) return NextResponse.json({ error: e.message }, { status: e.status });
  if (e instanceof ZodError) {
    return NextResponse.json({ error: 'invalid input', issues: e.issues.map(i => i.path.join('.') + ': ' + i.message) },
                             { status: 400 });
  }
  const pg = e as PgError;
  if (pg && typeof pg.code === 'string' && PG_STATUS[pg.code]) {
    return NextResponse.json({ error: pg.message, code: pg.code, detail: pg.detail ?? null },
                             { status: PG_STATUS[pg.code] });
  }
  console.error('Unhandled error:', pg?.code ?? '', pg?.message ?? e);   // no stack trace to the client
  return NextResponse.json({ error: 'internal error' }, { status: 500 });
}
