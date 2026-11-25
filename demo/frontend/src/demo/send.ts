import { bytesToHex, encodeFunctionData, toFunctionSelector, zeroAddress, type Address, type Hex } from "viem";
import type { Identity } from "../lib/account";
import { domainA, domainB, l1, until } from "../lib/chain";
import { DEMO_DOMAIN_BRIDGE_ABI, DEMO_L1_BRIDGE_ABI, ERC20_ABI, POOL_ABI } from "../lib/demo-abi";
import { CHAIN_A, CHAIN_B, deployment, quoteEurIn } from "../lib/deployment";
import { DEPOSIT_DELIVERY_GAS, DEPOSIT_MESSAGE_BYTES, fetchBalances, filePaymentOrder, ledgerBalanceA, ledgerBalanceB, type Balances, type Step } from "../lib/flows";
import { deliveryFee, HUB_INPUT_GAS_HEADROOM, sendL1, sequenceDomainTx } from "../lib/sequencer";
import { trackPayment } from "../lib/watch";

/** Where tokens can sit: € and $ on Monad, € at Bank A, $ at Bank B. */
export type Ledger = "eurL1" | "eurA" | "usdB" | "usdL1";

export const LEDGERS: Record<Ledger, { label: string; unit: string }> = {
  eurA: { label: "€ · Bank A", unit: "€" },
  usdB: { label: "$ · Bank B", unit: "$" },
  eurL1: { label: "€ · Monad", unit: "€" },
  usdL1: { label: "$ · Monad", unit: "$" },
};

export const LEDGER_ORDER: Ledger[] = ["eurA", "usdB", "eurL1", "usdL1"];

/**
 * Where each source can send to. € and $ move between Monad and their bank through the
 * bridges; € becomes $ only through the liquidity pool, which only Bank A can use (the bank
 * payment, € at Bank A -> $ at Bank B). So € on Monad reaches $ by going through both banks,
 * and there is no way from $ back to €.
 */
export const DESTINATIONS: Record<Ledger, Ledger[]> = {
  eurL1: ["eurL1", "eurA", "usdB", "usdL1"],
  eurA: ["eurA", "usdB", "eurL1", "usdL1"],
  usdB: ["usdB", "usdL1"],
  usdL1: ["usdL1", "usdB"],
};

/** The wallet's balances: the shared reads plus $ on Monad. */
export type WalletBalances = Balances & { usdL1: bigint };

export async function fetchWalletBalances(identity: Identity): Promise<WalletBalances> {
  const address = identity.domain.address;
  const [b, usdL1] = await Promise.all([
    // The company is also the "recipient" here, so the Bank B figures are its own.
    fetchBalances(identity.l1.address, address, address),
    l1.readContract({ address: deployment.tokens.usd, abi: ERC20_ABI, functionName: "balanceOf", args: [identity.l1.address] }),
  ]);
  return { ...b, usdL1 };
}

export function balanceOn(ledger: Ledger, b: WalletBalances): bigint {
  return { eurA: b.userEurOnA, usdB: b.userUsdOnB, eurL1: b.eurL1, usdL1: b.usdL1 }[ledger];
}

const isEuro = (l: Ledger) => l === "eurL1" || l === "eurA";

/** What the sender pays for `amount` arriving at the destination (the pool's quote for € -> $). */
export function costOf(from: Ledger, to: Ledger, amount: bigint): bigint {
  return isEuro(from) && !isEuro(to) ? quoteEurIn(amount) : amount;
}

const SWAP_SELECTOR = toFunctionSelector("function swap(uint256,address)").slice(2);
let swapSupport: Promise<boolean> | null = null;

/**
 * Whether the deployed pool has the direct `swap` (pools deployed before it was added do
 * not): its selector appears in the contract's dispatcher. Asked once per page load.
 */
export function poolCanSwap(): Promise<boolean> {
  swapSupport ??= l1
    .getCode({ address: deployment.pool })
    .then((code) => !!code && code.toLowerCase().includes(SWAP_SELECTOR))
    .catch(() => {
      swapSupport = null; // ask again next time
      return false;
    });
  return swapSupport;
}

/** One line on what the route does and who can see it; `direct`: the pool can swap on Monad. */
export function describeRoute(from: Ledger, to: Ledger, direct = false): string {
  const key = `${from}>${to}`;
  if (key === "eurL1>usdL1" && direct)
    return "A direct swap at the liquidity pool on Monad (1 € = 1.2 $), in one public transaction - anyone can see it.";
  switch (key) {
    case "eurL1>eurL1":
    case "usdL1>usdL1":
      return "A public transfer on Monad - anyone can see it.";
    case "eurL1>eurA":
    case "usdL1>usdB":
      return `A deposit: locked at the bridge on Monad (public) and credited at Bank ${to === "eurA" ? "A" : "B"} (private).`;
    case "eurA>eurA":
    case "usdB>usdB":
      return `A private transfer inside Bank ${from === "eurA" ? "A" : "B"}'s domain - only the bank sees it.`;
    case "eurA>usdB":
      return "A bank payment: Bank A checks the recipient with Bank B (KYC), locks $ at the liquidity pool and settles atomically.";
    case "eurA>eurL1":
    case "usdB>usdL1":
      return `A withdrawal: the tokens leave Bank ${from === "eurA" ? "A" : "B"} and are paid out on Monad once the operators relay it.`;
    case "eurL1>usdB":
      return "Two steps: deposit the € into your own account at Bank A, then a bank payment to the recipient at Bank B.";
    case "eurA>usdL1":
      return "Two steps: a bank payment to your own account at Bank B (€ -> $ at the pool), then a withdrawal of the $ to the recipient on Monad.";
    case "eurL1>usdL1":
      return "The deployed pool has no direct swap yet (it needs a redeploy), so this goes through both banks in three steps: deposit € at Bank A, bank payment to your own $ account at Bank B, withdraw the $ to the recipient on Monad. Takes a few minutes.";
    default:
      return "";
  }
}

