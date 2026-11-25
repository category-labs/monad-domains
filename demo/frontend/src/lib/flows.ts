import { decodeAbiParameters, encodeFunctionData, parseAbiParameters, parseEventLogs, zeroAddress, type Address, type Hex } from "viem";
import { short, type Identity } from "./account";
import { OPERATOR_URL, domainA, domainB, l1, scriptHeaders, until } from "./chain";
import { DEMO_DOMAIN_BRIDGE_ABI, DEMO_L1_BRIDGE_ABI, ERC20_ABI, L2_BANK_ABI, POOL_ABI, SPOKE_ABI } from "./demo-abi";
import { CHAIN_A, deployment, quoteEurIn } from "./deployment";
import { deliveryFee, HUB_INPUT_GAS_HEADROOM, sendL1, sequenceDomainTx, type SequencedTx } from "./sequencer";

/**
 * Gas bought for the delivery of a deposit on the domain. The first deposit of a ledger also
 * deploys its wrapped token there.
 */
export const DEPOSIT_DELIVERY_GAS = 2_500_000n;
/** A deposit's message is `abi.encode(recipient, token, amount)`. */
export const DEPOSIT_MESSAGE_BYTES = 96;

/** Where a step executes, for the flow visualisation. */
export type Zone = "A" | "L1" | "B";

export interface Step {
  /** Stable id within one flow run. */
  seq: number;
  zone: Zone;
  actor: string;
  title: string;
  detail: string;
  status: "running" | "done";
  txHash?: Hex;
  /** Marks the single atomic L1 transaction of the payment. */
  atomic?: boolean;
  /**
   * What anyone reading Monad sees of this step, for the page's public view; `null` when
   * the step leaves no public trace (it ran inside a domain).
   */
  publicView?: string | null;
  /** The public view shows data a domain would ideally keep private (plaintext routing). */
  publicLeak?: boolean;
  /** The L1 transaction the public view refers to (the courier, for a domain transaction). */
  publicTxHash?: Hex;
}

/** The public footprint of a domain transaction: its courier transaction on the L1. */
export function courierView(from: Address, chainId: bigint, sequenced: SequencedTx): Pick<Step, "publicView" | "publicTxHash"> {
  const bytes = (sequenced.ciphertext.length - 2) / 2;
  return {
    publicView: `courier transaction from ${short(from)}: hub.sequenceToDomain(${chainId}, ${sequenced.ciphertext.slice(0, 18)}… ${bytes} bytes of ciphertext) - who sent it, to which domain, nothing more`,
    publicTxHash: sequenced.l1TxHash,
  };
}

export type Report = (step: Step) => void;

export interface Balances {
  mon: bigint;
  eurL1: bigint;
  lockedEurA: bigint;
  poolEur: bigint;
  poolUsd: bigint;
  poolUsdLocked: bigint;
  lockedUsdB: bigint;
  /** Visitor's wrapped EUR at Bank A, and the bank's custody. */
  userEurOnA: bigint;
  supplyEurA: bigint;
  custodyEurA: bigint;
  recipientUsdOnB: bigint;
  /** Your own $ at Bank B (the same as the recipient's when you pay yourself). */
  userUsdOnB: bigint;
  supplyUsdB: bigint;
  /** Registry entries (remaining daily limits): visitor at Bank A, recipient at Bank B. */
  userLimitA: bigint;
  recipientLimitB: bigint;
  /** KYC tiers (0 = not onboarded): visitor at Bank A, recipient at Bank B. */
  userTierA: number;
  recipientTierB: number;
  ledgerA: Address;
  ledgerB: Address;
}

const orDefault = async <T>(read: Promise<T>, fallback: T): Promise<T> => read.catch(() => fallback);

