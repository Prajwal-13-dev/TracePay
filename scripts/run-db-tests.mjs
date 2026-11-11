// Runs every SQL test file in db/tests (01_*.sql, 02_*.sql, ...) and prints a PASS/FAIL summary.
// Each file runs in one transaction and rolls itself back (see db/tests/_setup.sql).
//   npm run test:db     (Docker)   or   PSQL="psql -h ... -U tracepay_owner -d tracepay" npm run test:db
//   npm run test:db -- 05          run only the files whose name starts with 05
import { execSync } from 'node:child_process';
import { readdirSync } from 'node:fs';

const only = process.argv[2];
const FILES = readdirSync(new URL('../db/tests/', import.meta.url))
  .filter(f => /^\d\d_.+\.sql$/.test(f) && (!only || f.startsWith(only)))
  .sort();
const local = process.env.PSQL;
let pass = 0, fail = 0;
for (const f of FILES) {
  const cmd = local ? `${local} -f db/tests/${f}`
                    : `docker compose exec -T postgres psql -U tracepay_owner -d tracepay -f /db/tests/${f}`;
  // stderr is captured too: a psql ERROR (a broken test script) counts as a failure.
  const out = execSync(cmd + ' 2>&1', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const p = (out.match(/^\s*PASS\b/gm) ?? []).length;
  const x = (out.match(/^\s*FAIL\b/gm) ?? []).length + (out.match(/\bERROR:/g) ?? []).length;
  pass += p; fail += x;
  console.log(`${x ? 'FAIL' : 'ok  '} ${f.replace(/\.sql$/, '').padEnd(20)} ${p} passed${x ? `, ${x} failed` : ''}`);
  if (x) console.log(out.split('\n').filter(l => /^\s*FAIL\b|ERROR:/.test(l)).join('\n'));
}
console.log(`\n${pass + fail} checks in ${FILES.length} files: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
