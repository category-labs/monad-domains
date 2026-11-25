import React, { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { isAddress, parseEther, zeroAddress, type Address, type Hex } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { short, type Identity } from "../lib/account";
import { ALDER, BRIGHTLINE, addressOf, identityFor } from "./customers";
import { l1 } from "../lib/chain";
import { CHAIN_A, CHAIN_B, EXPLORER, RATE_DEN, RATE_NUM, deployment, quoteEurIn } from "../lib/deployment";
import { depositToA, fetchBalances, filePaymentOrder, fmt, fmtAmount, onboard, type Balances, type Step } from "../lib/flows";
import { fetchAccounts, fetchBankBook, type BankBook } from "../lib/customers";
import { PAYMENT_STEPS, trackPayment } from "../lib/watch";

type FlowKind = "onboard" | "deposit" | "payment";

/** How the demo payment should end: settled, refunded by an expired lock, or denied at KYC. */
type Scenario = "settle" | "expire" | "deny";

const SCENARIOS: { id: Scenario; label: string }[] = [
  { id: "settle", label: "Settles" },
  { id: "expire", label: "Lock expires" },
  { id: "deny", label: "KYC denied" },
];
/** Rail states: left rail A<->L1 (AL1 rightward, L1A leftward), right rail L1<->B. */
type Edge = "L1A" | "AL1" | "L1B" | "BL1" | null;

/** Whose eyes the page shows the ledgers through. */
type Viewer = "alder" | "brightline" | "bankA" | "bankB" | "auditor" | "public";

/** Whose account a row is: a company's (readable by that company) or someone else's. */
type Owner = "alder" | "brightline" | null;

const VIEWERS: { id: Viewer; label: string; sees: string }[] = [
  { id: "alder", label: ALDER.name, sees: `${ALDER.name} sees its own accounts at Bank A and Bank B.` },
  { id: "brightline", label: BRIGHTLINE.name, sees: `${BRIGHTLINE.name} sees its own accounts at Bank A and Bank B.` },
  { id: "bankA", label: "Bank A", sees: "All of domain A - Bank A runs it. Domain B stays dark to Bank A." },
  { id: "bankB", label: "Bank B", sees: "All of domain B - Bank B runs it. Domain A stays dark to Bank B." },
  { id: "auditor", label: "Auditor", sees: "All of both domains, read-only - both banks let their auditor read their ledgers." },
  { id: "public", label: "Public", sees: "Anyone: the Monad public network in full, the domains only as ciphertext - and whatever crosses the Monad public network. The step list shows what each step reveals." },
];

const VIEWER_KEY = "demo.split.viewer";

function loadViewer(): Viewer {
  try {
    const stored = localStorage.getItem(VIEWER_KEY);
    if (VIEWERS.some((v) => v.id === stored)) return stored as Viewer;
  } catch {
    // storage unavailable: start from the sender's view
  }
  return "alder";
}

/** The shared step texts speak to "you"; here the sender is Alder & Co. */
function asAlder(text: string): string {
  return text
    .replace(/\bYou are\b/g, `${ALDER.name} is`)
    .replace(/\byour\b/g, `${ALDER.name}'s`)
    .replace(/\bYour\b/g, `${ALDER.name}'s`)
    .replace(/\byou\b/g, ALDER.name)
    .replace(/\bYou\b/g, ALDER.name);
}

function LockGlyph() {
  return (
    <svg className="lock-glyph" width="9" height="11" viewBox="0 0 9 11" aria-hidden="true">
      <rect x="0.5" y="4.5" width="8" height="6" rx="1" fill="none" stroke="currentColor" />
      <path d="M2.5 4.5V3a2 2 0 0 1 4 0v1.5" fill="none" stroke="currentColor" />
    </svg>
  );
}

const STEP_COUNT: Record<FlowKind, number> = { onboard: 2, deposit: 3, payment: PAYMENT_STEPS };

/** Which rail segment carries the value/message for a running step. */
function edgeFor(flow: FlowKind, step: Step, expireLock: boolean): Edge {
  if (flow === "onboard") return step.seq === 1 ? "L1B" : null;
  if (flow === "deposit") return "L1A";
  const s = step.seq;
  if (s <= 2) return "AL1"; // order + inquiry head to the L1
  if (s <= 3) return "L1B"; // inquiry delivered to Bank B
  if (s <= 4) return "BL1"; // reply heads back to the L1
  if (s <= 5) return "L1A"; // reply delivered to Bank A
  if (s === 6) return "AL1"; // Bank A's lock request travels to the pool
  if (s === 7) return "L1A"; // the pool's quote travels back to Bank A
  if (s === 8) return "AL1"; // the € payment travels to the pool
  return expireLock ? "L1A" : "L1B"; // settlement: $ to the recipient, or € refund to the sender
}

function useFlash(value: bigint): boolean {
  const prev = useRef(value);
  const [flash, setFlash] = useState(false);
  useEffect(() => {
    if (prev.current !== value) {
      prev.current = value;
      setFlash(true);
      const t = setTimeout(() => setFlash(false), 1200);
      return () => clearTimeout(t);
    }
  }, [value]);
  return flash;
}

/** A row's label that copies an address when clicked (shown in the clear only). */
function CopyLabel({ label, address }: { label: string; address: Address }) {
  const [copied, setCopied] = useState(false);
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(address);
      setCopied(true);
      setTimeout(() => setCopied(false), 1200);
    } catch {
      // clipboard unavailable (e.g. insecure context): the full address is still in the tooltip
    }
  };
  return (
    <button type="button" className="balance-label copy-label" onClick={copy} title={`${address} - click to copy`}>
      {copied ? "Copied" : label}
    </button>
  );
}