export async function fetchBalances(l1Address: Address, domainAddress: Address, recipient: Address): Promise<Balances> {
  const d = deployment;
  const [mon, eurL1, lockedEurA, poolEur, poolUsd, poolUsdLocked, lockedUsdB, ledgerA, ledgerB, userLimitA, recipientLimitB, userTierA, recipientTierB] =
    await Promise.all([
      l1.getBalance({ address: l1Address }),
      l1.readContract({ address: d.tokens.eur, abi: ERC20_ABI, functionName: "balanceOf", args: [l1Address] }),
      l1.readContract({ address: d.tokens.eur, abi: ERC20_ABI, functionName: "balanceOf", args: [d.domains.A.l1Bridge] }),
      l1.readContract({ address: d.tokens.eur, abi: ERC20_ABI, functionName: "balanceOf", args: [d.pool] }),
      l1.readContract({ address: d.tokens.usd, abi: ERC20_ABI, functionName: "balanceOf", args: [d.pool] }),
      l1.readContract({ address: d.pool, abi: POOL_ABI, functionName: "lockedOut" }),
      l1.readContract({ address: d.tokens.usd, abi: ERC20_ABI, functionName: "balanceOf", args: [d.domains.B.l1Bridge] }),
      orDefault(domainA.readContract({ address: d.domains.A.domainBridge, abi: DEMO_DOMAIN_BRIDGE_ABI, functionName: "bridgedTokens", args: [d.tokens.eur] }), zeroAddress),
      orDefault(domainB.readContract({ address: d.domains.B.domainBridge, abi: DEMO_DOMAIN_BRIDGE_ABI, functionName: "bridgedTokens", args: [d.tokens.usd] }), zeroAddress),
      orDefault(domainA.readContract({ address: d.domains.A.bank, abi: L2_BANK_ABI, functionName: "receiveAllowance", args: [domainAddress] }), 0n),
      orDefault(domainB.readContract({ address: d.domains.B.bank, abi: L2_BANK_ABI, functionName: "receiveAllowance", args: [recipient] }), 0n),
      orDefault(domainA.readContract({ address: d.domains.A.bank, abi: L2_BANK_ABI, functionName: "kycTier", args: [domainAddress] }), 0),
      orDefault(domainB.readContract({ address: d.domains.B.bank, abi: L2_BANK_ABI, functionName: "kycTier", args: [recipient] }), 0),
    ]);
  const read = (client: typeof domainA, token: Address, call: { functionName: "balanceOf"; args: [Address] } | { functionName: "totalSupply" }) =>
    token === zeroAddress ? Promise.resolve(0n) : orDefault(client.readContract({ address: token, abi: ERC20_ABI, ...call }) as Promise<bigint>, 0n);
  const [userEurOnA, supplyEurA, custodyEurA, recipientUsdOnB, supplyUsdB, userUsdOnB] = await Promise.all([
    read(domainA, ledgerA, { functionName: "balanceOf", args: [domainAddress] }),
    read(domainA, ledgerA, { functionName: "totalSupply" }),
    read(domainA, ledgerA, { functionName: "balanceOf", args: [d.domains.A.bank] }),
    read(domainB, ledgerB, { functionName: "balanceOf", args: [recipient] }),
    read(domainB, ledgerB, { functionName: "totalSupply" }),
    read(domainB, ledgerB, { functionName: "balanceOf", args: [domainAddress] }),
  ]);
  return {
    mon, eurL1, lockedEurA, poolEur, poolUsd, poolUsdLocked, lockedUsdB,
    userEurOnA, supplyEurA, custodyEurA, recipientUsdOnB, userUsdOnB, supplyUsdB, userLimitA, recipientLimitB, userTierA, recipientTierB, ledgerA, ledgerB,
  };
}

// ---------------------------------------------------------------------------
// Onboarding: the operator's faucet funds the visitor and registers them with the banks.
// ---------------------------------------------------------------------------

export interface OnboardResponse {
  address: Address;
  domainAddress: Address;
  drip: Hex | null;
  mint: Hex;
  registration: { id: string; status: string };
}

