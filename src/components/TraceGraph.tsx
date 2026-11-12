'use client';
// Interactive money trail. Accounts are nodes, transfers are arrows (from Neo4j path search).
// Click an arrow to confirm a link; click an account to see it or request a freeze.
// Every write still goes through PostgreSQL (confirm_link / request_freeze) and its money rules.
import { useEffect, useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import cytoscape, { Core } from 'cytoscape';
import type { CaseTraceGraph, GraphEdge, GraphAccount } from '@/lib/traceGraph';
import { friendlyError } from '@/lib/friendly';

const inr = (n: number) => '₹' + n.toLocaleString('en-IN', { maximumFractionDigits: 2 });
const time = (s: string) => new Date(s).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' });

type Selection = { kind: 'edge' | 'account'; id: number } | null;

export default function TraceGraph({ caseId, graph, fifo, canWork, canFreeze }: {
  caseId: number; graph: CaseTraceGraph; fifo: Record<number, number>; canWork: boolean; canFreeze: boolean;
}) {
  const box = useRef<HTMLDivElement>(null);
  const cy = useRef<Core | null>(null);
  const [sel, setSel] = useState<Selection>(null);
  const router = useRouter();

  const accounts = useMemo(() => new Map(graph.accounts.map(a => [a.id, a])), [graph]);
  const edges = useMemo(() => new Map(graph.edges.map(e => [e.txn_id, e])), [graph]);

  useEffect(() => {
    if (!box.current) return;
    const root = graph.edges.find(e => e.depth === 0);
    // Busy graphs: arrow labels appear only on hover/selection (plus the disputed and confirmed arrows).
    const busy = graph.edges.length > 10;
    cy.current = cytoscape({
      container: box.current,
      elements: [
        ...graph.accounts.map(a => ({
          data: { id: 'a' + a.id, label: `${a.owner}\n${a.ref.slice(-4)} · ${inr(a.balance)}` },
          classes: [a.isVictim && 'victim', a.isRoot && 'root', a.sharedCases > 1 && 'shared', a.frozen > 0 && 'frozen']
            .filter(Boolean).join(' '),
        })),
        ...graph.edges.map(e => ({
          data: { id: 't' + e.txn_id, source: 'a' + e.from_id, target: 'a' + e.to_id,
                  label: `${e.ref} · ${inr(e.amount)} · ${time(e.occurred_at)}` },
          classes: [e.depth === 0 && 'disputed', e.confirmed_inflow > 0 && 'confirmed', busy && 'quiet'].filter(Boolean).join(' '),
        })),
      ],
      layout: { name: 'breadthfirst', directed: true, roots: root ? ['a' + root.from_id] : undefined, spacingFactor: 1.1, padding: 20 },
      wheelSensitivity: 0.2, minZoom: 0.4, maxZoom: 2.5,
      style: [
        { selector: 'node', style: {
            'shape': 'round-rectangle', 'width': 170, 'height': 52, 'background-color': '#ffffff',
            'border-width': 1.5, 'border-color': '#c3cad6', 'label': 'data(label)', 'text-wrap': 'wrap',
            'text-valign': 'center', 'font-size': 12, 'color': '#1d2330' } },
        { selector: 'node.victim', style: { 'background-color': '#fdecea', 'border-color': '#b42318' } },
        { selector: 'node.root', style: { 'border-color': '#1f5fbf', 'border-width': 2.5 } },
        { selector: 'node.shared', style: { 'background-color': '#fff4e5', 'border-color': '#d97706', 'border-width': 3 } },
        { selector: 'node.frozen', style: { 'border-style': 'double', 'border-width': 5, 'border-color': '#067647' } },
        { selector: 'edge', style: {
            'curve-style': 'bezier', 'control-point-step-size': 70, 'target-arrow-shape': 'triangle',
            'text-margin-y': -8, 'width': 2, 'line-color': '#b6bfcc',
            'target-arrow-color': '#b6bfcc', 'line-style': 'dashed', 'label': 'data(label)', 'font-size': 10,
            'text-background-color': '#ffffff', 'text-background-opacity': 1, 'text-background-padding': '2px',
            'color': '#647086' } },
        { selector: 'edge.confirmed', style: { 'line-style': 'solid', 'line-color': '#067647', 'target-arrow-color': '#067647', 'width': 3, 'color': '#067647' } },
        { selector: 'edge.disputed', style: { 'line-style': 'solid', 'line-color': '#b42318', 'target-arrow-color': '#b42318', 'width': 3.5, 'color': '#b42318' } },
        { selector: 'edge.quiet', style: { 'label': '' } },
        { selector: 'edge.quiet.disputed, edge.quiet.confirmed, edge.quiet.hover, edge.quiet:selected', style: { 'label': 'data(label)' } },
        { selector: 'edge.hover', style: { 'width': 3, 'line-color': '#1f5fbf', 'target-arrow-color': '#1f5fbf', 'z-index': 9 } },
        { selector: ':selected', style: { 'overlay-color': '#1f5fbf', 'overlay-opacity': 0.15, 'overlay-padding': 6 } },
      ],
    });
    cy.current.on('tap', 'edge', ev => {
      setSel({ kind: 'edge', id: Number(ev.target.id().slice(1)) });
    });
    cy.current.on('mouseover', 'edge', ev => ev.target.addClass('hover'));
    cy.current.on('mouseout', 'edge', ev => ev.target.removeClass('hover'));
    cy.current.on('tap', 'node', ev => {
      setSel({ kind: 'account', id: Number(ev.target.id().slice(1)) });
    });
    cy.current.on('tap', ev => { if (ev.target === cy.current) setSel(null); });
    return () => { cy.current?.destroy(); cy.current = null; };
  }, [graph, accounts, edges]);

  // Look the selection up in the latest data, so the panel is fresh after router.refresh().
  const selEdge = sel?.kind === 'edge' ? edges.get(sel.id) : undefined;
  const selAccount = sel?.kind === 'account' ? accounts.get(sel.id) : undefined;

  return (
    <div className="trace-graph">
      <div className="tg-head">
        <div className="legend">
          <span><i className="sw victim" />Victim</span>
          <span><i className="sw root" />First receiver</span>
          <span><i className="sw shared" />Shared mule (several cases)</span>
          <span><i className="sw frozen" />Frozen: outgoing blocked</span>
          <span><i className="ln disputed" />Disputed</span>
          <span><i className="ln confirmed" />Confirmed</span>
          <span><i className="ln candidate" />Suggested path</span>
        </div>
        <span className={'source ' + graph.source}>
          {graph.source === 'neo4j' ? 'Paths from Neo4j' : 'Neo4j offline: paths from PostgreSQL'}
        </span>
      </div>
      <div className="tg-body">
        <div ref={box} className="tg-canvas" aria-label="Money trail graph" />
        <aside className="tg-panel">
          {!selEdge && !selAccount && <p className="muted">Point at an arrow to see the transfer; click it {canWork ? 'to confirm it' : 'for details'}. Click an account to see its balance
            {canFreeze ? ' or request a freeze' : ''}. Scroll to zoom, drag to move.</p>}
          {selEdge && <EdgePanel key={selEdge.txn_id} caseId={caseId} e={selEdge}
            fifo={fifo[selEdge.txn_id]} canWork={canWork} onDone={() => router.refresh()} />}
          {selAccount && <AccountPanel key={selAccount.id} caseId={caseId} a={selAccount}
            canFreeze={canFreeze} onDone={() => router.refresh()} />}
        </aside>
      </div>
    </div>
  );
}

function usePost(onDone: () => void) {
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  async function post(url: string, body: unknown, okText: string) {
    setBusy(true); setMsg(null);
    const res = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    const data = await res.json().catch(() => ({}));
    setBusy(false);
    if (!res.ok) { setMsg({ ok: false, text: friendlyError(data, res.status) }); return; }
    setMsg({ ok: true, text: okText });
    onDone();
  }
  return { busy, msg, post };
}

function EdgePanel({ caseId, e, fifo, canWork, onDone }: {
  caseId: number; e: GraphEdge; fifo?: number; canWork: boolean; onDone: () => void;
}) {
  const { busy, msg, post } = usePost(onDone);
  const max = Math.min(e.remaining_capacity, e.parent_outflow_left, e.upper_bound);
  const suggested = Math.min(fifo ?? max, max);
  const [amount, setAmount] = useState(suggested > 0 ? String(suggested) : '');
  const [method, setMethod] = useState(fifo ? 'FIFO' : 'MANUAL');

  return (
    <>
      <h3>{e.ref} {e.depth === 0 ? <span className="badge danger">disputed</span> : <span className="badge">hop {e.depth}</span>}</h3>
      <dl className="kv">
        <dt>From → To</dt><dd>{e.from_ref} → {e.to_ref}</dd>
        <dt>Amount</dt><dd>{inr(e.amount)}</dd>
        <dt>When</dt><dd>{new Date(e.occurred_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' })}</dd>
        {e.parent_ref && <><dt>Comes after</dt><dd>{e.parent_ref}</dd></>}
        <dt>Path</dt><dd>{e.path.length} transfer{e.path.length > 1 ? 's' : ''} from the disputed one</dd>
        <dt>Upper bound</dt><dd>{inr(e.upper_bound)} <span className="muted">(smallest transfer on the path)</span></dd>
        <dt>Confirmed for this case</dt><dd>{e.confirmed_inflow ? inr(e.confirmed_inflow) : 'Not yet'}</dd>
        <dt>Claimed by all cases</dt><dd>{inr(e.all_cases_inflow)} of {inr(e.amount)}</dd>
      </dl>
      {e.depth > 0 && canWork && (
        e.parent_confirmed ? (
          <form className="stack" onSubmit={ev => { ev.preventDefault();
            post(`/api/cases/${caseId}/links`, { fromTxn: e.parent_txn_id, toTxn: e.txn_id, amount: Number(amount), method },
                 `Link ${e.parent_ref} → ${e.ref} confirmed.`); }}>
            <div className="field"><label>Amount to attribute (₹)</label>
              <input type="number" step="0.01" min="0.01" value={amount} onChange={x => setAmount(x.target.value)} required />
              <span className="hint">Up to {inr(max)} can still be attributed here{fifo ? `; FIFO suggests ${inr(fifo)}` : ''}.</span>
            </div>
            <div className="field"><label>Method</label>
              <select value={method} onChange={x => setMethod(x.target.value)}>
                <option value="FIFO">FIFO</option><option value="MANUAL">Manual</option>
              </select>
            </div>
            <button disabled={busy}>{busy ? 'Saving…' : `Confirm ${e.parent_ref} → ${e.ref}`}</button>
          </form>
        ) : <p className="muted">Confirm {e.parent_ref} first. A link can only start from a confirmed transfer.</p>
      )}
      {msg && <p className={msg.ok ? 'ok' : 'error'}>{msg.text}</p>}
    </>
  );
}

function AccountPanel({ caseId, a, canFreeze, onDone }: {
  caseId: number; a: GraphAccount; canFreeze: boolean; onDone: () => void;
}) {
  const { busy, msg, post } = usePost(onDone);
  const free = Math.max(0, a.balance - a.frozen);
  const [amount, setAmount] = useState(free > 0 ? String(free) : '');
  return (
    <>
      <h3>{a.owner}</h3>
      <dl className="kv">
        <dt>Account</dt><dd>{a.ref}</dd>
        <dt>Balance</dt><dd>{inr(a.balance)}</dd>
        <dt>Already frozen</dt><dd>{inr(a.frozen)}{a.frozen > 0 && <span className="badge s-ACTIVE"> outgoing blocked</span>}</dd>
        <dt>Cases reaching it</dt><dd>{a.sharedCases || 0}{a.sharedCases > 1 && <span className="badge warn"> shared mule</span>}</dd>
      </dl>
      {canFreeze && !a.isVictim && (free > 0 ? (
        <form className="stack" onSubmit={ev => { ev.preventDefault();
          post('/api/freezes', { caseId, accountId: a.id, amount: Number(amount) }, 'Freeze requested. A different supervisor must approve it.'); }}>
          <div className="field"><label>Freeze amount (₹)</label>
            <input type="number" step="0.01" min="0.01" value={amount} onChange={x => setAmount(x.target.value)} required />
            <span className="hint">{inr(free)} is not frozen yet.</span>
          </div>
          <button disabled={busy}>{busy ? 'Sending…' : 'Request freeze'}</button>
        </form>
      ) : <p className="muted">Nothing left to freeze on this account.</p>)}
      {a.frozen > 0 && <p className="muted">While a freeze is active no money can leave this account. At settlement only the
        refunded amount is paid out; the rest stays with the account holder.</p>}
      {msg && <p className={msg.ok ? 'ok' : 'error'}>{msg.text}</p>}
    </>
  );
}
