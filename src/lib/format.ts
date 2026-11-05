export const inr = (v: string | number | null | undefined) =>
  v === null || v === undefined ? '—' : '₹' + Number(v).toLocaleString('en-IN', { maximumFractionDigits: 2 });
export const when = (v: string | Date | null | undefined) =>
  v ? new Date(v).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', dateStyle: 'medium', timeStyle: 'short' }) : '—';