export async function onboard(identity: Identity, report: Report): Promise<OnboardResponse> {
  report({ seq: 0, zone: "L1", actor: "Operator", title: "Asking the operator's faucet for test funds", detail: "POST /api/onboard - gas, demo €, and a registry entry at both banks", status: "running" });
  const response = await fetch(`${OPERATOR_URL}/api/onboard`, {
    method: "POST",
    headers: { "content-type": "application/json", ...scriptHeaders() },
    body: JSON.stringify({ address: identity.l1.address, domainAddress: identity.domain.address }),
  });
  const body = (await response.json()) as OnboardResponse & { error?: string };
  if (!response.ok) throw new Error(body.error ?? `onboarding failed (${response.status})`);
  await l1.waitForTransactionReceipt({ hash: body.mint });
  // The node's transaction pool sees a fresh balance a couple of seconds after the receipt;
  // settle before the visitor's first transaction so it is not rejected and retried.
  if (body.drip) await new Promise((resolve) => setTimeout(resolve, 3_000));
  report({
    seq: 0, zone: "L1", actor: "Operator", status: "done", txHash: body.mint,
    title: `Test funds issued${body.drip ? " - MON for gas and" : " -"} demo € on the Monad public network`,
    detail: "eur.mint(you, 1000) from the faucet account; the drip keeps your account above the gas threshold",
    publicView: `the faucet minted demo € to ${short(identity.l1.address)}${body.drip ? " and sent it MON" : ""} - ordinary transactions on the Monad public network, readable by anyone`,
    publicTxHash: body.mint,
  });
  report({ seq: 1, zone: "B", actor: "Banks", title: "Bank B and Bank A put you in their KYC tiers", detail: "setKycTier(you, tier) - sequenced by the bank operator on domain B, then on domain A", status: "running" });
  // Bank A is registered after Bank B, so its entry means both are in place.
  await until(
    "the KYC tier at Bank A",
    () => domainA.readContract({ address: deployment.domains.A.bank, abi: L2_BANK_ABI, functionName: "kycTier", args: [identity.domain.address] }),
    (tier) => tier > 0,
    180_000,
    1_500,
  );
  report({ seq: 1, zone: "B", actor: "Banks", title: "You are KYC'd at both banks", detail: "Bank B will approve payments to you, and Bank A will take your orders, up to your tier's daily limit", status: "done", publicView: "two courier transactions from the bank operator to domains B and A - ciphertext only; your tiers and limits stay inside the domains" });
  return body;
}

// ---------------------------------------------------------------------------
// Deposit: € from the L1 into the visitor's account at Bank A (protocol-delivered).
// ---------------------------------------------------------------------------

export async function depositToA(identity: Identity, amount: bigint, report: Report): Promise<void> {
  const d = deployment;
  const before = await orDefault(ledgerBalanceA(identity.domain.address), 0n);
  const allowance = await l1.readContract({ address: d.tokens.eur, abi: ERC20_ABI, functionName: "allowance", args: [identity.l1.address, d.domains.A.l1Bridge] });
  if (allowance < amount) {
    report({ seq: 0, zone: "L1", actor: "You", title: "Approve the bridge on the Monad public network to take your €", detail: "eur.approve(l1BridgeA, amount)", status: "running" });
    const { hash } = await sendL1(identity, { address: d.tokens.eur, abi: ERC20_ABI, functionName: "approve", args: [d.domains.A.l1Bridge, amount] });
    report({ seq: 0, zone: "L1", actor: "You", title: "Bridge on the Monad public network approved", detail: "eur.approve(l1BridgeA, amount)", status: "done", txHash: hash, publicView: `${short(identity.l1.address)} approved domain A's bridge for ${fmt(amount)} € - an ordinary transaction on the Monad public network`, publicTxHash: hash });
  }
  report({ seq: 1, zone: "L1", actor: "You", title: "Locking € on the Monad public network for your domain account", detail: "l1BridgeA.bridgeToDomain(you, EUR, amount) locks the € and records the transfer on the hub", status: "running" });
  const { hash } = await sendL1(identity, {
    address: d.domains.A.l1Bridge,
    abi: DEMO_L1_BRIDGE_ABI,
    functionName: "bridgeToDomain",
    args: [identity.domain.address, d.tokens.eur, amount],
    // The deposit pays for its own delivery on the domain.
    value: await deliveryFee(DEPOSIT_MESSAGE_BYTES, DEPOSIT_DELIVERY_GAS),
    gasHeadroom: HUB_INPUT_GAS_HEADROOM,
  });
  report({ seq: 1, zone: "L1", actor: "You", title: "€ locked on the Monad public network, deposit message recorded on the hub", detail: "hub.L1MessageRecorded - the domain protocol derives a system transaction from it", status: "done", txHash: hash, publicView: `${fmt(amount)} € moved from ${short(identity.l1.address)} into domain A's bridge for domain account ${short(identity.domain.address)} - deposits are recorded on the Monad public network in clear`, publicTxHash: hash });
  report({ seq: 2, zone: "A", actor: "Protocol", title: "Waiting for the protocol to deliver the deposit on domain A", detail: "the node injects spoke.relayL1Message as a system transaction; the bridge mints wrapped €", status: "running" });
  await until("the deposit to land on domain A", () => ledgerBalanceA(identity.domain.address), (balance) => balance >= before + amount, 180_000);
  report({ seq: 2, zone: "A", actor: "Protocol", title: "Wrapped € minted into your account at Bank A", detail: "DemoDomainBridge.onDomainMessage minted the bridged ledger token", status: "done", publicView: null });
}

