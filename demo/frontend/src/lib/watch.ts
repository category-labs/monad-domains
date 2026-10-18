import { encodeAbiParameters, keccak256, parseEventLogs, type Address, type Hex, type Log, type PublicClient } from "viem";
import { domainA, domainB, l1 } from "./chain";
import { DEMO_DOMAIN_BRIDGE_ABI, HUB_ABI, L2_BANK_ABI, POOL_ABI, SPOKE_ABI } from "./demo-abi";
import { CHAIN_A, CHAIN_B, deployment } from "./deployment";
import { decodeEnvelope, fmt, ledgerBalanceA, ledgerBalanceB, type PaymentOrder, type Report } from "./flows";

const DEBUG = typeof process !== "undefined" && process.env?.WATCH_DEBUG === "1";
const trace = (line: string) => {
  if (DEBUG) console.log(`      [watch] ${line}`);
};

/**
 * Follows a payment order through the system by reading the chains, so the page can show
 * the same ledger of steps whether the work is done by the banks, the relayer or the
 * protocol. Each chain is scanned for logs from the block the order started in, a log
 * window at a time, and every milestone is reported once with the transaction it came from.
 *
 * Milestones (step numbers continue after the visitor's own two transactions):
 *   2  A -> L1  relayer proves the inquiry on the hub, which forwards it to domain B
 *   3  B        Bank B answers from its registry in the delivery transaction
 *   4  B -> L1  relayer proves the reply on the hub, which forwards it to domain A
 *   5  A        Bank A receives the reply: approved (or denied -> custody refunded, end)
 *   6  L1       Bank A's operator reserves liquidity at the pool (lock id, quote)
 *   7  A        Bank A executes the payment: custody withdrawn to the pool with the lock memo
 *   8  L1       relayer proves the withdrawal; in that one transaction the bridge pays the
 *               pool, the pool settles (or refunds) the lock and bridges the result
 *   9  B / A    the protocol delivers the $ to the recipient at Bank B, or the € refund to you
 */
export const PAYMENT_STEPS = 10;

const LOG_WINDOW = 999n;
/** Blocks re-read on every poll: the newest blocks may not have execution results yet. */
const SCAN_OVERLAP = 24n;

interface Scanner {
  name: string;
  client: PublicClient;
  next: bigint;
  addresses: Address[];
  seen: Set<string>;
}

async function scan(s: Scanner): Promise<Log[]> {
  const latest = await s.client.getBlockNumber({ cacheTime: 0 });
  const out: Log[] = [];
  let from = s.next;
  const first = from;
  while (from <= latest) {
    const to = from + LOG_WINDOW < latest ? from + LOG_WINDOW : latest;
    const logs = await s.client.getLogs({ address: s.addresses, fromBlock: from, toBlock: to });
    for (const log of logs) {
      const key = `${log.transactionHash}:${log.logIndex}`;
      if (s.seen.has(key)) continue;
      s.seen.add(key);
      out.push(log);
    }
    from = to + 1n;
  }
  const floor = s.next;
  s.next = latest + 1n > SCAN_OVERLAP ? latest + 1n - SCAN_OVERLAP : 0n;
  if (s.next < floor) s.next = floor;
  trace(`${s.name}: scanned ${first}..${latest}, ${out.length} new log(s)${out.length ? ": " + out.map((l) => `${l.blockNumber}/${l.address.slice(0, 8)}/${l.logIndex}`).join(" ") : ""}`);
  return out;
}

export interface PaymentOutcome {
  approved: boolean;
  settled: boolean;
  refunded: boolean;
  lockId: bigint | null;
}

