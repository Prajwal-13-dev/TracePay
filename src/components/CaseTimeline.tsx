// Parcel-tracker style progress for a case, built from case_status_history.
import { statusLabel } from './StatusBadge';

const PATH = ['SUBMITTED', 'UNDER_REVIEW', 'INVESTIGATING', 'RECOVERY', 'CLOSED'];
const fmt = (d: Date | string) => new Date(d).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' });

export default function CaseTimeline({ status, createdAt, history }: {
  status: string; createdAt: Date | string; history: { to_status: string; changed_at: Date | string }[];
}) {
  const reached = new Map<string, Date | string>([['SUBMITTED', createdAt]]);
  for (const h of history) if (!reached.has(h.to_status)) reached.set(h.to_status, h.changed_at);
  const rejected = status === 'REJECTED';
  const steps = rejected ? [...PATH.filter(s => reached.has(s)), 'REJECTED'] : PATH;
  const cur = steps.indexOf(status);
  return (
    <div className="timeline" role="list" aria-label="Case progress">
      {steps.map((s, i) => {
        const cls = s === 'REJECTED' ? 'bad current' : i < cur ? 'done' : i === cur ? (s === 'CLOSED' ? 'done current' : 'current') : '';
        const at = reached.get(s);
        return (
          <div key={s} role="listitem" className={'tl-step ' + cls}>
            <div className="tl-dot">{i < cur || s === 'CLOSED' && i === cur ? '✓' : s === 'REJECTED' ? '✕' : ''}</div>
            {statusLabel(s)}
            {at && <span className="tl-when">{fmt(at)}</span>}
          </div>
        );
      })}
    </div>
  );
}
