import React, { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { isAddress, parseEther, zeroAddress, type Address, type Hex } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import {
  browserIdentity,
  connectInjectedWallet,
  exportSessionKey,
  hasInjectedWallet,
  resetSessionKey,
  short,
  type Identity,
} from "./lib/account";
import { l1 } from "./lib/chain";
import { CHAIN_A, CHAIN_B, EXPLORER, RATE_DEN, RATE_NUM, deployment, quoteEurIn } from "./lib/deployment";
import { depositToA, fetchBalances, filePaymentOrder, fmt, fmtAmount, onboard, type Balances, type Step } from "./lib/flows";
import { fetchAccounts, fetchBankBook, type BankBook } from "./lib/customers";
import { PAYMENT_STEPS, trackPayment } from "./lib/watch";
import { MonadLogo } from "./MonadLogo";

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
type Viewer = "you" | "bankA" | "bankB" | "auditor" | "public";

const VIEWERS: { id: Viewer; label: string; sees: string }[] = [
  { id: "you", label: "You", sees: "You see your account information with Bank A and Bank B." },
  { id: "bankA", label: "Bank A", sees: "All of domain A - Bank A runs it. Domain B stays dark to Bank A." },
  { id: "bankB", label: "Bank B", sees: "All of domain B - Bank B runs it. Domain A stays dark to Bank B." },
  { id: "auditor", label: "Auditor", sees: "All of both domains, read-only - both banks let their auditor read their ledgers." },
  { id: "public", label: "Public", sees: "Anyone: the Monad public network in full, the domains only as ciphertext - and whatever crosses the Monad public network. The step list shows what each step reveals." },
];

const VIEWER_KEY = "demo.viewer";

function loadViewer(): Viewer {
  try {
    const stored = localStorage.getItem(VIEWER_KEY);
    if (VIEWERS.some((v) => v.id === stored)) return stored as Viewer;
  } catch {
    // storage unavailable: start from the visitor's own view
  }
  return "you";
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
  return expireLock ? "L1A" : "L1B"; // settlement: $ to the recipient, or € refund to you
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

/** An address in a chip, with a button that copies it. */
function AddressChip({ address }: { address: Address }) {
  const [copied, setCopied] = useState(false);
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(address);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // clipboard unavailable (e.g. insecure context): the address is still selectable
    }
  };
  return (
    <span className="address-chip">
      <code title={address}>{address}</code>
      <button type="button" className="chip-copy" onClick={copy} aria-label="Copy address">
        {copied ? "Copied" : "Copy"}
      </button>
    </span>
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

export default function App() {
  const [identity, setIdentity] = useState<Identity>(() => browserIdentity());
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
  const [showIntro, setShowIntro] = useState(false);
  const [showKey, setShowKey] = useState(false);
  const [steps, setSteps] = useState<Step[]>([]);
  const [flow, setFlow] = useState<FlowKind | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [offline, setOffline] = useState(false);

  const recipient: Address | null = useMemo(() => {
    const value = recipientInput.trim();
    if (!value) return identity.domain.address;
    return isAddress(value) ? (value as Address) : null;
  }, [recipientInput, identity.domain.address]);

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

  const connect = useCallback(async () => {
    setError(null);
    try {
      setIdentity(await connectInjectedWallet());
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }, []);

  const useBrowserAccount = useCallback(() => {
    setError(null);
    setIdentity(browserIdentity());
  }, []);

  const startOver = useCallback(() => {
    if (!window.confirm("Generate a new browser account? The current key and its balances stay on-chain but this page forgets it.")) return;
    resetSessionKey();
    setIdentity(browserIdentity());
    setSteps([]);
    setFlow(null);
  }, []);

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
  // read all of it, you read your own accounts (never your recipient's), and the public reads
  // none of it.
  const reads = (zone: "A" | "B", own: boolean) =>
    viewer === "auditor" || viewer === (zone === "A" ? "bankA" : "bankB") || (viewer === "you" && own);
  const publicMode = viewer === "public";

  // The other accounts on a bank's books, after the one shown on top; an account the viewer
  // may not read keeps its row (so the list is the same for every viewer) but not its address.
  const others = <T extends { address: Address }>(list: T[] | undefined, top: Address | null) =>
    (list ?? []).filter((x) => top == null || x.address.toLowerCase() !== top.toLowerCase());
  const accountLabel = (address: Address, readable: boolean) => (readable ? short(address) : "0x••••…••••");
  // Your own row at a bank: "Your account" where the viewer may read it, else masked like any address -
  // the label alone would tell a viewer that you bank there.
  const youLabel = (zone: "A" | "B") => (reads(zone, true) ? "Your account" : "0x••••…••••");
  // The recipient you picked (when it is not you) - masked like any other address the viewer may not read.
  const recipientLabel = reads("B", false) ? "Selected recipient address" : "0x••••…••••";
  const self = identity.domain.address;
  // At Bank B your own account is yours to read; the recipient's is not - unless you pay
  // yourself, in which case it is the same account, shown once as "Your account".
  const recipientIsYou = recipient != null && recipient.toLowerCase() === self.toLowerCase();
  const selfAtB = {
    customer: books.B?.customers.find((c) => c.address.toLowerCase() === self.toLowerCase()),
  };

  return (
    <>
      <header className="topbar">
        <div className="brand">
          <MonadLogo className="brand-logo" />
          <span className="brand-product">Private Settlement Domains</span>
        </div>
        <div className="badges">
          <div className={`node-badge${offline ? " offline" : ""}`}>
            <span className="pulse" />
            <span>
              {offline ? (
                "node unreachable"
              ) : (
                <>
                  monad testnet · block <strong>{block?.toString() ?? "…"}</strong>
                </>
              )}
            </span>
          </div>
        </div>
      </header>
      <div className="page">
        <header className="masthead">
          <div>
            <h1 className="title">
              Two private domains, two currencies, <em>common liquidity.</em>
              <button
                type="button"
                className={`intro-toggle${showIntro ? " open" : ""}`}
                onClick={() => setShowIntro((v) => !v)}
                aria-expanded={showIntro}
                aria-controls="intro"
                aria-label={showIntro ? "Hide description" : "Show description"}
              />
            </h1>
            <div className="lede" id="intro" hidden={!showIntro}>
              <p>
                This demo shows how a bank payment can cross between two private settlement domains, in two currencies, settled
                atomically against a liquidity pool on the Monad public network.
              </p>
              <p>
                You bank in <strong>€ with Bank A on private settlement domain A</strong> and in{" "}
                <strong>$ with Bank B on private settlement domain B</strong>, with a different KYC level at each bank. You ask Bank A to
                send $ to an account at Bank B (yours or someone else's). Bank A first <strong>KYC-inquires with Bank B</strong> about the
                recipient address (real cross-domain messages, both ways, relayed by the operators), then takes a{" "}
                <strong>liquidity lock</strong> at the pool on the Monad public network ({rateLabel}), charges you the quoted € and the
                pool's settlement delivers the locked $ to the recipient - or refunds the € if the lock timed out first. Every transaction
                here is signed by your own account; the relaying is done by the operators' service, not by this page.
              </p>
            </div>
          </div>
        </header>

        <section className="account panel" aria-labelledby="account-title">
          <h2 className="panel-title account-title" id="account-title">
            You are a customer of Bank A and B
          </h2>
          <div className="account-main">
            <div className="account-row">
              <span className="field-label">{identity.l1.kind === "injected" ? "Connected wallet (L1):" : "Your address:"}</span>
              <AddressChip address={identity.l1.address} />
              {identity.l1.kind === "injected" && (
                <>
                  <span className="field-label">Domain account (session key):</span>
                  <AddressChip address={identity.domain.address} />
                </>
              )}
            </div>
            <p className="funds">
              <span className="field-label">Funds:</span>
              {[
                { value: balances?.mon, label: "MON for gas" },
                { value: balances?.eurL1, label: "€ on Monad" },
                { value: balances?.userEurOnA, label: "€ at Bank A" },
                { value: balances?.userUsdOnB, label: "$ at Bank B" },
              ].map((f) => (
                <span key={f.label}>
                  <strong>{balances ? fmt(f.value ?? 0n) : "–"}</strong> {f.label}
                </span>
              ))}
            </p>
          </div>
          <div className="account-actions">
            <button className={btn("onboard")} onClick={() => run("onboard")} disabled={busy || offline || !balances}>
              Get test funds
            </button>
            {identity.l1.kind === "browser" ? (
              hasInjectedWallet() && (
                <button className="btn" onClick={connect} disabled={busy}>
                  Connect wallet
                </button>
              )
            ) : (
              <button className="btn" onClick={useBrowserAccount} disabled={busy}>
                Use browser account
              </button>
            )}
            <button className="btn ghost reset" onClick={startOver} disabled={busy} title="Generate a new browser key">
              ↺ New account
            </button>
            <button className="btn ghost" onClick={() => setShowKey((v) => !v)} disabled={busy}>
              {showKey ? "Hide key" : "Export key"}
            </button>
          </div>
          {showKey && (
            <p className="account-key">
              Browser key (test funds only, never reuse elsewhere): <code>{exportSessionKey() ?? "n/a"}</code>
            </p>
          )}
        </section>

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
                  <BalanceRow label={youLabel("A")} value={balances?.userEurOnA ?? 0n} unit="€" strong sealed={!reads("A", true)} />
                  {others(books.A?.holders, self).map((h) => (
                    <BalanceRow key={h.address} label={accountLabel(h.address, reads("A", false))} copy={h.address} value={h.balance} unit="€" sealed={!reads("A", false)} />
                  ))}
                </AccountList>
                <BalanceRow label="Bank A custody" value={balances?.custodyEurA ?? 0n} unit="€" double sealed={!reads("A", false)} />
                <BalanceRow label="total supply" value={balances?.supplyEurA ?? 0n} unit="€" sealed={!reads("A", false)} />
              </LedgerGroup>
              <LedgerGroup name="KYC'd customer" middle="level" right="daily limit">
                <AccountList>
                  <BalanceRow label={youLabel("A")} middle={tierLabel(balances?.userTierA)} value={balances?.userLimitA ?? 0n} unit="€" sealed={!reads("A", true)} />
                  {others(books.A?.customers, self).map((c) => (
                    <BalanceRow key={c.address} label={accountLabel(c.address, reads("A", false))} copy={c.address} middle={tierLabel(c.tier)} value={c.limit} unit="€" sealed={!reads("A", false)} />
                  ))}
                </AccountList>
              </LedgerGroup>
            </Station>
            <Rail edge={edge === "L1B" || edge === "BL1" ? null : edge} atomic={atomicLive} />
            <Station zone="L1" tag="Public domain · Monad testnet" name="Ledgers + liquidity pool" active={activeZone === "L1"}>
              <LedgerGroup name="€ Ledger">
                <BalanceRow label="Your account" value={balances?.eurL1 ?? 0n} unit="€" />
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
                    <BalanceRow label={youLabel("B")} value={balances?.recipientUsdOnB ?? 0n} unit="$" strong sealed={!reads("B", true)} />
                  ) : (
                    <>
                      <BalanceRow label={youLabel("B")} value={balances?.userUsdOnB ?? 0n} unit="$" strong sealed={!reads("B", true)} />
                      <BalanceRow label={recipientLabel} value={balances?.recipientUsdOnB ?? 0n} unit="$" sealed={!reads("B", false)} copy={recipient ?? undefined} />
                    </>
                  )}
                  {others(others(books.B?.holders, recipient), self).map((h) => (
                    <BalanceRow key={h.address} label={accountLabel(h.address, reads("B", false))} copy={h.address} value={h.balance} unit="$" sealed={!reads("B", false)} />
                  ))}
                </AccountList>
                <BalanceRow label="total supply" value={balances?.supplyUsdB ?? 0n} unit="$" sealed={!reads("B", false)} />
              </LedgerGroup>
              <LedgerGroup name="KYC'd customer" middle="level" right="daily limit">
                <AccountList>
                  {recipientIsYou ? (
                    <BalanceRow label={youLabel("B")} middle={tierLabel(balances?.recipientTierB)} value={balances?.recipientLimitB ?? 0n} unit="$" sealed={!reads("B", true)} />
                  ) : (
                    <>
                      <BalanceRow label={youLabel("B")} middle={tierLabel(selfAtB.customer?.tier)} value={selfAtB.customer?.limit ?? 0n} unit="$" sealed={!reads("B", true)} />
                      <BalanceRow label={recipientLabel} middle={tierLabel(balances?.recipientTierB)} value={balances?.recipientLimitB ?? 0n} unit="$" sealed={!reads("B", false)} copy={recipient ?? undefined} />
                    </>
                  )}
                  {others(others(books.B?.customers, recipient), self).map((c) => (
                    <BalanceRow key={c.address} label={accountLabel(c.address, reads("B", false))} copy={c.address} middle={tierLabel(c.tier)} value={c.limit} unit="$" sealed={!reads("B", false)} />
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
                  <span className="current-tx-title" title={currentStep.title}>
                    {currentStep.title}
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

        <section className="controls panel" aria-labelledby="controls-title">
          <h2 className="panel-title" id="controls-title">
            What do you want to do?
          </h2>
          <div className="step">
            <h3 className="step-title">
              <span className="step-num">1</span> Fund your account at Bank A
            </h3>
            <div className="step-row">
              <button className={btn("deposit")} onClick={() => run("deposit")} disabled={!canDeposit}>
                Deposit
              </button>
              <label className="field">
                <span className="field-label">Amount</span>
                <span className="field-box">
                  <input value={depositAmount} onChange={(e) => setDepositAmount(e.target.value)} disabled={busy} inputMode="decimal" spellCheck={false} />
                  <span className="field-unit">€</span>
                </span>
              </label>
            </div>
          </div>
          <div className="step">
            <h3 className="step-title">
              <span className="step-num">2</span> Pay someone at Bank B
            </h3>
            <div className="step-row">
              <button className={btn("payment")} onClick={() => run("payment")} disabled={!canPay}>
                Send
              </button>
              <label className="field">
                <span className="field-label">
                  Amount
                  {costWei != null && <span className="field-help">costs {fmt(costWei)} €</span>}
                </span>
                <span className="field-box">
                  <input value={amount} onChange={(e) => setAmount(e.target.value)} disabled={busy} inputMode="decimal" spellCheck={false} />
                  <span className="field-unit">$</span>
                </span>
              </label>
              <label className="field recipient-field">
                <span className="field-label">Recipient at Bank B</span>
                <span className="field-box">
                  <input
                    value={editingRecipient || !isAddress(recipientInput.trim()) ? recipientInput : short(recipientInput.trim())}
                    title={recipientInput || identity.domain.address}
                    onFocus={() => setEditingRecipient(true)}
                    onBlur={() => setEditingRecipient(false)}
                    onChange={(e) => {
                      setRecipientInput(e.target.value);
                      if (denyKyc) setScenarioState("settle");
                    }}
                    disabled={busy}
                    placeholder={`${short(identity.domain.address)} (you)`}
                    spellCheck={false}
                  />
                </span>
              </label>
              <div className="field">
                <span className="field-label" id="outcome-label">
                  Select flow
                </span>
                <div className="segmented" role="radiogroup" aria-labelledby="outcome-label">
                  {SCENARIOS.map((option) => (
                    <button
                      key={option.id}
                      type="button"
                      role="radio"
                      aria-checked={scenario === option.id}
                      className={`segment${scenario === option.id ? " on" : ""}`}
                      onClick={() => setScenario(option.id)}
                      disabled={busy}
                    >
                      {option.label}
                    </button>
                  ))}
                </div>
              </div>
            </div>
          </div>
          {ready && !hasGas && <p className="hint">Your account has no MON for gas - press "Get test funds" first.</p>}
          {ready && hasGas && costWei != null && balances!.userLimitA < costWei && (
            <p className="hint">
              {balances!.userTierA === 0
                ? 'You are not onboarded at Bank A yet - press "Get test funds" first.'
                : `This costs ${fmt(costWei)} €, more than the ${fmt(balances!.userLimitA)} € left on your daily limit at Bank A today - Bank A would refuse the order. The limit resets at 00:00 UTC.`}
            </p>
          )}
          {ready && hasGas && denyKyc && (
            <p className="hint">Bank B has never verified this address: it will deny the KYC inquiry, and Bank A refunds your €.</p>
          )}
          {ready && hasGas && !denyKyc && reads("B", false) && recipient != null && amountOutWei != null && balances!.recipientLimitB < amountOutWei && (
            <p className="hint">
              The recipient's daily limit at Bank B does not cover this amount today - Bank B will deny the KYC inquiry and Bank A refunds your €.
              Limits reset at 00:00 UTC.
            </p>
          )}
        </section>

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
                    ? "Deposit - €: Monad public network → your account at Bank A (delivered by the protocol)"
                    : `Bank payment - $${amount} to ${recipient ? short(recipient) : "…"} · KYC round trip, ${denyKyc ? "denial, refund" : `liquidity lock on the Monad public network, ${expireLock ? "timeout refund" : "atomic settlement"}`}`}
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
              <span className="entry-actor">{s.actor}</span>
              <span className="entry-body">
                <span className="entry-title">
                  {s.title}
                  {s.atomic && <span className="atomic-badge">1 L1 TX</span>}
                  {publicMode && s.publicLeak && <span className="leak-badge">IN CLEAR</span>}
                </span>
                <span className="entry-detail">
                  {!publicMode || s.publicView === undefined
                    ? s.detail
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
              Your account signs every transaction of yours: deposits on the Monad public network and domain transactions carried to the hub inside a
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
              <span>you</span>
              <code>{identity.l1.address}</code>
            </div>
          </details>

        </footer>
      </div>
    </>
  );
}
