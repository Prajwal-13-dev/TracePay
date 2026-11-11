// Rebuild the database from scratch: drop everything, run every migration and seed in order.
//   npm run db:reset             (uses `docker compose exec postgres psql`)
//   npm run db:reset -- --graph  (also wipes and reloads Neo4j)
// Without Docker, set PSQL to your own psql command, e.g.
//   PSQL="psql -h localhost -p 5433 -U tracepay_owner -d tracepay"
import { execSync } from 'node:child_process';

const MIGRATIONS = ['001_core', '002_integrity', '003_engine', '004_tracing', '005_recovery',
                    '006_views_search', '007_users_accounts', '008_graph_outbox', '009_db_roles'];
const SEEDS = ['010_scenario', '020_narratives', '030_chains'];

const local = process.env.PSQL;
const psql = (args) => local
  ? `${local} -v ON_ERROR_STOP=1 -q ${args}`
  : `docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -q -U tracepay_owner -d tracepay ${args}`;
const file = (dir, name) => (local ? `db/${dir}/` : `/db/${dir}/`) + name + '.sql';
const run = (cmd) => execSync(cmd, { stdio: ['ignore', 'ignore', 'inherit'],
  env: { ...process.env, PGOPTIONS: '-c client_min_messages=warning' } });

const graph = process.argv.includes('--graph');
run(psql(`-c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"`));
for (const m of MIGRATIONS) run(psql(`-f ${file('migrations', m)}`));
for (const s of SEEDS) run(psql(`-f ${file('seed', s)}`));
// The app's login role (009_db_roles) gets its password from .env. Roles are cluster-wide, so this is idempotent.
if (process.env.PG_APP_PASSWORD) {
  const pw = process.env.PG_APP_PASSWORD.replace(/'/g, "''");
  execSync(psql('-f -'), { input: `ALTER ROLE tracepay_app PASSWORD '${pw}';`, stdio: ['pipe', 'ignore', 'inherit'] });
}
if (graph) run('node --env-file=.env scripts/graph-sync.mjs --rebuild');
console.log('database rebuilt' + (graph ? ' (and Neo4j reloaded)' : ''));