export type Progress = (text: string, running: boolean, detail?: string) => void;

type Zone = "A" | "B";
const zoneOf = (l: Ledger): Zone => (l === "eurA" || l === "eurL1" ? "A" : "B");
const tokenOf = (zone: Zone) => (zone === "A" ? deployment.tokens.eur : deployment.tokens.usd);
const unitOf = (zone: Zone) => (zone === "A" ? "€" : "$");
const chainOf = (zone: Zone) => (zone === "A" ? CHAIN_A : CHAIN_B);
const ledgerBalance = (zone: Zone, account: Address) => (zone === "A" ? ledgerBalanceA(account) : ledgerBalanceB(account));
const l1Balance = (zone: Zone, account: Address) => l1.readContract({ address: tokenOf(zone), abi: ERC20_ABI, functionName: "balanceOf", args: [account] });

// ---------------------------------------------------------------------------
// The legs every route is made of.
// ---------------------------------------------------------------------------

/** A transfer on one ledger: public on Monad, a private domain transaction at a bank. */
async function transfer(identity: Identity, ledger: Ledger, recipient: Address, amount: bigint, progress: Progress): Promise<Hex> {
  if (ledger === "eurL1" || ledger === "usdL1") {
    const zone = zoneOf(ledger);
    progress(`Transferring ${unitOf(zone)} on Monad…`, true);
    const { hash } = await sendL1(identity, { address: tokenOf(zone), abi: ERC20_ABI, functionName: "transfer", args: [recipient, amount] });
    return hash;
  }
  const zone = zoneOf(ledger);
  const wrapped = await bankLedger(zone);
  progress(`Private transfer inside Bank ${zone}…`, true);
  const sent = await sequenceDomainTx({
    identity,
    chainId: chainOf(zone),
    to: wrapped,
    viewingKey: deployment.domains[zone].viewingKey,
    data: encodeFunctionData({ abi: ERC20_ABI, functionName: "transfer", args: [recipient, amount] }),
    gas: 100_000n,
  });
  return sent.domainTxHash;
}

/** The bank's wrapped ledger token on its domain (deployed with the first deposit). */
async function bankLedger(zone: Zone): Promise<Address> {
  const client = zone === "A" ? domainA : domainB;
  const d = deployment.domains[zone];
  const ledger = await client.readContract({ address: d.domainBridge, abi: DEMO_DOMAIN_BRIDGE_ABI, functionName: "bridgedTokens", args: [tokenOf(zone)] });
  if (ledger === zeroAddress) throw new Error(`Bank ${zone} has no ledger yet - nothing has been deposited there`);
  return ledger;
}

/** Monad -> bank: lock at the bridge, wait until the bank's domain credits the recipient. */
async function deposit(identity: Identity, zone: Zone, recipient: Address, amount: bigint, progress: Progress): Promise<Hex> {
  const d = deployment;
  const bridge = d.domains[zone].l1Bridge;
  const before = await ledgerBalance(zone, recipient).catch(() => 0n);
  const allowance = await l1.readContract({ address: tokenOf(zone), abi: ERC20_ABI, functionName: "allowance", args: [identity.l1.address, bridge] });
  if (allowance < amount) {
    progress(`Approving bridge ${zone} on Monad…`, true);
    await sendL1(identity, { address: tokenOf(zone), abi: ERC20_ABI, functionName: "approve", args: [bridge, amount] });
  }
  progress(`Locking ${unitOf(zone)} at bridge ${zone} on Monad…`, true);
  const { hash } = await sendL1(identity, {
    address: bridge, abi: DEMO_L1_BRIDGE_ABI, functionName: "bridgeToDomain", args: [recipient, tokenOf(zone), amount],
    // The deposit pays for its own delivery on the domain.
    value: await deliveryFee(DEPOSIT_MESSAGE_BYTES, DEPOSIT_DELIVERY_GAS),
    gasHeadroom: HUB_INPUT_GAS_HEADROOM,
  });
  progress(`Waiting for Bank ${zone} to credit the deposit…`, true);
  await until(`the deposit to land at Bank ${zone}`, () => ledgerBalance(zone, recipient), (balance) => balance >= before + amount, 180_000);
  return hash;
}

