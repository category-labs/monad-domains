import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { isAddress, parseEther, type Address, type Hex } from "viem";
import {
  browserIdentity,
  connectInjectedWallet,
  exportSessionKey,
  hasInjectedWallet,
  resetSessionKey,
  short,
  type Identity,
} from "./lib/account";
import { OPERATOR_URL, l1 } from "./lib/chain";
import { CHAIN_A, CHAIN_B, EXPLORER, RATE_DEN, RATE_NUM, deployment, quoteEurIn } from "./lib/deployment";
import { depositToA, fetchBalances, filePaymentOrder, fmt, onboard, type Balances, type Step } from "./lib/flows";
import { PAYMENT_STEPS, trackPayment } from "./lib/watch";
import { MonadLogo } from "./MonadLogo";

type FlowKind = "onboard" | "deposit" | "payment";
/** Rail states: left rail A<->L1 (AL1 rightward, L1A leftward), right rail L1<->B. */
type Edge = "L1A" | "AL1" | "L1B" | "BL1" | null;

const STEP_COUNT: Record<FlowKind, number> = { onboard: 2, deposit: 3, payment: PAYMENT_STEPS };

interface OperatorStatus {
  uptimeMs: number;
  relayer: { chainId: string; scannedThrough: string | null; recorded: number; batches: number; anchored: number; relayed: number; lastError: string | null }[];
  bankAgent: { cursor: string; nextRequestId: string | null; executed: number; lastError: string | null };
  queue: number;
}

