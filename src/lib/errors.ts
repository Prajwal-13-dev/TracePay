// Maps database and validation errors to HTTP responses (handbook 20.2).
import { NextResponse } from 'next/server';
import { ZodError } from 'zod';
import { HttpError } from './auth';

type PgError = { code?: string; message?: string; detail?: string; constraint?: string };

// Plain-language explanations for the constraints a user can realistically hit from a form.
// The SQLSTATE and constraint name are still returned, so the database rule stays visible.
const CONSTRAINT_HELP: Record<string, string> = {
  fund_flow_links_from_node_id_to_node_id_key: 'this link is already confirmed for the case (confirmed links are never edited)',
  fraud_cases_disputed_txn_id_key: 'a complaint for this transfer already exists',
  users_email_key: 'an account with this email already exists',
  account_freezes_check2: 'four-eyes rule: you cannot approve a freeze you requested',
  fraud_cases_check: 'verified loss must be more than 0 and at most the reported amount',
  one_live_allocation: 'this case already has an active allocation on this freeze',
  one_open_assignment: 'this case already has an open assignment',
  trace_nodes_case_id_txn_id_key: 'this transfer is already part of the trace',
  users_phone_check: 'phone must be a 10-digit Indian mobile number',
  fraud_cases_narrative_check: 'the description must be 30 to 5,000 characters',
};

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
    // TP* details carry the useful numbers (limit, total, excess). Postgres' own details for
    // 23xxx errors echo the whole failing row (e.g. a narrative), so they are not sent to the browser.
    const detail = pg.code.startsWith('TP') ? pg.detail ?? null : null;
    const help = pg.constraint ? CONSTRAINT_HELP[pg.constraint] : undefined;
    const error = help ? `${help} (${pg.constraint})` : pg.message;
    return NextResponse.json({ error, code: pg.code, detail },
                             { status: PG_STATUS[pg.code] });
  }
  console.error('Unhandled error:', pg?.code ?? '', pg?.message ?? e);   // no stack trace to the client
  return NextResponse.json({ error: 'internal error' }, { status: 500 });
}
