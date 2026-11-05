// Turns a complaint narrative into a 384-number vector (all-MiniLM-L6-v2, mean pooling, L2-normalised).
// Runs inside Node with transformers.js: no Python service. The model downloads once into .cache/.
import 'server-only';

export const EMBED_MODEL = 'Xenova/all-MiniLM-L6-v2';
type Extractor = (text: string, opts: { pooling: 'mean'; normalize: boolean }) => Promise<{ data: Float32Array }>;
let extractor: Promise<Extractor> | null = null;

export async function embed(text: string): Promise<number[]> {
  const { pipeline, env } = await import('@huggingface/transformers');
  env.cacheDir = './.cache/transformers';
  extractor ??= pipeline('feature-extraction', EMBED_MODEL) as unknown as Promise<Extractor>;
  const out = await (await extractor)(text, { pooling: 'mean', normalize: true });
  return Array.from(out.data);
}

// pgvector accepts the text form '[0.1,0.2,...]'
export const toVector = (v: number[]) => '[' + v.join(',') + ']';

// Never let a model problem block a complaint: the vector can be backfilled with `npm run embed`.
export async function tryEmbed(text: string): Promise<number[] | null> {
  try {
    return await embed(text);
  } catch (e) {
    console.error('embedding skipped (run `npm run embed` later):', (e as Error).message);
    return null;
  }
}