/** Which rail segment carries the value/message for a running step. */
function edgeFor(flow: FlowKind, step: Step, expireLock: boolean): Edge {
  if (flow === "onboard") return step.seq === 1 ? "L1B" : null;
  if (flow === "deposit") return "L1A";
  const s = step.seq;
  if (s <= 2) return "AL1"; // order + inquiry head to the L1
  if (s <= 3) return "L1B"; // inquiry delivered to Bank B
  if (s <= 4) return "BL1"; // reply heads back to the L1
  if (s <= 5) return "L1A"; // reply delivered to Bank A
  if (s === 6) return null; // the liquidity lock is L1-local
  if (s <= 8) return "AL1"; // the € payment travels to the pool
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

function BalanceRow({ label, value, unit, strong, double }: { label: string; value: bigint; unit: string; strong?: boolean; double?: boolean }) {
  const flash = useFlash(value);
  return (
    <div className={`balance-row${strong ? " strong" : ""}${flash ? " flash" : ""}${double ? " double" : ""}`}>
      <span className="balance-label">{label}</span>
      <span className="balance-value">
        {fmt(value)}
        <span className="unit"> {unit}</span>
      </span>
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

function LedgerGroup({ name, right, children }: { name: string; right?: string; children: React.ReactNode }) {
  return (
    <div className="ledger-group">
      <div className="ledger-sub">
        <span>{name}</span>
        {right && <span className="ledger-sub-right">{right}</span>}
      </div>
      {children}
    </div>
  );
}

function Station({ zone, tag, name, active, children }: { zone: "A" | "L1" | "B"; tag: string; name: string; active: boolean; children: React.ReactNode }) {
  return (
    <section className={`station station-${zone}${active ? " active" : ""}`}>
      <div className="station-tag">{tag}</div>
      <h2 className="station-name">{name}</h2>
      <div className="station-balances">{children}</div>
    </section>
  );
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
  const [operator, setOperator] = useState<OperatorStatus | null>(null);
  const [amount, setAmount] = useState("60");
  const [recipientInput, setRecipientInput] = useState("");
  const [expireLock, setExpireLock] = useState(false);
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

  useEffect(() => {
    void refresh(true);
    const t = setInterval(() => void refresh(), 2_500);
    return () => clearInterval(t);
  }, [refresh]);

  useEffect(() => {
    const load = () =>
      fetch(`${OPERATOR_URL}/api/status`)
        .then((r) => (r.ok ? (r.json() as Promise<OperatorStatus>) : null))
        .then((s) => setOperator(s))
        .catch(() => setOperator(null));
    void load();
    const t = setInterval(load, 5_000);
    return () => clearInterval(t);
  }, []);

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

  const run = useCallback(
    async (kind: FlowKind) => {
      if (kind !== "onboard" && (amountOutWei == null || costWei == null)) {
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
          await depositToA(identity, costWei!, report);
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
    [amount, amountOutWei, costWei, expireLock, identity, recipient, report, refresh],
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
  const edge: Edge = busy && running && flow ? edgeFor(flow, running, expireLock) : null;
  const atomicLive = !!(running?.atomic && busy);
  const activeZone = busy ? running?.zone : undefined;

  const rateLabel = `1 € = ${fmt((10n ** 18n * RATE_NUM) / RATE_DEN)} $`;
  const availableUsd = balances != null ? balances.poolUsd - balances.poolUsdLocked : 0n;
  const totalEurL1 = (balances?.eurL1 ?? 0n) + (balances?.lockedEurA ?? 0n) + (balances?.poolEur ?? 0n);
  const hasGas = (balances?.mon ?? 0n) > 10n ** 16n;
  const ready = !busy && !offline && balances != null;
  const canDeposit = ready && costWei != null && balances!.eurL1 >= costWei && hasGas;
  const canPay =
    ready &&
    costWei != null &&
    amountOutWei != null &&
    recipient != null &&
    balances!.userEurOnA >= costWei &&
    availableUsd >= amountOutWei &&
    balances!.recipientLimitB >= amountOutWei &&
    hasGas;
  const needsOnboarding = ready && (!hasGas || balances!.eurL1 + balances!.userEurOnA === 0n || balances!.recipientLimitB === 0n);
  const relayerHead = operator?.relayer.find((r) => r.chainId === CHAIN_A.toString())?.scannedThrough;

  return (
    <>
      <header className="topbar">
        <div className="brand">
          <MonadLogo className="brand-logo" />
          <span className="brand-product">Private Settlement Domains</span>
        </div>
        <div className="badges">
          <div className={`node-badge${operator ? "" : " offline"}`} title="The operator service runs the relayer, Bank A's back office and the faucet">
            <span className="pulse" />
            <span>
              {operator ? (
                <>
                  operator · relayer at <strong>{relayerHead ?? "…"}</strong>
                  {operator.queue > 0 ? ` · ${operator.queue} queued` : ""}
                </>
              ) : (
                "operator service unreachable"
              )}
            </span>
          </div>
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
              Two banks, two currencies, <em>one L1 settlement.</em>
              <button
                type="button"
                className={`intro-toggle${showIntro ? " open" : ""}`}
                onClick={() => setShowIntro((v) => !v)}
                aria-expanded={showIntro}
                aria-controls="intro"
                aria-label={showIntro ? "Hide description" : "Show description"}
              />
            </h1>
            <p className="lede" id="intro" hidden={!showIntro}>
              You bank in <strong>€ with Bank A on private settlement domain A</strong>; your recipient banks in{" "}
              <strong>$ with Bank B on private settlement domain B</strong>. You ask Bank A to send $ to the recipient. Bank A first{" "}
              <strong>KYC-inquires with Bank B</strong> (real cross-domain messages, both ways, relayed by the operators), then takes a{" "}
              <strong>liquidity lock</strong> at the L1 pool ({rateLabel}), charges you the quoted € and the pool's settlement delivers the
              locked $ to the recipient - or refunds the € if the lock timed out first. Every transaction here is signed by your own
              account; the relaying is done by the operators' service, not by this page.
            </p>
          </div>
        </header>

        <section className="account">
          <div className="account-main">
            <div className="account-row">
              <span className="field-label">{identity.l1.kind === "injected" ? "Connected wallet (L1)" : "Browser account (L1 + domains)"}</span>
              <code className="account-address" title={identity.l1.address}>
                {identity.l1.address}
              </code>
              {identity.l1.kind === "injected" && (
                <>
                  <span className="field-label">Domain account (session key)</span>
                  <code className="account-address" title={identity.domain.address}>
                    {identity.domain.address}
                  </code>
                </>
              )}
            </div>
            <div className="account-row stats">
              <span>
                <strong>{fmt(balances?.mon ?? 0n)}</strong> MON for gas
              </span>
              <span>
                <strong>{fmt(balances?.eurL1 ?? 0n)}</strong> € on the L1
              </span>
              <span>
                <strong>{fmt(balances?.userEurOnA ?? 0n)}</strong> € at Bank A
              </span>
              <span>
                KYC limit at Bank B: <strong>{fmt(balances?.recipientLimitB ?? 0n)}</strong> $
              </span>
            </div>
          </div>
          <div className="account-actions">
            <button className={`btn${needsOnboarding ? " primary" : ""}`} onClick={() => run("onboard")} disabled={busy || offline || !balances}>
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
            <button className="btn reset" onClick={startOver} disabled={busy} title="Generate a new browser key">
              ↺ New account
            </button>
            <button className="btn reset" onClick={() => setShowKey((v) => !v)} disabled={busy}>
              {showKey ? "Hide key" : "Export key"}
            </button>
          </div>
          {showKey && (
            <p className="account-key">
              Browser key (test funds only, never reuse elsewhere): <code>{exportSessionKey() ?? "n/a"}</code>
            </p>
          )}
        </section>

        <main className="board">
          <Station zone="A" tag={`Private settlement domain A · ${CHAIN_A}`} name="Bank A · € ledger" active={activeZone === "A"}>
            <LedgerGroup name="€ Ledger (wrapped)">
              <BalanceRow label="You" value={balances?.userEurOnA ?? 0n} unit="€" strong double />
              <BalanceRow label="Bank A custody" value={balances?.custodyEurA ?? 0n} unit="€" />
              <BalanceRow label="total supply" value={balances?.supplyEurA ?? 0n} unit="€" />
            </LedgerGroup>
            <LedgerGroup name="KYC'd depositors" right="limit">
              <BalanceRow label="You" value={balances?.userLimitA ?? 0n} unit="€" />
            </LedgerGroup>
          </Station>
          <Rail edge={edge === "L1B" || edge === "BL1" ? null : edge} atomic={atomicLive} />
          <Station zone="L1" tag="Public execution · Monad testnet" name="L1 · ledgers + liquidity pool" active={activeZone === "L1"}>
            <LedgerGroup name="€ Ledger">
              <BalanceRow label="You" value={balances?.eurL1 ?? 0n} unit="€" />
              <BalanceRow label="Liquidity pool" value={balances?.poolEur ?? 0n} unit="€" strong />
              <BalanceRow label="Domain A escrow" value={balances?.lockedEurA ?? 0n} unit="€" double />
              <BalanceRow label="total" value={totalEurL1} unit="€" />
            </LedgerGroup>
            <LedgerGroup name="$ Ledger">
              <BalanceRow label="Liquidity pool" value={balances?.poolUsd ?? 0n} unit="$" strong />
              <BalanceRow label="reserved by locks" value={balances?.poolUsdLocked ?? 0n} unit="$" />
              <BalanceRow label="Domain B escrow" value={balances?.lockedUsdB ?? 0n} unit="$" double />
            </LedgerGroup>
            <LedgerGroup name="Pool">
              <InfoRow label="rate">{rateLabel}</InfoRow>
              <InfoRow label="hub">
                <code title={deployment.hub}>{short(deployment.hub)}</code>
              </InfoRow>
            </LedgerGroup>
          </Station>
          <Rail edge={edge === "L1B" || edge === "BL1" ? edge : null} atomic={atomicLive} />
          <Station zone="B" tag={`Private settlement domain B · ${CHAIN_B}`} name="Bank B · $ ledger" active={activeZone === "B"}>
            <LedgerGroup name="$ Ledger (wrapped)">
              <BalanceRow label="Recipient" value={balances?.recipientUsdOnB ?? 0n} unit="$" strong double />
              <BalanceRow label="total supply" value={balances?.supplyUsdB ?? 0n} unit="$" />
            </LedgerGroup>
            <LedgerGroup name="KYC'd depositors" right="limit">
              <BalanceRow label="Recipient" value={balances?.recipientLimitB ?? 0n} unit="$" />
            </LedgerGroup>
          </Station>
        </main>

        <section className="controls">
          <div className="controls-row">
            <label className="amount-field">
              <span className="field-label">Amount</span>
              <input value={amount} onChange={(e) => setAmount(e.target.value)} disabled={busy} inputMode="decimal" spellCheck={false} />
              <span className="field-unit">${costWei != null ? ` - costs ${fmt(costWei)} €` : ""}</span>
            </label>
            <label className="amount-field recipient-field">
              <span className="field-label">Recipient at Bank B</span>
              <input
                value={recipientInput}
                onChange={(e) => setRecipientInput(e.target.value)}
                disabled={busy}
                placeholder={`${identity.domain.address} (you)`}
                spellCheck={false}
              />
            </label>
            <label className="amount-field" style={{ cursor: busy ? "default" : "pointer" }}>
              <input type="checkbox" checked={expireLock} onChange={(e) => setExpireLock(e.target.checked)} disabled={busy} style={{ width: "auto" }} />
              <span className="field-label" style={{ whiteSpace: "nowrap" }}>
                let the lock expire → refund path
              </span>
            </label>
          </div>
          <div className="controls-row">
            <button className="btn" onClick={() => run("deposit")} disabled={!canDeposit}>
              <span className="btn-step">1</span> Deposit {costWei != null ? `${fmt(costWei)} €` : "€"} into your account at Bank A
            </button>
            <button className="btn primary" onClick={() => run("payment")} disabled={!canPay}>
              <span className="btn-step">2</span> Send ${amountOutWei != null ? fmt(amountOutWei) : ""} to the recipient <span className="btn-note">KYC + lock + settle</span>
            </button>
          </div>
          {ready && !hasGas && <p className="hint">Your account has no MON for gas - press "Get test funds" first.</p>}
          {ready && hasGas && recipient != null && amountOutWei != null && balances!.recipientLimitB < amountOutWei && (
            <p className="hint">
              The recipient is not registered at Bank B for this amount - Bank B would deny the KYC inquiry. Onboard the recipient's address first
              (or send to yourself).
            </p>
          )}
        </section>

        {error && <div className="error">{error}</div>}

        {steps.length > 0 && (
          <section className="ledger">
            <div className="ledger-head">
              <span>
                {flow === "onboard"
                  ? "Onboarding - test funds from the operator's faucet, registry entries at both banks"
                  : flow === "deposit"
                    ? "Deposit - € : L1 → your account at Bank A (delivered by the protocol)"
                    : `Bank payment - $${amount} to ${recipient ? short(recipient) : "…"} · KYC round trip, L1 liquidity lock, ${expireLock ? "timeout refund" : "atomic settlement"}`}
              </span>
              <span className="ledger-count">
                {steps.filter((s) => s.status === "done").length}/{flow ? STEP_COUNT[flow] : 0} steps
              </span>
            </div>
            {steps.map((s) => (
              <div key={s.seq} className={`entry${s.atomic ? " atomic" : ""} ${s.status}`}>
                <span className="entry-seq">{String(s.seq + 1).padStart(2, "0")}</span>
                <span className={`entry-zone zone-${s.zone}`}>{s.zone === "L1" ? "L1" : `PSD ${s.zone}`}</span>
                <span className="entry-actor">{s.actor}</span>
                <span className="entry-body">
                  <span className="entry-title">
                    {s.title}
                    {s.atomic && <span className="atomic-badge">1 L1 TX</span>}
                  </span>
                  <span className="entry-detail">{s.detail}</span>
                </span>
                <span className="entry-tx">
                  <TxLink hash={s.txHash} zone={s.zone} />
                </span>
                <span className="entry-status">{s.status === "done" ? "✓" : <span className="spinner" />}</span>
              </div>
            ))}
          </section>
        )}

        <footer className="colophon">
          <details>
            <summary>Cast of contracts &amp; accounts</summary>
            <div className="addr-grid">
              <span>hub (L1)</span>
              <code>{deployment.hub}</code>
              <span>spoke A / B</span>
              <code>
                {short(deployment.domains.A.spoke)} · {short(deployment.domains.B.spoke)}
              </code>
              <span>L1 bridge A / B</span>
              <code>
                {short(deployment.domains.A.l1Bridge)} · {short(deployment.domains.B.l1Bridge)}
              </code>
              <span>domain bridge A / B</span>
              <code>
                {short(deployment.domains.A.domainBridge)} · {short(deployment.domains.B.domainBridge)}
              </code>
              <span>€ / $ ledgers (L1)</span>
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
          <p>
            Your account signs every transaction of yours: deposits on the L1 and domain transactions carried to the hub inside an L1
            transaction, encrypted to the domain's viewing key. The KYC inquiry and reply are real cross-domain messages routed by the hub;
            the operators' service (open source, <code>npm run operator</code>) finalizes, attests and proves them, runs Bank A's back office
            and the faucet. Nothing is relayed by this page.
          </p>
        </footer>
      </div>
    </>
  );
}