function BalanceRow({
  label,
  value,
  unit,
  strong,
  double,
  middle,
  sealed,
  copy,
}: {
  label: string;
  value: bigint;
  unit: string;
  strong?: boolean;
  double?: boolean;
  middle?: string;
  sealed?: boolean;
  /** The account's address: the label copies it - only when the row is in the clear. */
  copy?: Address;
}) {
  const flash = useFlash(value);
  return (
    <div className={`balance-row${strong ? " strong" : ""}${flash && !sealed ? " flash" : ""}${double ? " double" : ""}${sealed ? " sealed" : ""}`}>
      {copy && !sealed ? <CopyLabel label={label} address={copy} /> : <span className="balance-label">{label}</span>}
      {middle && (
        <span className="ledger-col">
          {sealed ? (
            <span className="sealed-value" title="Hidden - not readable by this viewer">
              <LockGlyph />
            </span>
          ) : (
            middle
          )}
        </span>
      )}
      {sealed ? (
        // The outer span keeps the value's font, so the row is as tall as when it shows a number.
        <span className="balance-value" title="Hidden - not readable by this viewer">
          <span className="sealed-value">
            <LockGlyph /> hidden
          </span>
        </span>
      ) : (
        <span className="balance-value">
          {fmtAmount(value)}
          <span className="unit"> {unit}</span>
        </span>
      )}
    </div>
  );
}

function InfoRow({ label, children, double }: { label: string; children: React.ReactNode; double?: boolean }) {
  return (
    <div className={`balance-row${double ? " double" : ""}`}>
      <span className="balance-label">{label}</span>
      <span className="balance-value">{children}</span>
    </div>
  );
}

function LedgerGroup({ name, middle, right, children }: { name: string; middle?: string; right?: string; children: React.ReactNode }) {
  return (
    <div className={`ledger-group${middle ? " has-col" : ""}`}>
      <div className="ledger-sub">
        <span>{name}</span>
        {middle && <span className="ledger-col">{middle}</span>}
        {right && <span className="ledger-sub-right">{right}</span>}
      </div>
      {children}
    </div>
  );
}

/**
 * A bank's account list: at most three whole rows are visible, the rest scroll. The rows
 * differ in height (yours is set larger), so the window is measured from the first three.
 * The slider on the right is drawn here rather than left to the browser: macOS hides native
 * scrollbars until you scroll, and current Chrome no longer lets a page restyle them.
 */
const THUMB_LENGTH = 24;

