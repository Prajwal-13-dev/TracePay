// Every run starts from the same seeded database (handbook demo scenario).
// Set E2E_SKIP_RESET=1 to keep the current data, E2E_GRAPH=1 to also reload Neo4j.
import { execSync } from 'node:child_process';

export default function globalSetup() {
  if (process.env.E2E_SKIP_RESET) return;
  execSync('node --env-file-if-exists=.env scripts/reset-db.mjs' + (process.env.E2E_GRAPH ? ' --graph' : ''), { stdio: 'inherit' });
}