/** The recipient's wrapped $ at Bank B (0 until the first $ deposit deploys the ledger). */
export async function ledgerBalanceB(account: Address): Promise<bigint> {
  const ledger = await domainB.readContract({ address: deployment.domains.B.domainBridge, abi: DEMO_DOMAIN_BRIDGE_ABI, functionName: "bridgedTokens", args: [deployment.tokens.usd] });
  if (ledger === zeroAddress) return 0n;
  return domainB.readContract({ address: ledger, abi: ERC20_ABI, functionName: "balanceOf", args: [account] });
}

export async function ledgerBalanceA(account: Address): Promise<bigint> {
  const ledger = await domainA.readContract({ address: deployment.domains.A.domainBridge, abi: DEMO_DOMAIN_BRIDGE_ABI, functionName: "bridgedTokens", args: [deployment.tokens.eur] });
  if (ledger === zeroAddress) return 0n;
  return domainA.readContract({ address: ledger, abi: ERC20_ABI, functionName: "balanceOf", args: [account] });
}

// ---------------------------------------------------------------------------
// Payment order: the visitor's two domain transactions. Everything after that is the
// banks', the relayer's and the protocol's work - see watch.ts.
// ---------------------------------------------------------------------------

export interface PaymentOrder {
  requestId: bigint;
  /** The domain account that filed the order (refunds return to it). */
  user: Address;
  /** Ledger balances right after the order was filed: the delivery is the change on top. */
  recipientUsdBefore: bigint;
  userEurBefore: bigint;
  /** Domain A block the order was filed in. */
  blockA: bigint;
  /** Domain B's latest block when the order was filed: each domain numbers its own blocks. */
  blockB: bigint;
  /** L1 block the order was sequenced in. */
  blockL1: bigint;
  /** Message id of the KYC inquiry recorded on spoke A. */
  inquiryId: Hex;
  amountOut: bigint;
  amountIn: bigint;
  recipient: Address;
  expireLock: boolean;
  requestTxHash: Hex;
}

const DOMAIN_MESSAGE = parseAbiParameters(
  "(uint64 sourceChainId, uint64 destinationChainId, address from, address to, uint256 sourceNonce, bytes32 salt, bytes data) message",
);

export function decodeEnvelope(encoded: Hex) {
  const [message] = decodeAbiParameters(DOMAIN_MESSAGE, encoded);
  return message;
}

