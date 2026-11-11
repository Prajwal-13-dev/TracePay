# TracePay: Multi-Hop Disputed-Fund Attribution and Fraud Recovery Coordination


TracePay traces where disputed money went after a fraud complaint, attributes it to victims without
double counting, and shares limited frozen funds across victims. Six financial limits are enforced
**inside PostgreSQL** by a reusable, concurrency-safe constraint engine (a restricted `CREATE ASSERTION`).

| | |
|---|---|
| SQL database | PostgreSQL 16 (system of record: money, cases, tracing, audit) |
| Graph database | Neo4j 5 (transfer graph: multi-hop path search, shared mule accounts) |
| Vector search | pgvector in the same PostgreSQL server (similar-complaint search) |
| Web app | Next.js 16 (App Router, TypeScript), Route Handlers as the API |
| Roles | Customer, Investigator, Supervisor (supervisors manage users on the Users page) |


## Prerequisites

Docker Desktop, Node.js 20+, Git. Windows PowerShell commands are shown; the SQL runs inside the container.

## Setup (first time)

```powershell
git clone https://github.com/Prajwal-13-dev/TracePay.git
cd TracePay
Copy-Item .env.example .env      # then edit .env (see below)
npm install
```

`.env` (git-ignored, never committed). See `.env.example` for every setting:

```
PG_OWNER_PASSWORD=<letters and digits only>
OWNER_DATABASE_URL=postgres://tracepay_owner:<same password>@localhost:5433/tracepay
PG_APP_PASSWORD=<letters and digits only, different from the owner's>
DATABASE_URL=postgres://tracepay_app:<app password>@localhost:5433/tracepay
AUTH_SECRET=<32+ random characters>
NEO4J_PASSWORD=<8+ letters and digits>
NEO4J_URI=bolt://localhost:7687
NEO4J_USER=neo4j
DEMO_OPENING_BALANCE=100000
```

The web app connects as **`tracepay_app`**, a limited role (migration 009): it can read what the pages show and
write only through the database procedures. Migrations, seeds and tests run as the owner, `tracepay_owner`.
`npm run db:reset` creates `tracepay_app` and sets its password from `PG_APP_PASSWORD`.

Generate a secret: `[Convert]::ToBase64String((1..32 | % { Get-Random -Max 256 }))`

The database is published on host port **5433** so it never clashes with a locally installed PostgreSQL on 5432.

## Build the database (run again any time for a clean state)

```powershell
docker compose down -v
docker compose up -d --wait
npm run db:reset -- --graph   # every migration and seed in order, app role password, and Neo4j reloaded
npm run embed      # narrative embeddings; first run downloads the model (~23 MB)
npm run graph:rebuild   # load accounts, transfers and cases into Neo4j
npm run graph:test      # Neo4j checks: sync counts, idempotent replay, trace parity with the recursive CTE
```

### How Neo4j fits in

PostgreSQL stays the system of record. Triggers write every new account, transfer and case into
`graph_outbox` in the same transaction; `npm run graph:sync` copies them into Neo4j with idempotent `MERGE`s.
Neo4j only **suggests** where money went (`src/lib/graphQueries.mjs`); confirming a link still runs
`confirm_link()` in PostgreSQL, so the constraint engine guards every rupee. If Neo4j is down, the trace page
falls back to the recursive CTE and says so. Neo4j Browser: http://localhost:7474 (user `neo4j`).

## Run

```powershell
npm run dev        # http://localhost:3000
npm run graph:sync # second terminal: keeps Neo4j in step with PostgreSQL
```

Demo accounts (password `Demo@1234` for all):

| Email | Role |
|---|---|
| `v1@demo.in`, `v2@demo.in` | Customer (victims of the demo scenario) |
| `inv@demo.in` | Investigator |
| `sup1@demo.in`, `sup2@demo.in` | Supervisor |

Public sign-up always creates a Customer and opens a bank account for them (opening balance
`DEMO_OPENING_BALANCE`), so a new customer can send money and report a transfer straight away.
Supervisors create investigators and supervisors, change roles, deactivate users and reset passwords on
**Users**, and record transfers between any accounts (also backdated, to build demo chains) on **Transactions**.
The database enforces who may do what (`create_user`, `set_user_role`, `record_transfer`, ...), not just the UI.

### How money moves

