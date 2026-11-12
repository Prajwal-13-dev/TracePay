// Runs every SQL test file in db/tests (01_*.sql, 02_*.sql, ...) and prints a PASS/FAIL summary.
// Each file runs in one transaction and rolls itself back (see db/tests/_setup.sql).
// The tests need the freshly seeded demo data (they file complaints on T1, T6, T8 ...), so by default they run
// in a SEPARATE database, tracepay_test, rebuilt from scratch first. Your demo database is never touched.
//   npm run test:db                 rebuild tracepay_test, run all tests there
//   npm run test:db -- 05           only the files whose name starts with 05
//   npm run test:db -- --current    run against the main database instead (needs freshly reset data)
// Without Docker: PSQL="psql -h localhost -p 5433 -U tracepay_owner -d tracepay" npm run test:db
import { execSync } from 'node:child_process';
import { readdirSync } from 'node:fs';

const args = process.argv.slice(2);
const only = args.find(a => !a.startsWith('--'));
const DB = args.includes('--current') ? 'tracepay' : 'tracepay_test';
const local = process.env.PSQL;
const psqlOn = (db) => local ? `${local.replace(/\s-d\s+\S+/, '')} -d ${db}`
                             : `docker compose exec -T postgres psql -U tracepay_owner -d ${db}`;

if (DB === 'tracepay_test') {
  process.stdout.write('building a fresh test database (tracepay_test) ... ');
  const quiet = { stdio: ['ignore', 'ignore', 'inherit'], env: { ...process.env, PGOPTIONS: '-c client_min_messages=warning' } };
  execSync(`${psqlOn('postgres')} -q -c "DROP DATABASE IF EXISTS tracepay_test WITH (FORCE)" -c "CREATE DATABASE tracepay_test"`, quiet);
  execSync(`node scripts/reset-db.mjs --db=tracepay_test`, quiet);
  console.log('done\n');
}

const FILES = readdirSync(new URL('../db/tests/', import.meta.url))
  .filter(f => /^\d\d_.+\.sql$/.test(f) && (!only || f.startsWith(only)))
  .sort();
let pass = 0, fail = 0;
for (const f of FILES) {
  const cmd = `${psqlOn(DB)} -f ${local ? '' : '/'}db/tests/${f}`;
  // stderr is captured too: a psql ERROR (a broken test script) counts as a failure.
  const out = execSync(cmd + ' 2>&1', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const p = (out.match(/^\s*PASS\b/gm) ?? []).length;
  const x = (out.match(/^\s*FAIL\b/gm) ?? []).length + (out.match(/\bERROR:/g) ?? []).length;
  pass += p; fail += x;
  console.log(`${x ? 'FAIL' : 'ok  '} ${f.replace(/\.sql$/, '').padEnd(20)} ${p} passed${x ? `, ${x} failed` : ''}`);
  if (x) console.log(out.split('\n').filter(l => /^\s*FAIL\b|ERROR:/.test(l)).join('\n'));
}
console.log(`\n${pass + fail} checks in ${FILES.length} files on ${DB}: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
