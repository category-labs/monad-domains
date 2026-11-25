import { useEffect, useMemo, useRef, useState } from "react";
import type { Address, Hex } from "viem";
import { l1 } from "../lib/chain";
import { EXPLORER } from "../lib/deployment";
import { type ChainTx, contractName, loadChainTxs } from "./chainTxs";
import { CUSTOMERS, addressOf } from "./customers";

/** How far back the feed looks when the page opens (Monad makes a few blocks a second). */
const BACKFILL_BLOCKS = 1_000n;
/** After a long pause (a background tab), catch up at most this far instead of everything. */
const MAX_CATCH_UP = 300n;
const SHOWN = 50;

type Filter = "companies" | "all";

const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;

function LockGlyph() {
  return (
    <svg className="lock-glyph" width="9" height="11" viewBox="0 0 9 11" aria-hidden="true">
      <rect x="0.5" y="4.5" width="8" height="6" rx="1" fill="none" stroke="currentColor" />
      <path d="M2.5 4.5V3a2 2 0 0 1 4 0v1.5" fill="none" stroke="currentColor" />
    </svg>
  );
}

function TxHash({ hash }: { hash: Hex }) {
  if (!EXPLORER) return <span title={hash}>{short(hash)}</span>;
  return (
    <a href={`${EXPLORER}/tx/${hash}`} target="_blank" rel="noreferrer" title={hash}>
      {short(hash)}
    </a>
  );
}

/** The Monad public network as anyone sees it: the demo's transactions, newest first. */
export default function ChainFeed() {
  const companies = useMemo(() => CUSTOMERS.map((c) => ({ name: c.name, address: addressOf(c) })), []);
  const name = useMemo(() => {
    const known = new Map(companies.map((c) => [c.address.toLowerCase(), c.name]));
    return (a: Address) => known.get(a.toLowerCase()) ?? contractName(a) ?? short(a);
  }, [companies]);

  const [txs, setTxs] = useState<Map<Hex, ChainTx>>(new Map());
  const [loaded, setLoaded] = useState(false);
  const [failed, setFailed] = useState(false);
  const [filter, setFilter] = useState<Filter>("companies");
  const scanned = useRef<bigint | null>(null);

  useEffect(() => {
    let stopped = false;
    let running = false;
    const poll = async () => {
      if (running) return;
      running = true;
      try {
        const latest = await l1.getBlockNumber({ cacheTime: 0 });
        const first = scanned.current == null ? latest - BACKFILL_BLOCKS : scanned.current + 1n;
        const from = latest - first > MAX_CATCH_UP && scanned.current != null ? latest - MAX_CATCH_UP : first;
        const found = await loadChainTxs(from > 0n ? from : 0n, latest, name);
        if (stopped) return;
        scanned.current = latest;
        if (found.length) {
          setTxs((prev) => {
            const next = new Map(prev);
            for (const tx of found) next.set(tx.hash, tx);
            return next;
          });
        }
        setLoaded(true);
        setFailed(false);
      } catch {
        if (!stopped) setFailed(true);
      } finally {
        running = false;
      }
    };
    void poll();
    const t = setInterval(() => void poll(), 2_000);
    return () => {
      stopped = true;
      clearInterval(t);
    };
  }, [name]);

  // A company is involved when it sent the transaction or its address is in the calldata
  // (a transfer to it, a faucet mint, a deposit for it).
  const involves = (tx: ChainTx) =>
    companies.some((c) => c.address.toLowerCase() === tx.from.toLowerCase() || tx.input.toLowerCase().includes(c.address.slice(2).toLowerCase()));
  const shown = [...txs.values()]
    .filter((tx) => filter === "all" || involves(tx))
    .sort((a, b) => (a.block === b.block ? 0 : a.block > b.block ? -1 : 1))
    .slice(0, SHOWN);

  return (
    <section className="chain-feed panel" aria-labelledby="chain-feed-title">
      <div className="chain-feed-head">
        <div>
          <h2 className="panel-title" id="chain-feed-title">
            Transactions on the Monad public network
          </h2>
          <p className="chain-feed-sub">What anyone reading the chain sees. Transfers inside a bank show up only as encrypted transactions.</p>
        </div>
        <div className="segmented" role="radiogroup" aria-label="Show">
          {(
            [
              ["companies", "The two companies"],
              ["all", "All demo traffic"],
            ] as const
          ).map(([id, label]) => (
            <button key={id} type="button" role="radio" aria-checked={filter === id} className={`segment${filter === id ? " on" : ""}`} onClick={() => setFilter(id)}>
              {label}
            </button>
          ))}
        </div>
      </div>

      {failed && !loaded && <p className="chain-feed-empty">Cannot reach the node.</p>}
      {!failed && !loaded && <p className="chain-feed-empty">Reading the last {BACKFILL_BLOCKS.toString()} blocks…</p>}
      {loaded && shown.length === 0 && (
        <p className="chain-feed-empty">
          No transactions in the last few minutes{filter === "companies" ? " from either company" : ""} - get test funds or send something.
        </p>
      )}
      {shown.length > 0 && (
        <div className="chain-feed-list" role="table" aria-label="Transactions">
          <div className="chain-row chain-row-head" role="row">
            <span role="columnheader">Time</span>
            <span role="columnheader">From</span>
            <span role="columnheader">What the chain shows</span>
            <span role="columnheader">Transaction</span>
          </div>
          {shown.map((tx) => (
            <div key={tx.hash} className={`chain-row${tx.encrypted ? " encrypted" : ""}`} role="row">
              <span className="chain-time" role="cell" title={`block ${tx.block}`}>
                {tx.time ? new Date(tx.time * 1000).toLocaleTimeString() : `#${tx.block}`}
              </span>
              <span className="chain-from" role="cell" title={tx.from}>
                {name(tx.from)}
              </span>
              <span className="chain-action" role="cell">
                <span className="chain-action-main">
                  {tx.encrypted && <LockGlyph />} {tx.action}
                </span>
                {tx.detail && <span className="chain-action-detail">{tx.detail}</span>}
              </span>
              <span className="chain-hash" role="cell">
                <TxHash hash={tx.hash} />
              </span>
            </div>
          ))}
        </div>
      )}
    </section>
  );
}