Every transfer debits the sender and credits the receiver inside PostgreSQL (trigger `apply_transfer`, migration 007):
overdrafts, spending frozen money and closed accounts are refused. When a freeze is settled (or expires), each
refunded amount is paid to the victim's account as a `RECOVERY` transfer, which tracing ignores.

## Tests

| Command | What it checks |
|---|---|
| `npm run db:reset` | Rebuilds the database from scratch (all migrations and seeds). Add `-- --graph` to reload Neo4j too. |
| `npm run test:db` | 209 SQL checks in 10 files, one per migration (`01_core` … `09_roles`) plus `10_alter_drop` (the ALTER/DROP demo). Each file runs in one transaction and rolls back. `npm run test:db -- 05` runs only `05_recovery`. |
| `npm run graph:test` | Neo4j: the graph matches PostgreSQL, replaying the outbox makes no duplicates, and every case traces identically to the recursive CTE. |
| `npm run test:e2e` | Playwright: the whole demo story through the browser as customer, supervisor and investigator, then a supervisor adding an investigator and a new customer registering, sending money and reporting it. Resets the database first, starts the app on port 3100, and saves report screenshots to `docs/screenshots/`. |

First time only: `npx playwright install chromium`. Without Docker, point the scripts at your own psql:
`$env:PSQL="psql -h localhost -p 5433 -U tracepay_owner -d tracepay"`.

Query catalogue (every required SQL concept on a demo state):
`docker compose exec postgres psql -U tracepay_owner -d tracepay -f /db/queries/catalogue.sql`.
Two-terminal concurrency demo: [`db/tests/RACE_DEMO.md`](db/tests/RACE_DEMO.md).
Concurrency lab (why the money rules use locked triggers): `node --env-file=.env experiments/concurrency-lab.mjs`
races two claims on the same transfer through five PostgreSQL strategies and three Neo4j strategies
(it creates its own lab tables, so it uses `OWNER_DATABASE_URL`).

## Troubleshooting

- **`password authentication failed for user "tracepay_owner"`**: Postgres reads `POSTGRES_PASSWORD` only on its
  first start. If you changed `PG_OWNER_PASSWORD` later, run
  `docker compose exec postgres psql -U tracepay_owner -d tracepay -c "ALTER ROLE tracepay_owner PASSWORD 'new-password'"`
  (the socket inside the container needs no password).
- **`password authentication failed for user "tracepay_app"`**: set `PG_APP_PASSWORD` in `.env` and run `npm run db:reset`.
- **Upgrading an older `.env`**: it still works with `DATABASE_URL` pointing at `tracepay_owner`, but the app then has
  full owner rights. Add `PG_APP_PASSWORD` and `OWNER_DATABASE_URL`, and point `DATABASE_URL` at `tracepay_app`.

## Project layout

```
db/migrations/   001 core tables and status lookups · 002 integrity triggers, state machine, audit · 003 constraint engine
                 004 tracing · 005 recovery procedures · 006 views, indexes · 007 users, accounts, transfers
                 008 Neo4j outbox · 009 database roles   (each file builds its part of the final schema directly)
db/seed/         010 demo scenario (T1-T7) · 020 96-complaint corpus · 030 laundering chains
                 narratives.json: the same 96 narratives with their scam-type labels, for judging search quality
db/graph/        Neo4j schema (applied by graph-sync)
db/tests/        01_core … 09_roles: one test file per migration · 10_alter_drop: ALTER/DROP demo (rolled back)
                 _setup.sql / _report.sql: shared helpers (ok, fails, check, act_as) · race demo (RACE_DEMO.md)
db/queries/      query catalogue
scripts/         reset-db · run-db-tests · embed · graph-sync · graph-test
experiments/     concurrency lab
src/lib/         db.ts (pool, per-transaction user context) · session.ts, auth.ts (sign-in, live role check)
                 api.ts (validated route wrapper) · errors.ts, friendly.ts (DB error -> plain language)
                 graph.ts, graphQueries.mjs, traceGraph.ts (Neo4j / CTE tracing) · embed.ts
src/proxy.ts     sign-in check for the role areas (each page checks the current role itself)
src/app/         customer: complaints, send money, report · investigator: queue, case workspace
                 supervisor: dashboard, cases + case page, freezes & recovery, transactions, users, audit log
docs/screenshots written by npm run test:e2e
```

