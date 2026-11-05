# TracePay: Multi-Hop Disputed-Fund Attribution and Fraud Recovery Coordination


TracePay traces where disputed money went after a fraud complaint, attributes it to victims without
double counting, and shares limited frozen funds across victims. Six financial limits are enforced
**inside PostgreSQL** by a reusable, concurrency-safe constraint engine (a restricted `CREATE ASSERTION`).

| | |
|---|---|
| SQL database | PostgreSQL 16 (system of record: money, cases, tracing, audit) |
| Second paradigm | pgvector in the same server (similar-complaint search) |
| Web app | Next.js 16 (App Router, TypeScript), Route Handlers as the API |
| Roles | Customer, Investigator, Supervisor |


## Prerequisites

Docker Desktop, Node.js 20+, Git. Windows PowerShell commands are shown; the SQL runs inside the container.

## Setup (first time)

```powershell
git clone https://github.com/Prajwal-13-dev/TracePay.git
cd TracePay
Copy-Item .env.example .env      # then edit .env (see below)
npm install
```

`.env` (git-ignored, never committed):

```
PG_OWNER_PASSWORD=<letters and digits only>
DATABASE_URL=postgres://tracepay_owner:<same password>@localhost:5433/tracepay
AUTH_SECRET=<32+ random characters>
```

Generate a secret: `[Convert]::ToBase64String((1..32 | % { Get-Random -Max 256 }))`

The database is published on host port **5433** so it never clashes with a locally installed PostgreSQL on 5432.

## Build the database (run again any time for a clean state)

```powershell
docker compose down -v
docker compose up -d --wait
foreach ($f in "001_core","002_integrity","003_engine","004_tracing","005_recovery","006_views_search","008_alter_demo") { docker compose exec postgres psql -v ON_ERROR_STOP=1 -q -U tracepay_owner -d tracepay -f /db/migrations/$f.sql }
foreach ($s in "010_scenario","020_narratives") { docker compose exec postgres psql -v ON_ERROR_STOP=1 -q -U tracepay_owner -d tracepay -f /db/seed/$s.sql }
npm run embed      # narrative embeddings; first run downloads the model (~23 MB)
```

## Run

```powershell
npm run dev        # http://localhost:3000
```

Demo accounts (password `Demo@1234` for all):

| Email | Role |
|---|---|
| `v1@demo.in`, `v2@demo.in` | Customer (victims of the demo scenario) |
| `inv@demo.in` | Investigator |
| `sup1@demo.in`, `sup2@demo.in` | Supervisor |

Public sign-up always creates a Customer; staff exist only in the seed.

## Tests (79 checks)

```powershell
foreach ($t in "t01_t05_integrity","t06_t19_engine","t08_t13_tracing","t14_t22_recovery","t_alter_demo") { docker compose exec postgres psql -U tracepay_owner -d tracepay -f /db/tests/$t.sql }
```

Each file runs in one transaction, prints `PASS`/`FAIL` lines, and rolls back. Query catalogue (every required SQL
concept on a demo state): `docker compose exec postgres psql -U tracepay_owner -d tracepay -f /db/queries/catalogue.sql`.
Two-terminal concurrency demo: [`db/tests/RACE_DEMO.md`](db/tests/RACE_DEMO.md).

## Project layout

```
db/migrations/   001 core schema · 002 integrity triggers · 003 constraint engine · 004 tracing
                 005 recovery procedures · 006 views, indexes · 008 ALTER/DROP demo   (007 reserved: DB roles)
db/seed/         010 demo scenario (T1-T7) · 020 96-complaint corpus (+ narratives.json with labels)
db/tests/        PASS/FAIL test suites · race demo
db/queries/      query catalogue
scripts/         embed.mjs (narrative embeddings)
src/lib/         db.ts (pool, per-transaction user context) · session.ts, auth.ts (sign-in, roles)
                 api.ts (validated route wrapper) · errors.ts (DB error -> HTTP) · embed.ts
src/proxy.ts     page protection by role
src/app/         customer / investigator / supervisor pages · api/ route handlers
docs/            documentation, ER diagram, screenshots, demo script
```