export async function trackPayment(
  order: PaymentOrder,
  report: Report,
  options: { timeoutMs?: number; signal?: AbortSignal; pollMs?: number } = {},
): Promise<PaymentOutcome> {
  const d = deployment;
  const requestKey = keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [d.domains.A.bank, order.requestId]));
  const scanners = {
    l1: { name: "L1", client: l1, next: order.blockL1, addresses: [d.hub, d.pool], seen: new Set() } as Scanner,
    a: { name: "A", client: domainA, next: order.blockA, addresses: [d.domains.A.bank, d.domains.A.spoke, d.domains.A.domainBridge], seen: new Set() } as Scanner,
    b: { name: "B", client: domainB, next: order.blockL1, addresses: [d.domains.B.bank, d.domains.B.spoke, d.domains.B.domainBridge], seen: new Set() } as Scanner,
  };
  const done = new Set<number>();
  const outcome: PaymentOutcome = { approved: false, settled: false, refunded: false, lockId: null };
  let replyId: Hex | null = null;
  let withdrawalId: Hex | null = null;
  let settleBlock: bigint | null = null;
  // Deliveries are seen by the domain scanners, possibly in the same pass that first sees
  // the settlement on the L1 (the scanners run before the L1 scan), so candidates are
  // collected unconditionally and resolved against the settlement block afterwards.
  const usdDeliveries: { block: bigint; tx: Hex | undefined }[] = [];
  const eurRefunds: { block: bigint; tx: Hex | undefined }[] = [];
  const deadline = Date.now() + (options.timeoutMs ?? 10 * 60_000);
  const user = order.requestTxHash; // only used for labelling

  const mark = (step: Parameters<Report>[0]) => {
    if (done.has(step.seq)) return;
    done.add(step.seq);
    report(step);
  };
  const running = (seq: number, zone: "A" | "L1" | "B", actor: string, title: string, detail: string) => {
    if (!done.has(seq) && !done.has(-seq)) {
      done.add(-seq);
      report({ seq, zone, actor, title, detail, status: "running" });
    }
  };

  running(2, "L1", "Relayer", "Relayer carrying the KYC inquiry to the L1", "finalize the batch on domain A, attest the state root on the hub, prove the message");

  while (Date.now() < deadline) {
    if (options.signal?.aborted) throw new Error("tracking aborted");

    // --- Domain A: Bank A events, the withdrawal envelope, refund delivery.
    for (const log of await scan(scanners.a)) {
      for (const ev of parseEventLogs({ abi: L2_BANK_ABI, logs: [log] })) {
        if (ev.eventName === "ReplyReceived" && ev.args.requestId === order.requestId) {
          outcome.approved = ev.args.approved;
          mark({
            seq: 5, zone: "A", actor: "Bank A", status: "done", txHash: log.transactionHash ?? undefined,
            title: ev.args.approved ? "Bank A received the positive KYC reply - order approved" : "Bank A received a negative KYC reply - order denied, custody refunded",
            detail: "bankA.onDomainMessage(reply), delivered by the protocol as a system transaction",
          });
          if (!ev.args.approved) return outcome;
          running(6, "L1", "Bank A", "Bank A's operator reserving liquidity at the L1 pool", "pool.lockLiquidity($amount, recipient, refundTo, ttl, requestKey)");
        }
        if (ev.eventName === "PaymentExecuted" && ev.args.requestId === order.requestId) {
          outcome.lockId = ev.args.lockId;
          mark({
            seq: 7, zone: "A", actor: "Bank A", status: "done", txHash: log.transactionHash ?? undefined,
            title: `Bank A pays the pool ${fmt(ev.args.amountIn)} € (memo: lock #${ev.args.lockId})`,
            detail: "bankA.executePayment withdraws the custodied € to the pool through the bridge, memo = lock id",
          });
          running(8, "L1", "Relayer", "Relayer carrying the € payment to the L1", "finalize, attest, prove - the bridge pays the pool and the pool settles in the same transaction");
        }
      }
      if (log.address.toLowerCase() === d.domains.A.spoke.toLowerCase() && done.has(7) && !withdrawalId) {
        for (const ev of parseEventLogs({ abi: SPOKE_ABI, eventName: "DomainMessageRecorded", logs: [log] })) {
          const envelope = decodeEnvelope(ev.args.message);
          if (envelope.from.toLowerCase() === d.domains.A.domainBridge.toLowerCase() && envelope.to.toLowerCase() === d.domains.A.l1Bridge.toLowerCase()) {
            withdrawalId = ev.args.messageId;
          }
        }
      }
      if (log.address.toLowerCase() === d.domains.A.domainBridge.toLowerCase() && log.blockNumber !== null && log.blockNumber > order.blockA) {
        for (const ev of parseEventLogs({ abi: DEMO_DOMAIN_BRIDGE_ABI, eventName: "DepositFinalized", logs: [log] })) {
          if (ev.args.recipient.toLowerCase() === order.user.toLowerCase() && ev.args.amount === order.amountIn) {
            eurRefunds.push({ block: log.blockNumber, tx: log.transactionHash ?? undefined });
          }
        }
      }
    }

    // --- Domain B: Bank B's answer (and the reply envelope), the final $ delivery.
    for (const log of await scan(scanners.b)) {
      for (const ev of parseEventLogs({ abi: L2_BANK_ABI, eventName: "InquiryAnswered", logs: [log] })) {
        if (ev.args.requestId !== order.requestId) continue;
        mark({
          seq: 3, zone: "B", actor: "Bank B", status: "done", txHash: log.transactionHash ?? undefined,
          title: ev.args.approved ? `Bank B answers KYC - the recipient may receive ${fmt(ev.args.amountOut)} $` : "Bank B answers KYC - recipient not cleared for this amount",
          detail: "bankB.onDomainMessage(inquiry) checks the know-your-depositor registry and sends the reply in the same system transaction",
        });
        running(4, "L1", "Relayer", "Relayer carrying the KYC reply to the L1", "finalize the batch on domain B, attest, prove - the hub forwards it to domain A");
      }
      if (log.address.toLowerCase() === d.domains.B.spoke.toLowerCase() && !replyId) {
        for (const ev of parseEventLogs({ abi: SPOKE_ABI, eventName: "DomainMessageRecorded", logs: [log] })) {
          const envelope = decodeEnvelope(ev.args.message);
          if (envelope.from.toLowerCase() === d.domains.B.bank.toLowerCase() && envelope.to.toLowerCase() === d.domains.A.bank.toLowerCase()) {
            replyId = ev.args.messageId;
          }
        }
      }
      if (log.address.toLowerCase() === d.domains.B.domainBridge.toLowerCase() && log.blockNumber !== null) {
        for (const ev of parseEventLogs({ abi: DEMO_DOMAIN_BRIDGE_ABI, eventName: "DepositFinalized", logs: [log] })) {
          if (ev.args.recipient.toLowerCase() === order.recipient.toLowerCase() && ev.args.amount === order.amountOut) {
            usdDeliveries.push({ block: log.blockNumber, tx: log.transactionHash ?? undefined });
          }
        }
      }
    }

    // --- L1: hub routing of both messages, the lock, the atomic settlement.
    for (const log of await scan(scanners.l1)) {
      for (const ev of parseEventLogs({ abi: HUB_ABI, logs: [log] })) {
        if (ev.eventName === "DomainMessageRouted") {
          if (ev.args.messageId.toLowerCase() === order.inquiryId.toLowerCase()) {
            mark({
              seq: 2, zone: "L1", actor: "Relayer", status: "done", txHash: log.transactionHash ?? undefined,
              title: "KYC inquiry proven on the hub and forwarded to domain B",
              detail: `hub.relayDomainMessage verified the inquiry against domain A's attested anchor and queued it for domain ${CHAIN_B}`,
            });
            running(3, "B", "Bank B", "Waiting for the protocol to deliver the inquiry to Bank B", "the node injects the forwarded message as a system transaction on domain B");
          } else if (replyId && ev.args.messageId.toLowerCase() === replyId.toLowerCase()) {
            mark({
              seq: 4, zone: "L1", actor: "Relayer", status: "done", txHash: log.transactionHash ?? undefined,
              title: "KYC reply proven on the hub and forwarded to domain A",
              detail: `hub.relayDomainMessage verified the reply against domain B's attested anchor and queued it for domain ${CHAIN_A}`,
            });
            running(5, "A", "Bank A", "Waiting for the protocol to deliver the reply to Bank A", "system transaction on domain A");
          }
        }
        if (ev.eventName === "DomainMessageRelayed" && withdrawalId && ev.args.messageHash.toLowerCase() === withdrawalId.toLowerCase()) {
          settleBlock = log.blockNumber;
        }
      }
      for (const ev of parseEventLogs({ abi: POOL_ABI, logs: [log] })) {
        if (ev.eventName === "LiquidityLocked" && ev.args.requestKey.toLowerCase() === requestKey.toLowerCase()) {
          outcome.lockId = ev.args.lockId;
          mark({
            seq: 6, zone: "L1", actor: "Bank A", status: "done", txHash: log.transactionHash ?? undefined,
            title: `Liquidity locked at the pool - lock #${ev.args.lockId}, quote ${fmt(ev.args.amountIn)} €${ev.args.expiry === 0n ? " (DEMO: born expired)" : ""}`,
            detail: `pool.lockLiquidity reserved ${fmt(ev.args.amountOut)} $ for the recipient at the current rate`,
          });
          running(7, "A", "Bank A", "Bank A executing the payment on domain A", "bankA.executePayment(requestId, lockId) - sequenced by the bank operator");
        }
        if (outcome.lockId !== null && (ev.eventName === "LockSettled" || ev.eventName === "LockRefunded") && ev.args.lockId === outcome.lockId) {
          settleBlock = log.blockNumber;
          if (ev.eventName === "LockSettled") {
            outcome.settled = true;
            mark({
              seq: 8, zone: "L1", actor: "Relayer + pool", status: "done", txHash: log.transactionHash ?? undefined, atomic: true,
              title: `ATOMIC L1 HOP - € paid in, lock #${ev.args.lockId} settled, ${fmt(ev.args.amountOut)} $ locked for domain B`,
              detail: "one L1 transaction: hub.relayDomainMessage -> DemoL1Bridge pays the pool -> pool.onBridgedTokens settles the lock -> bridge B records the $ deposit",
            });
            running(9, "B", "Protocol", "Waiting for the protocol to deliver the $ to the recipient", "system transaction on domain B mints the wrapped $");
          } else {
            outcome.refunded = true;
            mark({
              seq: 8, zone: "L1", actor: "Relayer + pool", status: "done", txHash: log.transactionHash ?? undefined, atomic: true,
              title: `LOCK EXPIRED - € paid in, lock #${ev.args.lockId} refunded toward your account on domain A`,
              detail: "one L1 transaction: the timed-out lock releases its $ reservation and bridges the € back to you",
            });
            running(9, "A", "Protocol", "Waiting for the protocol to deliver the € refund", "system transaction on domain A");
          }
        }
      }
    }

    // --- Resolve. The delivery is read from state (the ledger balance moved by the order's
    // amount), which does not depend on when the delivery block's logs become queryable;
    // a matching DepositFinalized log, when already seen, supplies the transaction hash.
    if (settleBlock !== null) {
      const after = (x: { block: bigint }) => x.block >= settleBlock!;
      if (outcome.settled) {
        const balance = await ledgerBalanceB(order.recipient);
        trace(`recipient $ at Bank B: ${balance} (before ${order.recipientUsdBefore}, expecting +${order.amountOut})`);
        if (balance >= order.recipientUsdBefore + order.amountOut) {
          mark({
            seq: 9, zone: "B", actor: "Protocol", status: "done", txHash: usdDeliveries.find(after)?.tx,
            title: `${fmt(order.amountOut)} $ delivered to the recipient's account at Bank B`,
            detail: "the protocol delivered the pool's deposit as a system transaction; wrapped $ minted",
          });
          return outcome;
        }
      }
      if (outcome.refunded) {
        const balance = await ledgerBalanceA(order.user);
        trace(`payer € at Bank A: ${balance} (before ${order.userEurBefore}, expecting +${order.amountIn})`);
        if (balance >= order.userEurBefore + order.amountIn) {
          mark({
            seq: 9, zone: "A", actor: "Protocol", status: "done", txHash: eurRefunds.find(after)?.tx,
            title: `Refund delivered - ${fmt(order.amountIn)} € back in your account at Bank A`,
            detail: "the protocol delivered the pool's refund deposit as a system transaction",
          });
          return outcome;
        }
      }
    }

    await new Promise((resolve) => setTimeout(resolve, options.pollMs ?? 1_000));
  }
  throw new Error(`timed out following payment order #${order.requestId} (${user})`);
}
