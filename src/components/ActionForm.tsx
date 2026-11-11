'use client';
// Generic form: sends JSON to an API route, shows the database's answer (including TP001 excess
// details), then refreshes the server-rendered page so tables show the new state.
import { useId, useState } from 'react';
import { useRouter } from 'next/navigation';
import { friendlyError } from '@/lib/friendly';

export type Field = {
  name: string; label: string;
  type?: 'text' | 'number' | 'textarea' | 'select' | 'hidden';
  options?: { value: string | number; label: string }[];
  defaultValue?: string | number; required?: boolean; step?: string; placeholder?: string;
  min?: number; max?: number;
};

export default function ActionForm({ endpoint, method = 'POST', fields = [], submit, extra = {},
                                     idempotent = false, confirm, inline = false, variant, success = 'Done' }: {
  endpoint: string; method?: 'POST' | 'PATCH' | 'DELETE'; fields?: Field[]; submit: string;
  extra?: Record<string, unknown>; idempotent?: boolean; confirm?: string; inline?: boolean;
  variant?: 'secondary' | 'danger' | 'ghost';
  success?: string;            // what to tell the user when it worked, e.g. "Freeze approved"
}) {
  const router = useRouter();
  const uid = useId();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [busy, setBusy] = useState(false);

  async function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    // Keep the form element: React clears e.currentTarget once the handler awaits.
    const form = e.currentTarget;
    if (confirm && !window.confirm(confirm)) return;
    const f = new FormData(form);
    const body: Record<string, unknown> = { ...extra };
    for (const fld of fields) {
      const v = f.get(fld.name);
      body[fld.name] = fld.type === 'number' ? (v === '' ? undefined : Number(v)) : v;
    }
    setBusy(true); setMsg(null);
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (idempotent) headers['Idempotency-Key'] = crypto.randomUUID();
    const res = await fetch(endpoint, { method, headers, body: method === 'DELETE' ? undefined : JSON.stringify(body) });
    const data = await res.json().catch(() => ({}));
    setBusy(false);
    if (!res.ok) {
      setMsg({ ok: false, text: friendlyError(data, res.status) });
      return;
    }
    setMsg({ ok: true, text: success });
    form.reset();
    router.refresh();
  }

  return (
    <form method="post" onSubmit={onSubmit} className={inline ? 'inline' : 'stack'}>
      {fields.map(fld => fld.type === 'hidden'
        ? <input key={fld.name} type="hidden" name={fld.name} defaultValue={fld.defaultValue} />
        : (
          <div key={fld.name} className="field">
            <label htmlFor={`${uid}-${fld.name}`}>{fld.label}</label>
            {fld.type === 'textarea' ? (
              <textarea id={`${uid}-${fld.name}`} name={fld.name} defaultValue={fld.defaultValue} required={fld.required} rows={3} placeholder={fld.placeholder} />
            ) : fld.type === 'select' ? (
              <select id={`${uid}-${fld.name}`} name={fld.name} defaultValue={fld.defaultValue} required={fld.required}>
                {fld.options?.map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
              </select>
            ) : (
              <input id={`${uid}-${fld.name}`} name={fld.name} type={fld.type ?? 'text'} defaultValue={fld.defaultValue}
                     required={fld.required} step={fld.step ?? (fld.type === 'number' ? '0.01' : undefined)}
                     // Money fields default to min 0.01. Not when a step is given: the browser counts steps from min.
                     min={fld.min ?? (fld.type === 'number' && !fld.step ? 0.01 : undefined)} max={fld.max}
                     placeholder={fld.placeholder} />
            )}
          </div>
        ))}
      <button disabled={busy} className={variant}>{busy ? '…' : submit}</button>
      {msg && <span className={msg.ok ? 'ok' : 'error'} role="status">{msg.text}</span>}
    </form>
  );
}