function AccountList({ doubleAfter, children }: { doubleAfter?: boolean; children: React.ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  const [height, setHeight] = useState<number>();
  const [thumb, setThumb] = useState({ size: 0, offset: 0 });

  const updateThumb = useCallback(() => {
    const el = ref.current;
    if (!el || el.scrollHeight <= el.clientHeight) return;
    // One short thumb for every list, whatever its length: the lists look alike.
    const size = Math.min(THUMB_LENGTH, el.clientHeight);
    const offset = (el.scrollTop / (el.scrollHeight - el.clientHeight)) * (el.clientHeight - size);
    // Only a real change re-renders (this also runs after every render, via the layout effect).
    setThumb((t) => (Math.abs(t.size - size) < 0.5 && Math.abs(t.offset - offset) < 0.5 ? t : { size, offset }));
  }, []);

  // Set up once per row count: the observer reports every later size change itself (rows
  // wrapping, the box resizing). Re-running this after every render would re-create the
  // observer, whose first report sets state again - a render loop.
  const rowCount = React.Children.count(children);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const measure = () => {
      const rows = Array.from(el.children) as HTMLElement[];
      // Exact (fractional) row heights: offsetHeight rounds, and three rounded rows show a sliver of the fourth.
      const next = rows.length > 3 ? rows.slice(0, 3).reduce((sum, row) => sum + row.getBoundingClientRect().height, 0) : undefined;
      setHeight((h) => (h === next || (h != null && next != null && Math.abs(h - next) < 0.01) ? h : next));
      updateThumb();
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    for (const row of Array.from(el.children)) observer.observe(row);
    return () => observer.disconnect();
  }, [rowCount, updateThumb]);

  // Drag the thumb: the list scrolls by the thumb's movement, scaled to the content.
  const drag = (event: React.PointerEvent<HTMLDivElement>) => {
    const el = ref.current;
    if (!el) return;
    event.preventDefault();
    const target = event.currentTarget;
    target.setPointerCapture(event.pointerId);
    const startY = event.clientY;
    const startScroll = el.scrollTop;
    const ratio = (el.scrollHeight - el.clientHeight) / Math.max(1, el.clientHeight - thumb.size);
    const move = (e: PointerEvent) => (el.scrollTop = startScroll + (e.clientY - startY) * ratio);
    const up = () => {
      target.removeEventListener("pointermove", move);
      target.removeEventListener("pointerup", up);
    };
    target.addEventListener("pointermove", move);
    target.addEventListener("pointerup", up);
  };
  // Click the track: page up or down by the visible height.
  const page = (event: React.MouseEvent<HTMLDivElement>) => {
    const el = ref.current;
    if (!el || event.target !== event.currentTarget) return;
    const above = event.clientY < event.currentTarget.getBoundingClientRect().top + thumb.offset;
    el.scrollBy({ top: above ? -el.clientHeight : el.clientHeight, behavior: "smooth" });
  };

  const scrolls = height != null;
  return (
    <div className={`account-list${doubleAfter ? " double-after" : ""}${scrolls ? " scrolls" : ""}`}>
      <div ref={ref} className="account-list-rows" style={scrolls ? { maxHeight: height } : undefined} onScroll={updateThumb}>
        {children}
      </div>
      {scrolls && (
        <div className="list-track" onClick={page} aria-hidden>
          <div className="list-thumb" style={{ height: thumb.size, transform: `translateY(${thumb.offset}px)` }} onPointerDown={drag} />
        </div>
      )}
    </div>
  );
}

function Station({
  zone,
  tag,
  name,
  active,
  bodyRef,
  children,
}: {
  zone: "A" | "L1" | "B";
  tag: string;
  name: string;
  active: boolean;
  /** The content wrapper, measured to give both private domains the same height. */
  bodyRef?: React.Ref<HTMLDivElement>;
  children: React.ReactNode;
}) {
  return (
    <section className={`station station-${zone}${active ? " active" : ""}`}>
      <div className="station-body" ref={bodyRef}>
        <div className="station-tag">
          <span>{tag}</span>
          {zone !== "L1" && <LockGlyph />}
        </div>
        <h2 className="station-name">{name}</h2>
        <div className="station-balances">{children}</div>
      </div>
    </section>
  );
}

/**
 * The taller natural content height of the two private domains, so both can be drawn at
 * that height (centred beside the public domain). Their content wrappers are measured with
 * the shared min-height lifted, so a box never keeps a height it no longer needs.
 */
function useEqualHeight(): [React.RefObject<HTMLDivElement>, React.RefObject<HTMLDivElement>, number | undefined] {
  const a = useRef<HTMLDivElement>(null);
  const b = useRef<HTMLDivElement>(null);
  const [height, setHeight] = useState<number>();
  useEffect(() => {
    const natural = (el: HTMLDivElement) => {
      const previous = el.style.minHeight;
      el.style.minHeight = "0px";
      const h = el.offsetHeight;
      el.style.minHeight = previous;
      return h;
    };
    const measure = () => {
      if (!a.current || !b.current) return;
      setHeight(Math.max(natural(a.current), natural(b.current)));
    };
    measure();
    const observer = new ResizeObserver(measure);
    for (const el of [a.current, b.current]) {
      for (const child of Array.from(el?.children ?? [])) observer.observe(child);
    }
    window.addEventListener("resize", measure);
    return () => {
      observer.disconnect();
      window.removeEventListener("resize", measure);
    };
  }, []);
  return [a, b, height];
}

function Rail({ edge, atomic }: { edge: Edge; atomic: boolean }) {
  const live = edge != null;
  const reverse = edge === "L1A" || edge === "BL1";
  return (
    <div className="rail" aria-hidden>
      <div className={`rail-seg${live ? " live" : ""}${reverse ? " reverse" : ""}${atomic && live ? " atomic" : ""}`}>{live && <span className="rail-coin" />}</div>
    </div>
  );
}

