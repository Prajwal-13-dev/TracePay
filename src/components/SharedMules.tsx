// Server component: accounts that money from two or more open cases reaches (Neo4j query).
// These hold mixed money from several victims, so they are the most useful freeze targets.
import Link from 'next/link';
import { sharedMules } from '@/lib/graph';
import { inr } from '@/lib/format';

export default async function SharedMules() {
  const rows = await sharedMules();
  return (
    <div className="card">
      <h2>Shared mule accounts</h2>
      <p className="muted">Accounts reached by the money of two or more open cases (Neo4j path search, same time rules as the trace).</p>
      {rows === null ? <p className="muted">The graph service is offline, so this list is unavailable. Start Neo4j and the sync worker.</p>
        : rows.length === 0 ? <p className="muted">No account is shared between open cases right now.</p> : (
        <table>
          <thead><tr><th>Account</th><th>Owner</th><th>Balance</th><th>Cases</th></tr></thead>
          <tbody>{rows.map(r => (
            <tr key={r.account_id}>
              <td>{r.account_ref}</td><td>{r.owner}</td><td>{inr(r.balance)}</td>
              <td>{r.case_ids.map((id, i) => <span key={id}>{i > 0 && ', '}<Link href={`/investigator/cases/${id}`}>#{id}</Link></span>)}
                <span className="badge warn"> {r.case_count} cases</span></td>
            </tr>
          ))}</tbody>
        </table>
      )}
    </div>
  );
}
