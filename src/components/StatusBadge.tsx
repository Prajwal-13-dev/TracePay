// One colour per status, used on every page. Labels match the status lookup tables (001_core.sql).
const LABEL: Record<string, string> = {
  SUBMITTED: 'Submitted', UNDER_REVIEW: 'Under review', INVESTIGATING: 'Investigating', RECOVERY: 'Recovery',
  CLOSED: 'Closed', REJECTED: 'Rejected', REQUESTED: 'Requested', DECLINED: 'Declined', ACTIVE: 'Active',
  RELEASED: 'Released', EXPIRED: 'Expired', SETTLED: 'Settled', PAID: 'Paid', CANCELLED: 'Cancelled',
  PROCESSED: 'Processed',
};
export default function StatusBadge({ status }: { status: string }) {
  return <span className={`badge s-${status}`}>{LABEL[status] ?? status}</span>;
}
export const statusLabel = (s: string) => LABEL[s] ?? s;