function TxLink({ hash, zone }: { hash?: Hex; zone: "A" | "L1" | "B" }) {
  if (!hash) return null;
  if (zone === "L1" && EXPLORER) {
    return (
      <a href={`${EXPLORER}/tx/${hash}`} target="_blank" rel="noreferrer" title={hash}>
        {short(hash)}
      </a>
    );
  }
  return <span title={hash}>{short(hash)}</span>;
}

/** The main page's full view (account, three domains, actions, steps), shown below the wallets. */
export default function ClassicView() {
  // Alder & Co. sends; Brightline Ltd. is the recipient unless another address is entered.
  const [identity] = useState<Identity>(() => identityFor(ALDER));
  const brightline = useMemo(() => addressOf(BRIGHTLINE), []);
  const [balances, setBalances] = useState<Balances | null>(null);
  const [block, setBlock] = useState<bigint | null>(null);
  const [depositAmount, setDepositAmount] = useState("50");
  const [amount, setAmount] = useState("60");
  const [recipientInput, setRecipientInput] = useState("");
  /** While the recipient field has focus it shows the full address; otherwise 0x1234…abcd. */
  const [editingRecipient, setEditingRecipient] = useState(false);
  const [scenario, setScenarioState] = useState<Scenario>("settle");
  const expireLock = scenario === "expire";
  /** Denial pays a fresh address Bank B never registered, so it denies the KYC inquiry. */
  const denyKyc = scenario === "deny";
  const setScenario = (next: Scenario) => {
    setScenarioState(next);
    if (next === "deny") setRecipientInput(privateKeyToAccount(generatePrivateKey()).address);
    else if (denyKyc) setRecipientInput("");
  };
  const [viewer, setViewerState] = useState<Viewer>(loadViewer);
  const [domainBodyA, domainBodyB, domainHeight] = useEqualHeight();
  const setViewer = (next: Viewer) => {
    setViewerState(next);
    try {
      localStorage.setItem(VIEWER_KEY, next);
    } catch {
      // not remembered across visits; the switch still works
    }
  };
  const [steps, setSteps] = useState<Step[]>([]);
  const [flow, setFlow] = useState<FlowKind | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [offline, setOffline] = useState(false);

  const recipient: Address | null = useMemo(() => {
    const value = recipientInput.trim();
    if (!value) return brightline;
    return isAddress(value) ? (value as Address) : null;
  }, [recipientInput, brightline]);

  // A refresh is ~15 RPC reads; throttle so bursts of step reports don't multiply.
  const refreshing = useRef(false);
  const lastRefresh = useRef(0);
  const refresh = useCallback(
    async (force = false) => {
      if (refreshing.current || (!force && Date.now() - lastRefresh.current < 800)) return;
      refreshing.current = true;
      try {
        const [b, n] = await Promise.all([
          fetchBalances(identity.l1.address, identity.domain.address, recipient ?? identity.domain.address),
          l1.getBlockNumber({ cacheTime: 0 }),
        ]);
        setBalances(b);
        setBlock(n);
        setOffline(false);
      } catch {
        setOffline(true);
      } finally {
        lastRefresh.current = Date.now();
        refreshing.current = false;
      }
    },
    [identity, recipient],
  );

  // Every account on both banks' books: the addresses from the operator's account index, the
  // values read from the domains, a little less often than the balances; the ledger tokens
  // come from the balance reads.
  const [books, setBooks] = useState<{ A?: BankBook; B?: BankBook }>({});
  const ledgers = useRef<{ A: Address; B: Address }>({ A: zeroAddress, B: zeroAddress });
  useEffect(() => {
    if (balances) ledgers.current = { A: balances.ledgerA, B: balances.ledgerB };
  }, [balances]);
  useEffect(() => {
    let loading = false;
    const load = async () => {
      if (loading) return;
      loading = true;
      try {
        const accounts = await fetchAccounts();
        const [A, B] = await Promise.all([
          fetchBankBook("A", ledgers.current.A, accounts.A),
          fetchBankBook("B", ledgers.current.B, accounts.B),
        ]);
        setBooks({ A, B });
      } catch {
        // keep the last books; the next pass retries
      } finally {
        loading = false;
      }
    };
    void load();
    const t = setInterval(() => void load(), 5_000);
    return () => clearInterval(t);
  }, []);

  useEffect(() => {
    void refresh(true);
    const t = setInterval(() => void refresh(), 2_500);
    return () => clearInterval(t);
  }, [refresh]);

  const report = useCallback(
    (step: Step) => {
      setSteps((prev) => {
        const next = prev.filter((s) => s.seq !== step.seq);
        next.push(step);
        next.sort((a, b) => a.seq - b.seq);
        return next;
      });
      void refresh();
    },
    [refresh],
  );

  const amountOutWei = useMemo(() => {
    try {
      const v = parseEther(amount);
      return v > 0n ? v : null;
    } catch {
      return null;
    }
  }, [amount]);
  const costWei = amountOutWei != null ? quoteEurIn(amountOutWei) : null;
  const depositWei = useMemo(() => {
    try {
      const v = parseEther(depositAmount);
      return v > 0n ? v : null;
    } catch {
      return null;
    }
  }, [depositAmount]);

  const run = useCallback(
    async (kind: FlowKind) => {
      if (kind === "deposit" && depositWei == null) {
        setError(`"${depositAmount}" is not a valid amount`);
        return;
      }
      if (kind === "payment" && (amountOutWei == null || costWei == null)) {
        setError(`"${amount}" is not a valid amount`);
        return;
      }
      if (kind === "payment" && recipient == null) {
        setError("the recipient must be an EVM address");
        return;
      }
      setBusy(true);
      setError(null);
      setSteps([]);
      setFlow(kind);
      try {
        if (kind === "onboard") {
          await onboard(identity, report);
        } else if (kind === "deposit") {
          await depositToA(identity, depositWei!, report);
        } else {
          const order = await filePaymentOrder(identity, recipient!, amountOutWei!, expireLock, report);
          await trackPayment(order, report);
        }
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err));
      } finally {
        setBusy(false);
        void refresh(true);
      }
    },
    [amount, amountOutWei, costWei, depositAmount, depositWei, expireLock, identity, recipient, report, refresh],
  );

  const running = steps.find((s) => s.status === "running");
  // The transaction shown in the three-domains view: the step running now, else the last one done.
  const currentStep = running ?? steps[steps.length - 1];
  const edge: Edge = busy && running && flow ? edgeFor(flow, running, expireLock) : null;
  const atomicLive = !!(running?.atomic && busy);
  const activeZone = busy ? running?.zone : undefined;

  const rateLabel = `1 € = ${fmt((10n ** 18n * RATE_NUM) / RATE_DEN)} $`;
  const availableUsd = balances != null ? balances.poolUsd - balances.poolUsdLocked : 0n;
  const totalEurL1 = (balances?.eurL1 ?? 0n) + (balances?.lockedEurA ?? 0n) + (balances?.poolEur ?? 0n);
  // "reserved by locks" is part of the pool's $, so it is not added again.
  const totalUsdL1 = (balances?.poolUsd ?? 0n) + (balances?.lockedUsdB ?? 0n);
  const hasGas = (balances?.mon ?? 0n) > 10n ** 16n;
  const ready = !busy && !offline && balances != null;
  const canDeposit = ready && depositWei != null && balances!.eurL1 >= depositWei && hasGas;
  const canPay =
    ready &&
    costWei != null &&
    amountOutWei != null &&
    recipient != null &&
    balances!.userEurOnA >= costWei &&
    balances!.userLimitA >= costWei &&
    availableUsd >= amountOutWei &&
    hasGas;
  const needsOnboarding = ready && (!hasGas || balances!.eurL1 + balances!.userEurOnA === 0n || balances!.userTierA === 0);
  // The one action the page highlights: onboard, then fund Bank A, then pay.
  const nextAction: FlowKind =
    !balances || needsOnboarding ? "onboard" : costWei != null && balances.userEurOnA < costWei ? "deposit" : "payment";
  const btn = (kind: FlowKind) => `btn${nextAction === kind ? " primary" : ""}`;
  const tierLabel = (tier: number | undefined) => (tier ? `Tier ${tier}` : "-");

  // What the selected viewer can read inside a domain: the bank running it and the auditor
  // read all of it, each company reads its own accounts (never the other's), and the public
  // reads none of it.
  const self = identity.domain.address;
  const same = (x: Address | null | undefined, y: Address) => x != null && x.toLowerCase() === y.toLowerCase();
  const ownerOf = (address: Address | null | undefined): Owner => (same(address, self) ? "alder" : same(address, brightline) ? "brightline" : null);
  const nameOf = (address: Address | null | undefined) => (same(address, self) ? ALDER.name : same(address, brightline) ? BRIGHTLINE.name : null);
  const reads = (zone: "A" | "B", owner: Owner) =>
    viewer === "auditor" || viewer === (zone === "A" ? "bankA" : "bankB") || (owner != null && viewer === owner);
  const publicMode = viewer === "public";

  // The other accounts on a bank's books, after the one shown on top; an account the viewer
  // may not read keeps its row (so the list is the same for every viewer) but not its address.
  const others = <T extends { address: Address }>(list: T[] | undefined, top: Address | null) =>
    (list ?? []).filter((x) => top == null || x.address.toLowerCase() !== top.toLowerCase());
  // A company's row carries its name; the name is masked like any address where the viewer
  // may not read it - the label alone would tell a viewer who banks there.
  const accountLabel = (address: Address, readable: boolean) => (readable ? (nameOf(address) ?? short(address)) : "0x••••…••••");
  const youLabel = (zone: "A" | "B") => (reads(zone, "alder") ? ALDER.name : "0x••••…••••");
  const recipientReadable = reads("B", ownerOf(recipient));
  const recipientLabel = recipientReadable ? (nameOf(recipient) ?? "Selected recipient address") : "0x••••…••••";
  // Paying Alder's own Bank B account shows it once, under Alder's name.
  const recipientIsYou = same(recipient, self);
  const selfAtB = {
    customer: books.B?.customers.find((c) => c.address.toLowerCase() === self.toLowerCase()),
  };

  return (
    <>
      <div className="page classic">
        <div className="ledger-view panel" role="region" aria-labelledby="ledger-view-title">
          <h2 className="panel-title ledger-view-title" id="ledger-view-title">
            Three domains - who sees what
          </h2>
          <section className="viewer" aria-label="Viewing as">
            <span className="field-label">Viewing as</span>
            <div className="segmented" role="radiogroup" aria-label="Viewing as">
              {VIEWERS.map((v) => (
                <button
                  key={v.id}
                  type="button"
                  role="radio"
                  aria-checked={viewer === v.id}
                  className={`segment${viewer === v.id ? " on" : ""}`}
                  onClick={() => setViewer(v.id)}
                >
                  {v.label}
                </button>
              ))}
            </div>
            {VIEWERS.find((v) => v.id === viewer)!.sees && <p className="viewer-sees">{VIEWERS.find((v) => v.id === viewer)!.sees}</p>}
          </section>

          <main className="board" style={domainHeight ? ({ "--domain-body-height": `${domainHeight}px` } as React.CSSProperties) : undefined}>
            <Station zone="A" tag={`Private settlement domain A · ${CHAIN_A}`} name="Bank A · € ledger" active={activeZone === "A"} bodyRef={domainBodyA}>
              <LedgerGroup name="€ Ledger (wrapped)">
                <AccountList>
                  <BalanceRow label={youLabel("A")} value={balances?.userEurOnA ?? 0n} unit="€" strong sealed={!reads("A", "alder")} />
                  {others(books.A?.holders, self).map((h) => (
                    <BalanceRow key={h.address} label={accountLabel(h.address, reads("A", ownerOf(h.address)))} copy={h.address} value={h.balance} unit="€" sealed={!reads("A", ownerOf(h.address))} />
                  ))}
                </AccountList>
                <BalanceRow label="Bank A custody" value={balances?.custodyEurA ?? 0n} unit="€" double sealed={!reads("A", null)} />
                <BalanceRow label="total supply" value={balances?.supplyEurA ?? 0n} unit="€" sealed={!reads("A", null)} />
              </LedgerGroup>
              <LedgerGroup name="KYC'd customer" middle="level" right="daily limit">
                <AccountList>
                  <BalanceRow label={youLabel("A")} middle={tierLabel(balances?.userTierA)} value={balances?.userLimitA ?? 0n} unit="€" sealed={!reads("A", "alder")} />
                  {others(books.A?.customers, self).map((c) => (
                    <BalanceRow key={c.address} label={accountLabel(c.address, reads("A", ownerOf(c.address)))} copy={c.address} middle={tierLabel(c.tier)} value={c.limit} unit="€" sealed={!reads("A", ownerOf(c.address))} />
                  ))}
                </AccountList>
              </LedgerGroup>
            </Station>
            <Rail edge={edge === "L1B" || edge === "BL1" ? null : edge} atomic={atomicLive} />
            <Station zone="L1" tag="Public domain · Monad testnet" name="Ledgers + liquidity pool" active={activeZone === "L1"}>
              <LedgerGroup name="€ Ledger">
                <BalanceRow label={ALDER.name} value={balances?.eurL1 ?? 0n} unit="€" />
                <BalanceRow label="Liquidity pool" value={balances?.poolEur ?? 0n} unit="€" />
                <BalanceRow label="Domain A escrow" value={balances?.lockedEurA ?? 0n} unit="€" double />
                <BalanceRow label="total" value={totalEurL1} unit="€" />
              </LedgerGroup>
              <LedgerGroup name="$ Ledger">
                <BalanceRow label="Liquidity pool" value={balances?.poolUsd ?? 0n} unit="$" />
                <BalanceRow label="reserved by locks" value={balances?.poolUsdLocked ?? 0n} unit="$" />
                <BalanceRow label="Domain B escrow" value={balances?.lockedUsdB ?? 0n} unit="$" double />
                <BalanceRow label="total" value={totalUsdL1} unit="$" />
              </LedgerGroup>
              <LedgerGroup name="Pool">
                <InfoRow label="rate">{rateLabel}</InfoRow>
                <InfoRow label="hub">
                  <code title={deployment.hub}>{short(deployment.hub)}</code>
                </InfoRow>
              </LedgerGroup>
            </Station>
            <Rail edge={edge === "L1B" || edge === "BL1" ? edge : null} atomic={atomicLive} />
            <Station zone="B" tag={`Private settlement domain B · ${CHAIN_B}`} name="Bank B · $ ledger" active={activeZone === "B"} bodyRef={domainBodyB}>
              <LedgerGroup name="$ Ledger (wrapped)">
                <AccountList doubleAfter>
                  {recipientIsYou ? (
                    <BalanceRow label={youLabel("B")} value={balances?.recipientUsdOnB ?? 0n} unit="$" strong sealed={!reads("B", "alder")} />
                  ) : (
                    <>
                      <BalanceRow label={youLabel("B")} value={balances?.userUsdOnB ?? 0n} unit="$" strong sealed={!reads("B", "alder")} />
                      <BalanceRow label={recipientLabel} value={balances?.recipientUsdOnB ?? 0n} unit="$" sealed={!recipientReadable} copy={recipient ?? undefined} />
                    </>
                  )}
                  {others(others(books.B?.holders, recipient), self).map((h) => (
                    <BalanceRow key={h.address} label={accountLabel(h.address, reads("B", ownerOf(h.address)))} copy={h.address} value={h.balance} unit="$" sealed={!reads("B", ownerOf(h.address))} />
                  ))}
                </AccountList>
                <BalanceRow label="total supply" value={balances?.supplyUsdB ?? 0n} unit="$" sealed={!reads("B", null)} />
              </LedgerGroup>
              <LedgerGroup name="KYC'd customer" middle="level" right="daily limit">
                <AccountList>
                  {recipientIsYou ? (
                    <BalanceRow label={youLabel("B")} middle={tierLabel(balances?.recipientTierB)} value={balances?.recipientLimitB ?? 0n} unit="$" sealed={!reads("B", "alder")} />
                  ) : (
                    <>
                      <BalanceRow label={youLabel("B")} middle={tierLabel(selfAtB.customer?.tier)} value={selfAtB.customer?.limit ?? 0n} unit="$" sealed={!reads("B", "alder")} />
                      <BalanceRow label={recipientLabel} middle={tierLabel(balances?.recipientTierB)} value={balances?.recipientLimitB ?? 0n} unit="$" sealed={!recipientReadable} copy={recipient ?? undefined} />
                    </>
                  )}
                  {others(others(books.B?.customers, recipient), self).map((c) => (
                    <BalanceRow key={c.address} label={accountLabel(c.address, reads("B", ownerOf(c.address)))} copy={c.address} middle={tierLabel(c.tier)} value={c.limit} unit="$" sealed={!reads("B", ownerOf(c.address))} />
                  ))}
                </AccountList>
              </LedgerGroup>
            </Station>
          </main>
          <div className={`current-tx${running ? " running" : ""}`} aria-live="polite">
            <div className="current-tx-label">Current transaction</div>
            <div className="current-tx-body">
              {currentStep ? (
                <>
                  {flow && (
                    <span className="current-tx-count">
                      ({currentStep.seq + 1}/{STEP_COUNT[flow]})
                    </span>
                  )}
                  <span className={`entry-zone zone-${currentStep.zone}`}>{currentStep.zone === "L1" ? "L1" : `PSD ${currentStep.zone}`}</span>
                  <span className="current-tx-title" title={asAlder(currentStep.title)}>
                    {asAlder(currentStep.title)}
                  </span>
                  <span className="current-tx-link">
                    {publicMode ? <TxLink hash={currentStep.publicTxHash} zone="L1" /> : <TxLink hash={currentStep.txHash} zone={currentStep.zone} />}
                  </span>
                  <span className="entry-status">{currentStep.status === "done" ? "✓" : <span className="spinner" />}</span>
                </>
              ) : (
                <span className="current-tx-idle">None running</span>
              )}
            </div>
          </div>
        </div>

        {error && <div className="error">{error}</div>}

        <section className="ledger">
          <div className="ledger-head">
            <div className="ledger-heading">
              <h2 className="panel-title">What is happening</h2>
              <span className="ledger-flow">
                {flow === null
                  ? "Nothing running yet - choose an action above, and every step appears here as it happens."
                  : flow === "onboard"
                  ? "Onboarding - test funds from the operator's faucet, registry entries at both banks"
                  : flow === "deposit"
                    ? `Deposit - €: Monad public network → ${ALDER.name}'s account at Bank A (delivered by the protocol)`
                    : `Bank payment - ${ALDER.name} pays $${amount} to ${recipient ? (nameOf(recipient) ?? short(recipient)) : "…"} · KYC round trip, ${denyKyc ? "denial, refund" : `liquidity lock on the Monad public network, ${expireLock ? "timeout refund" : "atomic settlement"}`}`}
              </span>
            </div>
            {publicMode && <span className="public-tag">public view</span>}
            {flow && (
              <span className="ledger-count">
                {steps.filter((s) => s.status === "done").length}/{STEP_COUNT[flow]} steps
              </span>
            )}
          </div>
          {steps.map((s) => (
            <div key={s.seq} className={`entry${s.atomic ? " atomic" : ""}${publicMode && s.publicView === null ? " dark" : ""} ${s.status}`}>
              <span className="entry-seq">{String(s.seq + 1).padStart(2, "0")}</span>
              <span className={`entry-zone zone-${s.zone}`}>{s.zone === "L1" ? "L1" : `PSD ${s.zone}`}</span>
              <span className="entry-actor">{asAlder(s.actor)}</span>
              <span className="entry-body">
                <span className="entry-title">
                  {asAlder(s.title)}
                  {s.atomic && <span className="atomic-badge">1 L1 TX</span>}
                  {publicMode && s.publicLeak && <span className="leak-badge">IN CLEAR</span>}
                </span>
                <span className="entry-detail">
                  {!publicMode || s.publicView === undefined
                    ? asAlder(s.detail)
                    : s.publicView === null
                      ? `Nothing public - this ran inside domain ${s.zone}`
                      : `Public: ${s.publicView}`}
                </span>
              </span>
              <span className="entry-tx">
                {publicMode ? <TxLink hash={s.publicTxHash} zone="L1" /> : <TxLink hash={s.txHash} zone={s.zone} />}
              </span>
              <span className="entry-status">{s.status === "done" ? "✓" : <span className="spinner" />}</span>
            </div>
          ))}
        </section>


        <footer className="colophon">
          <details>
            <summary>How it works</summary>
            <p>
              {ALDER.name}'s account signs every transaction of its own: deposits on the Monad public network and domain transactions carried to the hub inside a
              transaction, encrypted to the domain's viewing key. The KYC inquiry and reply are real cross-domain messages routed by the hub;
              so are Bank A's lock request to the pool on the Monad public network and the pool's quote, on which Bank A pays - no bank key takes part in a payment.
              The operators' service (open source, <code>npm run operator</code>) finalizes, attests and proves the messages and runs the faucet. Nothing is relayed by this page.
            </p>
          </details>
          <details>
            <summary>Cast of contracts &amp; accounts</summary>
            <div className="addr-grid">
              <span>hub (Monad public network)</span>
              <code>{deployment.hub}</code>
              <span>spoke A / B</span>
              <code>
                {short(deployment.domains.A.spoke)} · {short(deployment.domains.B.spoke)}
              </code>
              <span>Monad public network bridge A / B</span>
              <code>
                {short(deployment.domains.A.l1Bridge)} · {short(deployment.domains.B.l1Bridge)}
              </code>
              <span>domain bridge A / B</span>
              <code>
                {short(deployment.domains.A.domainBridge)} · {short(deployment.domains.B.domainBridge)}
              </code>
              <span>€ / $ ledgers (Monad public network)</span>
              <code>
                {short(deployment.tokens.eur)} · {short(deployment.tokens.usd)}
              </code>
              <span>liquidity pool</span>
              <code>{deployment.pool}</code>
              <span>Bank A (domain A) / Bank B (domain B)</span>
              <code>
                {short(deployment.domains.A.bank)} · {short(deployment.domains.B.bank)}
              </code>
              <span>bank operator / relayer</span>
              <code>{deployment.bankOperator}</code>
              <span>{ALDER.name} / {BRIGHTLINE.name}</span>
              <code>
                {short(identity.l1.address)} · {short(brightline)}
              </code>
            </div>
          </details>

        </footer>
      </div>
    </>
  );
}
