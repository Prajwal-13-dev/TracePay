// Computes embeddings for every case that has none, or whose narrative changed (source_hash mismatch).
// Same model and settings as src/lib/embed.ts.  Run:  npm run embed
import pg from 'pg';
import { pipeline, env } from '@huggingface/transformers';

const MODEL = 'Xenova/all-MiniLM-L6-v2';
env.cacheDir = './.cache/transformers';
const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });

const { rows } = await pool.query(`
  SELECT c.case_id, c.narrative
  FROM fraud_cases c LEFT JOIN case_embeddings e USING (case_id)
  WHERE e.case_id IS NULL OR e.source_hash <> encode(sha256(convert_to(c.narrative, 'UTF8')), 'hex')
  ORDER BY c.case_id`);
console.log(`${rows.length} case(s) need an embedding. Loading model ${MODEL} (first run downloads ~23 MB)...`);

const extractor = await pipeline('feature-extraction', MODEL);
let done = 0;
for (const r of rows) {
  const out = await extractor(r.narrative, { pooling: 'mean', normalize: true });
  await pool.query(
    `INSERT INTO case_embeddings (case_id, model, embedding, source_hash)
     VALUES ($1, $2, $3::vector, encode(sha256(convert_to($4, 'UTF8')), 'hex'))
     ON CONFLICT (case_id) DO UPDATE
       SET embedding = EXCLUDED.embedding, source_hash = EXCLUDED.source_hash, model = EXCLUDED.model, embedded_at = now()`,
    [r.case_id, MODEL, '[' + Array.from(out.data).join(',') + ']', r.narrative]);
  if (++done % 20 === 0) console.log(`  ${done}/${rows.length}`);
}
console.log(`Embedded ${done} narrative(s).`);
await pool.end();