/** Bank -> Monad: burn on the domain, wait until the operators' relay pays it out on Monad. */
async function withdraw(identity: Identity, zone: Zone, recipient: Address, amount: bigint, progress: Progress): Promise<Hex> {
  const before = await l1Balance(zone, recipient);
  progress(`Withdrawing ${unitOf(zone)} from Bank ${zone}…`, true);
  const sent = await sequenceDomainTx({
    identity,
    chainId: chainOf(zone),
    to: deployment.domains[zone].domainBridge,
    viewingKey: deployment.domains[zone].viewingKey,
    // The salt keeps the withdrawal's message id from revealing its content before it is relayed.
    data: encodeFunctionData({
      abi: DEMO_DOMAIN_BRIDGE_ABI, functionName: "bridgeToL1",
      args: [recipient, tokenOf(zone), amount, bytesToHex(crypto.getRandomValues(new Uint8Array(32)))],
    }),
    gas: 300_000n,
  });
  progress("Waiting for the operators to pay it out on Monad…", true);
  await until("the withdrawal to arrive on Monad", () => l1Balance(zone, recipient), (balance) => balance >= before + amount, 300_000, 2_000);
  return sent.domainTxHash;
}

/** € on Monad -> $ on Monad at the pool, in one transaction (after the approval, if needed). */
async function swap(identity: Identity, recipient: Address, amountOut: bigint, progress: Progress): Promise<Hex> {
  const d = deployment;
  const cost = quoteEurIn(amountOut);
  const allowance = await l1.readContract({ address: d.tokens.eur, abi: ERC20_ABI, functionName: "allowance", args: [identity.l1.address, d.pool] });
  if (allowance < cost) {
    progress("Approving the pool to take the €…", true);
    await sendL1(identity, { address: d.tokens.eur, abi: ERC20_ABI, functionName: "approve", args: [d.pool, cost] });
  }
  progress("Swapping at the pool on Monad…", true);
  const { hash } = await sendL1(identity, { address: d.pool, abi: POOL_ABI, functionName: "swap", args: [amountOut, recipient] });
  return hash;
}

/** € at Bank A -> $ at Bank B through the pool; throws unless the $ were delivered. */
async function pay(identity: Identity, recipient: Address, amountOut: bigint, progress: Progress): Promise<Hex> {
  const report = (s: Step) => progress(s.title, s.status === "running", s.detail);
  const order = await filePaymentOrder(identity, recipient, amountOut, false, report);
  const outcome = await trackPayment(order, report);
  if (!outcome.settled) {
    throw new Error(
      !outcome.approved
        ? "Bank B denied the KYC inquiry - Bank A refunded the €"
        : outcome.lockFailed
          ? "The pool had no liquidity to lock - Bank A refunded the €"
          : "The payment did not settle - the € were refunded",
    );
  }
  return order.requestTxHash;
}

/**
 * Sends tokens from one of the sender's ledgers to `recipient` on the destination ledger;
 * `amount` is what arrives. Routes that cross between € and $ or between Monad and a bank
 * are chained legs, each waiting for the previous one to land; intermediate steps use the
 * sender's own accounts.
 */
export async function sendRoute(identity: Identity, from: Ledger, to: Ledger, recipient: Address, amount: bigint, progress: Progress): Promise<Hex> {
  if (!DESTINATIONS[from].includes(to)) throw new Error(`cannot send from ${LEDGERS[from].label} to ${LEDGERS[to].label}`);
  if (from === to) return transfer(identity, from, recipient, amount, progress);
  if (from === "eurL1" && to === "usdL1" && (await poolCanSwap())) return swap(identity, recipient, amount, progress);

  const self = identity.domain.address;
  const legs: ((p: Progress) => Promise<Hex>)[] = [];
  let at: Ledger = from;
  // € on Monad heading anywhere but Bank A goes into the sender's own Bank A account first.
  if (at === "eurL1") {
    if (to === "eurA") legs.push((p) => deposit(identity, "A", recipient, amount, p));
    else legs.push((p) => deposit(identity, "A", self, costOf(from, to, amount), p));
    at = "eurA";
  }
  if (at === "eurA" && to !== "eurA") {
    if (to === "eurL1") legs.push((p) => withdraw(identity, "A", recipient, amount, p));
    else if (to === "usdB") legs.push((p) => pay(identity, recipient, amount, p));
    else legs.push((p) => pay(identity, self, amount, p));
    at = to === "usdL1" ? "usdB" : to;
  }
  if (at === "usdB" && to === "usdL1") legs.push((p) => withdraw(identity, "B", recipient, amount, p));
  if (at === "usdL1" && to === "usdB") legs.push((p) => deposit(identity, "B", recipient, amount, p));

  let hash: Hex | undefined;
  for (const [i, leg] of legs.entries()) {
    const prefix = legs.length > 1 ? `Step ${i + 1}/${legs.length}: ` : "";
    hash = await leg((text, running, detail) => progress(prefix + text, running, detail));
  }
  return hash!;
}
