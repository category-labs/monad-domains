import { decodeAbiParameters, encodeFunctionData, parseAbiParameters, parseEventLogs, zeroAddress, type Address, type Hex } from "viem";
import type { Identity } from "./account";
import { OPERATOR_URL, domainA, domainB, l1, scriptHeaders, until } from "./chain";
import { DEMO_DOMAIN_BRIDGE_ABI, DEMO_L1_BRIDGE_ABI, ERC20_ABI, L2_BANK_ABI, POOL_ABI, SPOKE_ABI } from "./demo-abi";
import { CHAIN_A, deployment, quoteEurIn } from "./deployment";
import { sendL1, sequenceDomainTx } from "./sequencer";

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
  supplyUsdB: bigint;
  /** Registry entries: visitor at Bank A, recipient at Bank B. */
  userLimitA: bigint;
  recipientLimitB: bigint;
  ledgerA: Address;
  ledgerB: Address;
}

const orDefault = async <T>(read: Promise<T>, fallback: T): Promise<T> => read.catch(() => fallback);

export async function fetchBalances(l1Address: Address, domainAddress: Address, recipient: Address): Promise<Balances> {
  const d = deployment;
  const [mon, eurL1, lockedEurA, poolEur, poolUsd, poolUsdLocked, lockedUsdB, ledgerA, ledgerB, userLimitA, recipientLimitB] =
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
    ]);
  const read = (client: typeof domainA, token: Address, call: { functionName: "balanceOf"; args: [Address] } | { functionName: "totalSupply" }) =>
    token === zeroAddress ? Promise.resolve(0n) : orDefault(client.readContract({ address: token, abi: ERC20_ABI, ...call }) as Promise<bigint>, 0n);
  const [userEurOnA, supplyEurA, custodyEurA, recipientUsdOnB, supplyUsdB] = await Promise.all([
    read(domainA, ledgerA, { functionName: "balanceOf", args: [domainAddress] }),
    read(domainA, ledgerA, { functionName: "totalSupply" }),
    read(domainA, ledgerA, { functionName: "balanceOf", args: [d.domains.A.bank] }),
    read(domainB, ledgerB, { functionName: "balanceOf", args: [recipient] }),
    read(domainB, ledgerB, { functionName: "totalSupply" }),
  ]);
  return {
    mon, eurL1, lockedEurA, poolEur, poolUsd, poolUsdLocked, lockedUsdB,
    userEurOnA, supplyEurA, custodyEurA, recipientUsdOnB, supplyUsdB, userLimitA, recipientLimitB, ledgerA, ledgerB,
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
    title: `Test funds issued${body.drip ? " - MON for gas and" : " -"} demo € on the L1`,
    detail: "eur.mint(you, 1000) from the faucet account; the drip keeps your account above the gas threshold",
  });
  report({ seq: 1, zone: "B", actor: "Bank B", title: "Bank B registers you as a known depositor", detail: "setReceiveAllowance(you, limit) - sequenced by the bank operator on domain B (and mirrored at Bank A)", status: "running" });
  await until(
    "the registry entry at Bank B",
    () => domainB.readContract({ address: deployment.domains.B.bank, abi: L2_BANK_ABI, functionName: "receiveAllowance", args: [identity.domain.address] }),
    (limit) => limit > 0n,
    180_000,
    1_500,
  );
  report({ seq: 1, zone: "B", actor: "Bank B", title: "You are on Bank B's know-your-depositor registry", detail: "Bank B will approve payments to you up to the registered limit", status: "done" });
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
    report({ seq: 0, zone: "L1", actor: "You", title: "Approve the L1 bridge to take your €", detail: "eur.approve(l1BridgeA, amount)", status: "running" });
    const { hash } = await sendL1(identity, { address: d.tokens.eur, abi: ERC20_ABI, functionName: "approve", args: [d.domains.A.l1Bridge, amount] });
    report({ seq: 0, zone: "L1", actor: "You", title: "L1 bridge approved", detail: "eur.approve(l1BridgeA, amount)", status: "done", txHash: hash });
  }
  report({ seq: 1, zone: "L1", actor: "You", title: "Locking € on the L1 for your domain account", detail: "l1BridgeA.bridgeToDomain(you, EUR, amount) locks the € and records the transfer on the hub", status: "running" });
  const { hash } = await sendL1(identity, {
    address: d.domains.A.l1Bridge,
    abi: DEMO_L1_BRIDGE_ABI,
    functionName: "bridgeToDomain",
    args: [identity.domain.address, d.tokens.eur, amount],
  });
  report({ seq: 1, zone: "L1", actor: "You", title: "€ locked on the L1, deposit message recorded on the hub", detail: "hub.L1MessageRecorded - the domain protocol derives a system transaction from it", status: "done", txHash: hash });
  report({ seq: 2, zone: "A", actor: "Protocol", title: "Waiting for the protocol to deliver the deposit on domain A", detail: "the node injects spoke.relayL1Message as a system transaction; the bridge mints wrapped €", status: "running" });
  await until("the deposit to land on domain A", () => ledgerBalanceA(identity.domain.address), (balance) => balance >= before + amount, 180_000);
  report({ seq: 2, zone: "A", actor: "Protocol", title: "Wrapped € minted into your account at Bank A", detail: "DemoDomainBridge.onDomainMessage minted the bridged ledger token", status: "done" });
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
  "(uint64 sourceChainId, uint64 destinationChainId, address from, address to, uint256 sourceNonce, bytes data) message",
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
    report({ seq: 0, zone: "A", actor: "You", title: "Bank A authorised to debit the quoted €", detail: "wrapped-EUR.approve(bankA, quote) executed on domain A", status: "done", txHash: approve.domainTxHash });
  }
  report({ seq: 1, zone: "A", actor: "You", title: "Filing the payment order", detail: "bankA.requestTransfer(recipient, $amount) takes the quoted € into custody and fires the KYC inquiry toward Bank B", status: "running" });
  const request = await sequenceDomainTx({
    identity, chainId: CHAIN_A, to: d.domains.A.bank, viewingKey: d.domains.A.viewingKey,
    data: encodeFunctionData({ abi: L2_BANK_ABI, functionName: "requestTransfer", args: [recipient, amountOut, expireLock] }),
    gas: 400_000n,
  });
  const [requested] = parseEventLogs({ abi: L2_BANK_ABI, eventName: "TransferRequested", logs: request.receipt.logs });
  if (!requested) throw new Error("requestTransfer emitted no TransferRequested event");
  const [recorded] = parseEventLogs({ abi: SPOKE_ABI, eventName: "DomainMessageRecorded", logs: request.receipt.logs });
  if (!recorded) throw new Error("the inquiry was not recorded on the spoke");
  const [blockL1, recipientUsdBefore, userEurBefore] = await Promise.all([
    l1.getTransactionReceipt({ hash: request.l1TxHash }).then((r) => r.blockNumber),
    ledgerBalanceB(recipient),
    domainA.readContract({ address: ledger, abi: ERC20_ABI, functionName: "balanceOf", args: [identity.domain.address] }),
  ]);
  report({
    seq: 1, zone: "A", actor: "You", status: "done", txHash: request.domainTxHash,
    title: `Payment order #${requested.args.requestId} filed - ${fmt(amountIn)} € in custody, KYC inquiry recorded`,
    detail: "bankA.requestTransfer executed on domain A; spoke.sendDomainMessage queued the inquiry for Bank B",
  });
  return {
    requestId: requested.args.requestId,
    user: identity.domain.address,
    recipientUsdBefore,
    userEurBefore,
    blockA: request.receipt.blockNumber,
    blockL1,
    inquiryId: recorded.args.messageId,
    amountOut,
    amountIn,
    recipient,
    expireLock,
    requestTxHash: request.domainTxHash,
  };
}

export function fmt(wei: bigint): string {
  const whole = wei / 10n ** 18n;
  const frac = wei % 10n ** 18n;
  if (frac === 0n) return whole.toString();
  return `${whole}.${frac.toString().padStart(18, "0").replace(/0+$/, "").slice(0, 4)}`;
}