export async function filePaymentOrder(
  identity: Identity,
  recipient: Address,
  amountOut: bigint,
  expireLock: boolean,
  report: Report,
): Promise<PaymentOrder> {
  const d = deployment;
  const amountIn = quoteEurIn(amountOut);
  const ledger = await domainA.readContract({ address: d.domains.A.domainBridge, abi: DEMO_DOMAIN_BRIDGE_ABI, functionName: "bridgedTokens", args: [d.tokens.eur] });
  if (ledger === zeroAddress) throw new Error("no wrapped € on domain A yet - deposit first");
  const allowance = await domainA.readContract({ address: ledger, abi: ERC20_ABI, functionName: "allowance", args: [identity.domain.address, d.domains.A.bank] });
  if (allowance < amountIn) {
    report({ seq: 0, zone: "A", actor: "You", title: "Mandate: authorise Bank A to debit your account", detail: "wrapped-EUR.approve(bankA, quote) - a domain transaction, sequenced through the hub", status: "running" });
    const approve = await sequenceDomainTx({
      identity, chainId: CHAIN_A, to: ledger, viewingKey: d.domains.A.viewingKey,
      data: encodeFunctionData({ abi: ERC20_ABI, functionName: "approve", args: [d.domains.A.bank, amountIn] }),
      gas: 100_000n,
    });
    report({ seq: 0, zone: "A", actor: "You", title: "Bank A authorised to debit the quoted €", detail: "wrapped-EUR.approve(bankA, quote) executed on domain A", status: "done", txHash: approve.domainTxHash, ...courierView(identity.l1.address, CHAIN_A, approve) });
  }
  report({ seq: 1, zone: "A", actor: "You", title: "Filing the payment order", detail: "bankA.requestTransfer(recipient, $amount) takes the quoted € into custody and fires the KYC inquiry toward Bank B", status: "running" });
  const request = await sequenceDomainTx({
    identity, chainId: CHAIN_A, to: d.domains.A.bank, viewingKey: d.domains.A.viewingKey,
    data: encodeFunctionData({ abi: L2_BANK_ABI, functionName: "requestTransfer", args: [recipient, amountOut, expireLock] }),
    gas: 700_000n,
  });
  const [requested] = parseEventLogs({ abi: L2_BANK_ABI, eventName: "TransferRequested", logs: request.receipt.logs });
  if (!requested) throw new Error("requestTransfer emitted no TransferRequested event");
  const [recorded] = parseEventLogs({ abi: SPOKE_ABI, eventName: "DomainMessageRecorded", logs: request.receipt.logs });
  if (!recorded) throw new Error("the inquiry was not recorded on the spoke");
  const [blockL1, blockB, recipientUsdBefore, userEurBefore] = await Promise.all([
    l1.getTransactionReceipt({ hash: request.l1TxHash }).then((r) => r.blockNumber),
    domainB.getBlockNumber({ cacheTime: 0 }),
    ledgerBalanceB(recipient),
    domainA.readContract({ address: ledger, abi: ERC20_ABI, functionName: "balanceOf", args: [identity.domain.address] }),
  ]);
  report({
    seq: 1, zone: "A", actor: "You", status: "done", txHash: request.domainTxHash,
    title: `Payment order #${requested.args.requestId} filed - ${fmt(amountIn)} € in custody, KYC inquiry recorded`,
    detail: "bankA.requestTransfer executed on domain A; spoke.sendDomainMessage queued the inquiry for Bank B",
    ...courierView(identity.l1.address, CHAIN_A, request),
  });
  return {
    requestId: requested.args.requestId,
    user: identity.domain.address,
    recipientUsdBefore,
    userEurBefore,
    blockA: request.receipt.blockNumber,
    blockL1,
    blockB,
    inquiryId: recorded.args.messageId,
    amountOut,
    amountIn,
    recipient,
    expireLock,
    requestTxHash: request.domainTxHash,
  };
}

/** A balance with two fixed decimals and thousands separators, e.g. 1,950.00 (rounded down). */
export function fmtAmount(wei: bigint): string {
  const negative = wei < 0n;
  const cents = (negative ? -wei : wei) / 10n ** 16n;
  const whole = (cents / 100n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return `${negative ? "-" : ""}${whole}.${(cents % 100n).toString().padStart(2, "0")}`;
}

export function fmt(wei: bigint): string {
  const whole = wei / 10n ** 18n;
  const frac = wei % 10n ** 18n;
  if (frac === 0n) return whole.toString();
  return `${whole}.${frac.toString().padStart(18, "0").replace(/0+$/, "").slice(0, 4)}`;
}
