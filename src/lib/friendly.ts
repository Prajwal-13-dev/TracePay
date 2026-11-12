// Turns an API error body into one plain-language sentence for the UI (safe on client and server).
// The engine raises TP001 with DETAIL 'parent_key=.. limit=.. total=.. excess=..'.
const rupee = (n: number) => '₹' + n.toLocaleString('en-IN', { maximumFractionDigits: 2 });

const RULES: Record<string, (l: string, t: string, x: string) => string> = {
  txn_capacity: (l, t, x) =>
    `This transfer moved only ${l} in total. With this link, all cases together would claim ${t}. Lower the amount by ${x}.`,
  node_outflow: (l, t, x) =>
    `This case traced only ${l} into the previous hop, but links leaving it would total ${t}. Lower the amount by ${x}.`,
  freeze_within_balance: (l, t, x) =>
    `The account holds ${l}. Active freezes on it would total ${t}, which is ${x} more than it holds.`,
  allocation_within_freeze: (l, t, x) =>
    `This freeze holds ${l}, but allocations would total ${t}. Lower the amount by ${x}.`,
  allocation_within_loss: (l, t, x) =>
    `The victim's verified loss is ${l}, but allocations would total ${t}. Lower the amount by ${x}.`,
  refund_within_allocation: (l, t, x) =>
    `The allocation is ${l}, but refunds would total ${t}. Lower the amount by ${x}.`,
};

export type ApiError = { error?: string; code?: string; detail?: string | null; issues?: string[] };

export function friendlyError(body: ApiError, status?: number): string {
  if (body.code === 'TP001' && body.error && body.detail) {
    const rule = /invariant (\w+)/.exec(body.error)?.[1];
    const num = (k: string) => Number(new RegExp(`${k}=(-?[\\d.]+)`).exec(body.detail!)?.[1] ?? NaN);
    const [l, t, x] = ['limit', 'total', 'excess'].map(num);
    if (rule && RULES[rule] && [l, t, x].every(Number.isFinite)) return RULES[rule](rupee(l), rupee(t), rupee(x));
  }
  if (body.code === 'TP006' && body.error) return body.error.charAt(0).toUpperCase() + body.error.slice(1) + '.';
  if (body.code === 'TP003') return `That step isn't allowed right now: ${body.error}.`;
  if (body.code === '40001' || body.code === '40P01') return 'Someone else changed this at the same moment. Please try again.';
  if (body.issues?.length) return 'Please check: ' + body.issues.join('; ');
  if (status === 401) return 'Your session has expired. Please sign in again.';
  if (status === 403) return body.error ? `Not allowed: ${body.error}.` : 'You are not allowed to do that.';
  if (body.error) return body.error.charAt(0).toUpperCase() + body.error.slice(1) + '.';
  return status ? `Something went wrong (HTTP ${status}).` : 'Something went wrong.';
}
