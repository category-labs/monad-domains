import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { isAddress, parseEther, type Address } from "viem";
import { type Identity } from "../lib/account";
import { l1 } from "../lib/chain";
import { fmtAmount, onboard, type Step } from "../lib/flows";
import { MonadLogo } from "../MonadLogo";
import ChainFeed from "./TransactionFeed";
import ClassicView from "./ClassicView";
import { CUSTOMERS, addressOf, identityFor, type Customer } from "./customers";
import { DESTINATIONS, LEDGERS, LEDGER_ORDER, balanceOn, costOf, describeRoute, fetchWalletBalances, poolCanSwap, sendRoute, type Ledger, type WalletBalances } from "./send";
import "./demo.css";

function short(address: string) {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

function CopyAddress({ address }: { address: Address }) {
  const [copied, setCopied] = useState(false);
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(address);
      setCopied(true);
      setTimeout(() => setCopied(false), 1200);
    } catch {
      // clipboard unavailable: the full address is in the tooltip
    }
  };
  return (
    <button type="button" className="wallet-address" onClick={copy} title={`${address} - click to copy`}>
      {copied ? "Copied" : short(address)}
    </button>
  );
}

/** The shared step texts speak to "you"; a wallet shows them for its company. */
function forCompany(text: string, name: string): string {
  return text.replace(/\byour\b/g, `${name}'s`).replace(/\bYour\b/g, `${name}'s`).replace(/\byou\b/gi, name);
}

/** Who receives: the other company, this company itself (another of its accounts), or any address. */
type RecipientKind = "counterpart" | "self" | "other";

/** What a wallet is doing, shown beside its buttons. */
type Status = { running: boolean; text: string; title?: string };

