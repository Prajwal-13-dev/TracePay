// FR-10: Similar-Scam Finder. Hybrid retrieval with Reciprocal Rank Fusion (handbook 18.3):
//   vector list  = top 50 by cosine distance (pgvector <=>, HNSW index)
//   text list    = top 50 by full-text rank, with the narrative's terms OR-ed together
//   RRF score    = 1/(60 + vector rank) + 1/(60 + text rank)   (ranks, so the two scales never mix)
// The shared-account flag says whether the two confirmed traces reached a common account.
import Link from 'next/link';
import { query } from '@/lib/db';

export default async function SimilarCases({ caseId }: { caseId: number }) {
  const [me] = await query<{ embedding: string }>('SELECT embedding::text FROM case_embeddings WHERE case_id = $1', [caseId]);
  if (!me) {
    return (
      <div className="card">
        <h2>Similar complaints</h2>
        <p className="muted">No embedding for this case yet. Run <code>npm run embed</code> to compute missing vectors.</p>
      </div>
    );
  }
  const rows = await query<{ case_id: string; status: string; narrative: string; cosine_sim: string | null;
    text_rank: string | null; rrf_score: string; shares_account: boolean }>(
    `WITH q AS (
       SELECT replace(plainto_tsquery('english', c.narrative)::text, '&', '|')::tsquery AS qtext
       FROM fraud_cases c WHERE c.case_id = $1
     ),
     vec AS (
       SELECT e.case_id, ROW_NUMBER() OVER (ORDER BY e.embedding <=> $2::vector) AS r,
              1 - (e.embedding <=> $2::vector) AS cosine_sim
       FROM case_embeddings e WHERE e.case_id <> $1
       ORDER BY e.embedding <=> $2::vector LIMIT 50
     ),
     txt AS (
       SELECT c.case_id, ROW_NUMBER() OVER (ORDER BY ts_rank_cd(c.search_vector, q.qtext, 32) DESC) AS r,
              ts_rank_cd(c.search_vector, q.qtext, 32) AS text_rank
       FROM fraud_cases c, q
       WHERE c.search_vector @@ q.qtext AND c.case_id <> $1
       ORDER BY text_rank DESC LIMIT 50
     ),
     fused AS (
       SELECT COALESCE(vec.case_id, txt.case_id) AS case_id, vec.cosine_sim, txt.text_rank,
              COALESCE(1.0 / (60 + vec.r), 0) + COALESCE(1.0 / (60 + txt.r), 0) AS rrf_score
       FROM vec FULL JOIN txt ON txt.case_id = vec.case_id
     )
     SELECT f.case_id, c.status, c.narrative, f.cosine_sim, f.text_rank, f.rrf_score,
            EXISTS (SELECT 1 FROM trace_accounts a JOIN trace_accounts b ON b.account_id = a.account_id
                    WHERE a.case_id = $1 AND b.case_id = f.case_id) AS shares_account
     FROM fused f JOIN fraud_cases c ON c.case_id = f.case_id
     ORDER BY f.rrf_score DESC LIMIT 10`, [caseId, me.embedding]);

  return (
    <div className="card">
      <h2>Similar complaints</h2>
      <p className="muted">Matched by meaning (vector) and by words (full-text), fused by rank. Leads to review, never automatic links.</p>
      <table>
        <thead><tr><th>Case</th><th>Narrative</th><th>Cosine</th><th>Text rank</th><th>RRF</th><th>Shares account</th></tr></thead>
        <tbody>{rows.map(r => (
          <tr key={r.case_id}>
            <td><Link href={`/investigator/cases/${r.case_id}`}>#{r.case_id}</Link><div className="muted">{r.status}</div></td>
            <td style={{ maxWidth: 420 }}>{r.narrative.length > 160 ? r.narrative.slice(0, 160) + '…' : r.narrative}</td>
            <td>{r.cosine_sim === null ? '—' : Number(r.cosine_sim).toFixed(3)}</td>
            <td>{r.text_rank === null ? '—' : Number(r.text_rank).toFixed(3)}</td>
            <td>{Number(r.rrf_score).toFixed(4)}</td>
            <td>{r.shares_account ? <span className="badge">shared account</span> : ''}</td>
          </tr>
        ))}
        {rows.length === 0 && <tr><td colSpan={6} className="muted">No other complaints yet.</td></tr>}</tbody>
      </table>
    </div>
  );
}