function Wallet({ customer, counterpart }: { customer: Customer; counterpart: Customer }) {
  const [identity] = useState<Identity>(() => identityFor(customer));
  const [balances, setBalances] = useState<WalletBalances | null>(null);
  const [offline, setOffline] = useState(false);
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState<Status | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [sending, setSending] = useState(false);
  const [from, setFrom] = useState<Ledger>("eurL1");
  const [to, setTo] = useState<Ledger>("eurA");
  const [amount, setAmount] = useState("10");
  const [recipientKind, setRecipientKind] = useState<RecipientKind>("counterpart");
  const [recipientInput, setRecipientInput] = useState("");
  const address = identity.domain.address;
  /** The deployed pool swaps € -> $ on Monad directly (else that route goes through the banks). */
  const [directSwap, setDirectSwap] = useState(false);
  useEffect(() => {
    void poolCanSwap().then(setDirectSwap);
  }, []);
  const counterpartAddress = useMemo(() => addressOf(counterpart), [counterpart]);

  const refreshing = useRef(false);
  const refresh = useCallback(async () => {
    if (refreshing.current) return;
    refreshing.current = true;
    try {
      setBalances(await fetchWalletBalances(identity));
      setOffline(false);
    } catch {
      setOffline(true);
    } finally {
      refreshing.current = false;
    }
  }, [identity]);

  useEffect(() => {
    void refresh();
    const t = setInterval(() => void refresh(), 3_000);
    return () => clearInterval(t);
  }, [refresh]);

  const getFunds = async () => {
    setBusy(true);
    setError(null);
    try {
      await onboard(identity, (s: Step) => {
        setStatus({ running: s.status === "running", text: forCompany(s.title, customer.name), title: forCompany(s.detail, customer.name) });
        void refresh();
      });
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
      void refresh();
    }
  };

  // Changing the source keeps the destination if it is still reachable, else the first one that is.
  const chooseFrom = (next: Ledger) => {
    setFrom(next);
    if (!DESTINATIONS[next].includes(to)) setTo(DESTINATIONS[next][0]!);
  };

  const b = balances;
  const amountWei = useMemo(() => {
    try {
      const v = parseEther(amount);
      return v > 0n ? v : null;
    } catch {
      return null;
    }
  }, [amount]);
  const recipient: Address | null =
    recipientKind === "counterpart"
      ? counterpartAddress
      : recipientKind === "self"
        ? address
        : isAddress(recipientInput.trim())
          ? (recipientInput.trim() as Address)
          : null;
  const recipientName = recipientKind === "counterpart" ? counterpart.name : recipientKind === "self" ? `${customer.name} (own account)` : recipient ? short(recipient) : "…";
  const fromUnit = LEDGERS[from].unit;
  const toUnit = LEDGERS[to].unit;
  const cost = amountWei != null ? costOf(from, to, amountWei) : null;
  const hasGas = b != null && b.mon > 10n ** 16n;
  const covered = b != null && cost != null && balanceOn(from, b) >= cost;
  const pointless = from === to && recipient != null && recipient.toLowerCase() === address.toLowerCase();
  const canSend = !busy && !offline && hasGas && covered && recipient != null && !pointless;

  const send = async () => {
    if (!b || amountWei == null || recipient == null) return;
    setBusy(true);
    setError(null);
    const what = `${fmtAmount(amountWei)} ${toUnit} to ${recipientName} at ${LEDGERS[to].label}`;
    setStatus({ running: true, text: `Sending ${what}…` });
    try {
      const hash = await sendRoute(identity, from, to, recipient, amountWei, (text, running, detail) => {
        setStatus({ running, text: forCompany(text, customer.name), title: detail && forCompany(detail, customer.name) });
        void refresh();
      });
      setStatus({ running: false, text: `Sent ${what}`, title: hash });
    } catch (err) {
      setStatus(null);
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
      void refresh();
    }
  };

  const needsFunds = b != null && (b.mon <= 10n ** 16n || b.userTierA === 0);
  // Every account this company holds, and how many tokens are in it.
  const accounts: { name: string; where: string; amount: bigint | undefined; unit: string }[] = [
    { name: "Euro", where: "Bank A", amount: b?.userEurOnA, unit: "€" },
    { name: "US Dollar", where: "Bank B", amount: b?.userUsdOnB, unit: "$" },
    { name: "Euro", where: "Monad", amount: b?.eurL1, unit: "€" },
    { name: "US Dollar", where: "Monad", amount: b?.usdL1, unit: "$" },
    { name: "Monad", where: "Monad · gas", amount: b?.mon, unit: "MON" },
  ];

  return (
    <section className="wallet panel" aria-label={`${customer.name} wallet`}>
      <header className="wallet-head">
        <div>
          <h2 className="wallet-name">{customer.name}</h2>
          <p className="wallet-kind">{customer.kind}</p>
        </div>
        <CopyAddress address={address} />
      </header>

      <ul className="wallet-list">
        {accounts.map((a) => (
          <li key={`${a.unit}-${a.where}`} className="wallet-item">
            <span className="wallet-icon" aria-hidden>
              {a.unit === "MON" ? "M" : a.unit}
            </span>
            <span className="wallet-item-name">
              {a.name}
              <span className="wallet-item-where">{a.where}</span>
            </span>
            <span className="wallet-item-amount">
              {b ? fmtAmount(a.amount ?? 0n) : "–"}
              <span className="wallet-row-unit"> {a.unit}</span>
            </span>
          </li>
        ))}
      </ul>

      {sending && (
        <div className="wallet-send">
          <label className="wallet-field">
            <span className="field-label">From</span>
            <select value={from} onChange={(e) => chooseFrom(e.target.value as Ledger)} disabled={busy}>
              {LEDGER_ORDER.map((l) => (
                <option key={l} value={l}>
                  {LEDGERS[l].label}
                </option>
              ))}
            </select>
          </label>
          <span className="wallet-arrow" aria-hidden>
            →
          </span>
          <label className="wallet-field">
            <span className="field-label">To</span>
            <select value={to} onChange={(e) => setTo(e.target.value as Ledger)} disabled={busy}>
              {LEDGER_ORDER.filter((l) => DESTINATIONS[from].includes(l)).map((l) => (
                <option key={l} value={l}>
                  {LEDGERS[l].label}
                </option>
              ))}
            </select>
          </label>
          <label className="wallet-field">
            <span className="field-label">
              Amount
              {cost != null && cost !== amountWei && (
                <span className="field-help">
                  costs {fmtAmount(cost)} {fromUnit}
                </span>
              )}
            </span>
            <span className="field-box">
              <input value={amount} onChange={(e) => setAmount(e.target.value)} disabled={busy} inputMode="decimal" spellCheck={false} />
              <span className="field-unit">{toUnit}</span>
            </span>
          </label>
          <label className="wallet-field wallet-field-wide">
            <span className="field-label">Recipient</span>
            <select value={recipientKind} onChange={(e) => setRecipientKind(e.target.value as RecipientKind)} disabled={busy}>
              <option value="counterpart">{counterpart.name}</option>
              <option value="self">{customer.name} (own account)</option>
              <option value="other">Another address…</option>
            </select>
          </label>
          {recipientKind === "other" && (
            <label className="wallet-field wallet-field-wide">
              <span className="field-label">Address</span>
              <span className="field-box">
                <input value={recipientInput} onChange={(e) => setRecipientInput(e.target.value)} disabled={busy} placeholder="0x…" spellCheck={false} />
              </span>
            </label>
          )}
          <p className="wallet-send-note">
            {describeRoute(from, to, directSwap)}
            {b && cost != null && !covered && ` Not enough: ${fmtAmount(balanceOn(from, b))} ${fromUnit} at ${LEDGERS[from].label}.`}
            {b && !hasGas && " No MON for gas - get test funds first."}
            {pointless && " That is the same account - choose another recipient or destination."}
            {recipientKind === "other" && recipientInput.trim() !== "" && recipient == null && " That is not an address."}
          </p>
        </div>
      )}

      <div className="wallet-actions">
        {sending ? (
          <>
            <button className="btn primary" onClick={send} disabled={!canSend}>
              Send
            </button>
            <button className="btn ghost" onClick={() => setSending(false)} disabled={busy}>
              Close
            </button>
          </>
        ) : (
          <>
            <button className={`btn${needsFunds ? " primary" : ""}`} onClick={getFunds} disabled={busy || offline || !b}>
              Get test funds
            </button>
            <button className={`btn${needsFunds ? "" : " primary"}`} onClick={() => setSending(true)} disabled={busy || offline || !b}>
              Send
            </button>
          </>
        )}
        {offline && <span className="wallet-status error-text">node unreachable</span>}
        {!offline && status && (
          <span className="wallet-status" title={status.title ?? status.text}>
            {status.running ? <span className="spinner" /> : "✓"} {status.text}
          </span>
        )}
      </div>
      {error && <div className="error">{error}</div>}
    </section>
  );
}

export default function App() {
  const [block, setBlock] = useState<bigint | null>(null);
  const [offline, setOffline] = useState(false);

  useEffect(() => {
    const poll = async () => {
      try {
        setBlock(await l1.getBlockNumber({ cacheTime: 0 }));
        setOffline(false);
      } catch {
        setOffline(true);
      }
    };
    void poll();
    const t = setInterval(() => void poll(), 2_500);
    return () => clearInterval(t);
  }, []);

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
      <div className="page wallets-page">
        <header className="masthead">
          <h1 className="title">
            Two companies, two wallets, <em>their own accounts.</em>
          </h1>
        </header>
        <main className="split">
          {CUSTOMERS.map((c) => (
            <Wallet key={c.id} customer={c} counterpart={CUSTOMERS.find((o) => o.id !== c.id)!} />
          ))}
        </main>
        <ChainFeed />
      </div>
      <ClassicView />
    </>
  );
}
