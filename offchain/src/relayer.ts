import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeFunctionData,
  http,
  nonceManager as defaultNonceManager,
  parseAbi,
  parseAbiItem,
  parseEventLogs,
  serializeSignature,
  toFunctionSelector,
  toHex,
  zeroHash,
  type Address,
  type Chain,
  type Hex,
  type Log,
  type NonceManager,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount, sign } from "viem/accounts";
import { getProof, root } from "./merkle.js";
import { decodeDomainMessage, hashDomainMessage, type DomainMessage, type MessageContext } from "./message.js";
import { DOMAIN_MESSAGE_RECORDED_EVENT, parseFinalizedBatches, type FinalizedBatch } from "./prover.js";
import { sequenceTransaction, type NonceManagerLike } from "./sequence.js";

/**
 * Off-chain service that moves domain state and domain-origin messages onto the L1.
 *
 * The domain protocol delivers L1 -> domain messages by itself, but nothing on the domain
 * side can reach the L1 without an actor that holds keys: the spoke operator must finalize
 * the pending domain-origin messages into an anchor, domain validators must sign the state
 * transition that carries the anchor onto the hub, and someone must prove every finalized
 * message to `DomainHub.relayDomainMessage` (which executes L1 callbacks and forwards
 * domain -> domain messages). This service does all three for each configured domain:
 *
 *   1. index `DomainMessageRecorded` events from the spoke, in recording order;
 *   2. when the spoke holds pending messages, sequence `finalizeDomainMessages()` from the
 *      operator through the hub and cut the batch at the finalize transaction's position;
 *   3. attest the latest finalized domain header (`monad_getDomainHeader`) onto the hub
 *      with the batch anchor, or with a zero anchor on a timer so the commitment keeps
 *      advancing while the domain is idle;
 *   4. prove and relay every finalized message whose anchor the hub has recorded.
 *
 * Batches are reconstructed from on-chain state rather than persisted: the spoke's pending
 * list is append-only until a finalize clears it, so every batch is a contiguous run of the
 * recorded messages. Already attested batches are recognised by matching prefix roots
 * against `hub.domainAnchors`; a batch finalized but not yet attested (service restarted in
 * between) is recovered by locating the operator's finalize transactions in the domain
 * receipts of the blocks that sequenced something. A spoke that emits
 * `DomainMessagesFinalized` (newer deployments) short-circuits all of this.
 *
 * Every step is idempotent against on-chain state, so the service can be restarted at any
 * time.
 */
export interface RelayerDomainConfig {
  chainId: bigint;
  /** The DomainSpoke on this domain. */
  spoke: Address;
  /** Domain JSON-RPC endpoint. Default `${l1RpcUrl}/domain/${chainId}`. */
  domainRpcUrl?: string;
  /** Key of the spoke `OPERATOR`; signs and sequences `finalizeDomainMessages` through the hub. */
  operatorKey: Hex;
  /** Keys of the registered validators this service signs state transitions with. */
  validatorKeys: Hex[];
  /** Domain viewing public key; encrypts the sequenced finalize transaction when set. */
  viewingKey?: Hex;
  /**
   * First block to index spoke events from (domain blocks mirror L1 heights, so this is
   * normally the L1 block the domain was registered in). Default: the head at startup
   * minus `DEFAULT_LOOKBACK` blocks.
   */
  startBlock?: bigint;
}

export interface RelayerConfig {
  l1RpcUrl: string;
  /** The DomainHub on the L1. */
  hub: Address;
  /** L1 account that pays for `submitStateSignature` and `relayDomainMessage`. */
  submitterKey: Hex;
  domains: RelayerDomainConfig[];
  /** Delay between passes over the domains. Default 2000 ms. */
  pollIntervalMs?: number;
  /** Attest the latest domain header even when nothing was finalized. Default 60000 ms, 0 disables. */
  attestIntervalMs?: number;
  /** How long to wait for the sequenced finalize transaction to execute. Default 120000 ms. */
  finalizeTimeoutMs?: number;
  /**
   * How long one pass waits for a batch's finalize block to become finalized before
   * attesting it, instead of leaving the attestation to a later pass. Default 5000 ms.
   */
  finalityWaitMs?: number;
  /** `msg.value` forwarded to the operator with the sequenced finalize transaction. Default 0. */
  sequencingFee?: bigint;
  /** Largest `eth_getLogs` block range the RPC accepts. Default 1000. */
  logRange?: bigint;
  /** Nonce manager for the submitter and operator keys; share it with other senders of the same keys. */
  nonceManager?: NonceManagerLike;
  log?: (line: string) => void;
}

/** Snapshot of what the service knows about one domain, for tests and status output. */
export interface DomainRelayerStatus {
  chainId: bigint;
  spoke: Address;
  scannedThrough: bigint | null;
  recorded: number;
  batches: number;
  anchored: number;
  relayed: number;
  lastAttestedAt: number | null;
  lastError: string | null;
}

export const HUB_ABI = parseAbi([
  "function domainBlockNumbers(uint64 domainChainId) view returns (uint64)",
  "function domainAnchors(uint64 domainChainId, bytes32 anchor) view returns (bool)",
  "function stateTransitionDigest(uint64 domainChainId, uint64 domainBlockNumber, bytes32 newStateRoot, bytes32 domainAnchor) view returns (bytes32)",
  "function hasVotedFor(bytes32 digest, address validator) view returns (bool)",
  "function submitStateSignature(uint64 domainChainId, uint64 domainBlockNumber, bytes32 newStateRoot, bytes32 domainAnchor, bytes signature)",
  "function relayedDomainMessages(uint64 domainChainId, bytes32 messageHash) view returns (bool)",
  "function relayDomainMessage((uint64 sourceChainId, uint64 destinationChainId, address from, address to, uint256 sourceNonce, bytes data) message, bytes32 anchor, bytes32[] proof) returns (bool)",
  "event StateSignatureSubmitted(uint64 indexed domainChainId, address indexed validator, uint64 domainBlockNumber, bytes32 newStateRoot, bytes32 domainAnchor, uint256 votes)",
  "event DomainStateUpdated(uint64 indexed domainChainId, uint256 stateNonce, uint64 domainBlockNumber, bytes32 newStateRoot, bytes32 domainAnchor)",
  "event DomainMessageRelayed(uint64 indexed domainChainId, bytes32 indexed messageHash, address indexed from, address to, uint256 nonce, bool success)",
  "event DomainMessageRouted(bytes32 indexed messageId, uint64 indexed sourceChainId, uint64 indexed destinationChainId, uint256 deliveryNonce)",
  "event DomainTransactionSequenced(uint64 indexed domainChainId, bytes rlpTx, uint256 fee)",
]);

export const SPOKE_ABI = parseAbi([
  "function getPendingDomainMessages() view returns (bytes32[])",
  "function finalizeDomainMessages() returns (bytes32)",
]);

export const DOMAIN_TRANSACTION_SEQUENCED_EVENT = parseAbiItem(
  "event DomainTransactionSequenced(uint64 indexed domainChainId, bytes rlpTx, uint256 fee)",
);

const FINALIZE_SELECTOR = toFunctionSelector("finalizeDomainMessages()");

/** Gas stamped on the sequenced finalize transaction; a batch of hundreds of leaves fits. */
const FINALIZE_GAS = 1_000_000n;

/** Blocks indexed before the head when no `startBlock` is configured. */
export const DEFAULT_LOOKBACK = 10_000n;

/**
 * Blocks re-scanned on every pass. Monad executes a block shortly after it is voted, so a
 * log query that reaches the head can answer before the newest blocks have execution
 * results; re-reading a tail window (events are de-duplicated by id) closes that gap.
 */
export const SCAN_OVERLAP = 32n;

/** Header the domain route returns from `monad_getDomainHeader`. */
export interface DomainHeader {
  /** L1 height the header was committed at: the block number to attest. */
  number: bigint;
  stateRoot: Hex;
  parentHash: Hex;
  timestamp: bigint;
}

/**
 * Reads the domain's latest committed header as of `block` from the domain RPC route.
 * Returns null while the domain has never executed a transaction. `latest` is the latest
 * proposed L1 block; attestations use `finalized`, because the execution client validates a
 * `DomainStateUpdated` event against the finalized domain root at the attested block and can
 * only do so once that block is finalized on its side.
 */
export async function getDomainHeader(
  domain: PublicClient,
  block: "latest" | "finalized" | bigint = "latest",
): Promise<DomainHeader | null> {
  const raw = (await domain.request({
    method: "monad_getDomainHeader" as never,
    params: [typeof block === "bigint" ? toHex(block) : block] as never,
  })) as { number: Hex; stateRoot: Hex; parentHash: Hex; timestamp: Hex } | null;
  if (!raw) return null;
  return {
    number: BigInt(raw.number),
    stateRoot: raw.stateRoot,
    parentHash: raw.parentHash,
    timestamp: BigInt(raw.timestamp),
  };
}

/** A domain-origin message as the spoke recorded it, with its position in the domain. */
export interface IndexedMessage {
  message: DomainMessage;
  messageHash: Hex;
  blockNumber: bigint;
  transactionIndex: number;
  logIndex: number;
}

/** Position of a successful `finalizeDomainMessages` execution. */
export interface FinalizePoint {
  blockNumber: bigint;
  transactionIndex: number;
}

/** A batch the operator anchored, in order, and what the service has done with it. */
export interface Batch extends FinalizedBatch {
  /** Index of the first leaf within the ordered message list. */
  start: number;
}

/** True if `message` executed before the finalize at `point` (same block: by transaction order). */
export function recordedBefore(message: { blockNumber: bigint; transactionIndex: number }, point: FinalizePoint): boolean {
  if (message.blockNumber !== point.blockNumber) return message.blockNumber < point.blockNumber;
  return message.transactionIndex < point.transactionIndex;
}

/**
 * Cuts the ordered, not yet batched messages `region` at every finalize point, in order.
 * Returns the batches (empty cuts are skipped) and how many leading messages they consume.
 */
export function partitionByFinalizePoints(
  region: readonly IndexedMessage[],
  points: readonly FinalizePoint[],
  start = 0,
): { batches: Batch[]; consumed: number } {
  const sorted = [...points].sort((a, b) =>
    a.blockNumber === b.blockNumber ? a.transactionIndex - b.transactionIndex : a.blockNumber < b.blockNumber ? -1 : 1,
  );
  const batches: Batch[] = [];
  let consumed = 0;
  for (const point of sorted) {
    let end = consumed;
    while (end < region.length && recordedBefore(region[end]!, point)) end++;
    if (end === consumed) continue;
    const leaves = region.slice(consumed, end).map((m) => m.messageHash);
    batches.push({
      anchor: root(leaves),
      leaves,
      blockNumber: point.blockNumber,
      logIndex: point.transactionIndex,
      start: start + consumed,
    });
    consumed = end;
  }
  return { batches, consumed };
}

function positionOf(a: { blockNumber: bigint; logIndex: number }, b: { blockNumber: bigint; logIndex: number }): number {
  return a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1;
}

interface DomainState {
  config: RelayerDomainConfig;
  domainRpcUrl: string;
  domain: PublicClient;
  operator: Address;
  scannedThrough: bigint | null;
  /** Every recorded message, in recording order. */
  messages: IndexedMessage[];
  byHash: Map<Hex, number>;
  /** Batches in order; `batches[i].start + leaves.length === batches[i+1].start`. */
  batches: Batch[];
  /** Messages consumed by `batches`. */
  batched: number;
  /** Finalize executions this service observed (its own receipts or recovered ones). */
  finalizePoints: FinalizePoint[];
  /** Anchors the hub is known to have recorded. */
  anchored: Set<Hex>;
  relayed: Set<Hex>;
  lastAttestedAt: number | null;
  lastError: string | null;
}

export class DomainRelayer {
  private readonly config: RelayerConfig;
  private readonly log: (line: string) => void;
  private readonly submitter;
  private readonly domains: DomainState[];
  private l1!: PublicClient;
  private wallet!: WalletClient;
  private l1Chain!: Chain;
  private context!: MessageContext;
  private running = false;
  private stopped: Promise<void> = Promise.resolve();

  constructor(config: RelayerConfig) {
    if (config.domains.length === 0) throw new Error("relayer: no domains configured");
    this.config = config;
    this.log = config.log ?? ((line) => console.log(line));
    this.submitter = privateKeyToAccount(config.submitterKey, {
      nonceManager: (config.nonceManager ?? defaultNonceManager) as NonceManager,
    });
    this.domains = config.domains.map((domainConfig) => {
      if (domainConfig.validatorKeys.length === 0) {
        throw new Error(`relayer: domain ${domainConfig.chainId} has no validator keys`);
      }
      const domainRpcUrl = domainConfig.domainRpcUrl ?? `${config.l1RpcUrl}/domain/${domainConfig.chainId}`;
      const chain = defineChain({
        id: Number(domainConfig.chainId),
        name: `domain-${domainConfig.chainId}`,
        nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
        rpcUrls: { default: { http: [domainRpcUrl] } },
      });
      return {
        config: domainConfig,
        domainRpcUrl,
        domain: createPublicClient({ chain, transport: http(domainRpcUrl) }),
        operator: privateKeyToAccount(domainConfig.operatorKey).address,
        scannedThrough: null,
        messages: [],
        byHash: new Map(),
        batches: [],
        batched: 0,
        finalizePoints: [],
        anchored: new Set(),
        relayed: new Set(),
        lastAttestedAt: null,
        lastError: null,
      };
    });
  }

  /** Current indexing and relay counters per domain. */
  status(): DomainRelayerStatus[] {
    return this.domains.map((d) => ({
      chainId: d.config.chainId,
      spoke: d.config.spoke,
      scannedThrough: d.scannedThrough,
      recorded: d.messages.length,
      batches: d.batches.length,
      anchored: d.batches.filter((b) => d.anchored.has(b.anchor)).length,
      relayed: d.relayed.size,
      lastAttestedAt: d.lastAttestedAt,
      lastError: d.lastError,
    }));
  }

  /** Runs passes over every domain until `stop()` is called. Resolves once the loop exits. */
  async start(): Promise<void> {
    if (this.running) throw new Error("relayer: already running");
    this.running = true;
    this.stopped = this.loop();
    return this.stopped;
  }

  /** Asks the loop to exit after the current pass. Resolves once it has. */
  async stop(): Promise<void> {
    this.running = false;
    await this.stopped;
  }

  private async loop(): Promise<void> {
    await this.connect();
    const interval = this.config.pollIntervalMs ?? 2_000;
    while (this.running) {
      await this.tick();
      const deadline = Date.now() + interval;
      while (this.running && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, Math.min(250, Math.max(0, deadline - Date.now()))));
      }
    }
  }

  private async connect(): Promise<void> {
    if (this.l1) return;
    const probe = createPublicClient({ transport: http(this.config.l1RpcUrl) });
    const l1ChainId = await probe.getChainId();
    this.l1Chain = defineChain({
      id: l1ChainId,
      name: `l1-${l1ChainId}`,
      nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
      rpcUrls: { default: { http: [this.config.l1RpcUrl] } },
    });
    this.l1 = createPublicClient({ chain: this.l1Chain, transport: http(this.config.l1RpcUrl) });
    this.wallet = createWalletClient({ account: this.submitter, chain: this.l1Chain, transport: http(this.config.l1RpcUrl) });
    this.context = { l1ChainId: BigInt(l1ChainId), hub: this.config.hub };
    this.log(`relayer: hub ${this.config.hub} on L1 ${l1ChainId}, submitter ${this.submitter.address}`);
    for (const d of this.domains) {
      const validators = d.config.validatorKeys.map((key) => privateKeyToAccount(key).address);
      this.log(
        `relayer: domain ${d.config.chainId} spoke ${d.config.spoke} via ${d.domainRpcUrl}, operator ${d.operator}, ` +
          `validators ${validators.join(",")}${d.config.viewingKey ? ", encrypted sequencing" : ""}`,
      );
    }
  }

  /** One pass over every domain. Failures are logged and retried on the next pass. */
  async tick(): Promise<void> {
    await this.connect();
    for (const d of this.domains) {
      try {
        await this.scan(d);
        await this.reconcile(d);
        await this.finalizePending(d);
        await this.attestBatches(d);
        await this.attestOnTimer(d);
        await this.relayBatches(d);
        d.lastError = null;
      } catch (error) {
        d.lastError = error instanceof Error ? error.message : String(error);
        this.log(`relayer[${d.config.chainId}]: pass failed: ${d.lastError}`);
      }
    }
  }

  // ---------------------------------------------------------------------
  // Indexing
  // ---------------------------------------------------------------------

  /**
   * Indexes spoke events up to the finalized domain head, a log window at a time, re-reading
   * the last `SCAN_OVERLAP` blocks of the previous pass.
   */
  private async scan(d: DomainState): Promise<void> {
    const latest = (await d.domain.getBlock({ blockTag: "finalized" })).number;
    const range = this.config.logRange ?? 1000n;
    let next: bigint;
    if (d.scannedThrough === null) {
      next = d.config.startBlock ?? (latest > DEFAULT_LOOKBACK ? latest - DEFAULT_LOOKBACK : 0n);
      if (d.config.startBlock === undefined) {
        this.log(`relayer[${d.config.chainId}]: no start block configured, indexing from ${next}`);
      }
    } else {
      next = d.scannedThrough + 1n > SCAN_OVERLAP ? d.scannedThrough + 1n - SCAN_OVERLAP : 0n;
      if (d.config.startBlock !== undefined && next < d.config.startBlock) next = d.config.startBlock;
    }
    while (next <= latest) {
      const to = next + range - 1n < latest ? next + range - 1n : latest;
      const logs = await d.domain.getLogs({ address: d.config.spoke, fromBlock: next, toBlock: to });
      this.index(d, logs);
      if (d.scannedThrough === null || to > d.scannedThrough) d.scannedThrough = to;
      next = to + 1n;
    }
  }

  private index(d: DomainState, logs: Log[]): void {
    const recorded = parseEventLogs({ abi: [DOMAIN_MESSAGE_RECORDED_EVENT], logs });
    const fresh: IndexedMessage[] = [];
    for (const log of recorded) {
      const { messageId, message: encoded } = log.args;
      if (!messageId || encoded === undefined || log.blockNumber === null || log.logIndex === null) continue;
      if (d.byHash.has(messageId)) continue;
      let message: DomainMessage;
      try {
        message = decodeDomainMessage(encoded);
      } catch {
        this.log(`relayer[${d.config.chainId}]: ignoring undecodable envelope ${messageId}`);
        continue;
      }
      if (hashDomainMessage(message, this.context).toLowerCase() !== messageId.toLowerCase()) {
        this.log(`relayer[${d.config.chainId}]: ignoring event whose id does not match its envelope (${messageId})`);
        continue;
      }
      fresh.push({
        message,
        messageHash: messageId,
        blockNumber: log.blockNumber,
        transactionIndex: log.transactionIndex ?? 0,
        logIndex: log.logIndex,
      });
    }
    fresh.sort(positionOf);
    for (const m of fresh) {
      const last = d.messages.at(-1);
      if (last && positionOf(last, m) >= 0) {
        throw new Error(`relayer: out-of-order message ${m.messageHash} at block ${m.blockNumber}`);
      }
      d.byHash.set(m.messageHash, d.messages.length);
      d.messages.push(m);
    }
    // A spoke that emits the finalize event tells us the exact cut; record it as a point so
    // the partition below is driven by the same machinery.
    for (const batch of parseFinalizedBatches(logs, d.config.spoke)) {
      this.addFinalizePoint(d, { blockNumber: batch.blockNumber, transactionIndex: this.txIndexOf(logs, batch) });
    }
  }

  private txIndexOf(logs: Log[], batch: FinalizedBatch): number {
    const log = logs.find((l) => l.blockNumber === batch.blockNumber && l.logIndex === batch.logIndex);
    return log?.transactionIndex ?? Number.MAX_SAFE_INTEGER;
  }

  private addFinalizePoint(d: DomainState, point: FinalizePoint): void {
    if (d.finalizePoints.some((p) => p.blockNumber === point.blockNumber && p.transactionIndex === point.transactionIndex)) return;
    d.finalizePoints.push(point);
  }

  // ---------------------------------------------------------------------
  // Batch reconstruction
  // ---------------------------------------------------------------------

  /**
   * Assigns indexed messages to batches: first by matching prefix roots against the
   * anchors the hub has recorded, then by the finalize executions the service knows about,
   * recovering those from domain receipts when a finalize happened before the service
   * started. Messages the spoke still reports as pending are never batched.
   */
  private async reconcile(d: DomainState): Promise<void> {
    if (d.scannedThrough === null) return;
    const pending = await d.domain.readContract({
      address: d.config.spoke,
      abi: SPOKE_ABI,
      functionName: "getPendingDomainMessages",
      blockNumber: d.scannedThrough,
    });
    const nonPending = d.messages.length - pending.length;
    if (nonPending < d.batched) {
      throw new Error(`spoke reports ${pending.length} pending messages but only ${d.messages.length - d.batched} are unbatched`);
    }
    for (let i = 0; i < pending.length; i++) {
      const indexed = d.messages[nonPending + i];
      if (!indexed || indexed.messageHash.toLowerCase() !== pending[i]!.toLowerCase()) {
        throw new Error(`pending message ${pending[i]} is not the indexed message at position ${nonPending + i}`);
      }
    }
    if (d.batched === nonPending) return;

    // 1. Batches the hub already knows: the shortest unbatched prefix whose root is an anchor.
    while (d.batched < nonPending) {
      const region = d.messages.slice(d.batched, nonPending);
      let found = false;
      for (let k = 1; k <= region.length; k++) {
        const leaves = region.slice(0, k).map((m) => m.messageHash);
        const anchor = root(leaves);
        if (!(await this.isAnchorRecorded(d, anchor))) continue;
        const last = region[k - 1]!;
        this.pushBatch(d, { anchor, leaves, blockNumber: last.blockNumber, logIndex: last.logIndex, start: d.batched });
        this.log(`relayer[${d.config.chainId}]: recognised anchored batch ${anchor} (${k} messages)`);
        found = true;
        break;
      }
      if (!found) break;
    }
    if (d.batched === nonPending) return;

    // 2. Batches finalized but not attested yet: cut at the operator's finalize executions.
    const region = d.messages.slice(d.batched, nonPending);
    const first = region[0]!;
    let { batches, consumed } = partitionByFinalizePoints(region, d.finalizePoints, d.batched);
    if (consumed < region.length) {
      const recovered = await this.recoverFinalizePoints(d, first.blockNumber, d.scannedThrough);
      for (const point of recovered) this.addFinalizePoint(d, point);
      ({ batches, consumed } = partitionByFinalizePoints(region, d.finalizePoints, d.batched));
    }
    for (const batch of batches) {
      this.pushBatch(d, batch);
      this.log(`relayer[${d.config.chainId}]: reconstructed batch ${batch.anchor} (${batch.leaves.length} messages, domain block ${batch.blockNumber})`);
    }
    if (consumed < region.length) {
      throw new Error(`${region.length - consumed} finalized message(s) could not be assigned to a batch`);
    }
  }

  private pushBatch(d: DomainState, batch: Batch): void {
    if (batch.start !== d.batched) throw new Error(`relayer: batch starts at ${batch.start}, expected ${d.batched}`);
    d.batches.push(batch);
    d.batched += batch.leaves.length;
  }

  /**
   * Finds every successful `finalizeDomainMessages` execution by the operator between
   * `from` and `to`: the hub's `DomainTransactionSequenced` events name the blocks that
   * executed sequenced transactions, and the domain route serves each block's receipts.
   */
  private async recoverFinalizePoints(d: DomainState, from: bigint, to: bigint): Promise<FinalizePoint[]> {
    const range = this.config.logRange ?? 1000n;
    const blocks = new Set<bigint>();
    for (let next = from; next <= to; next += range) {
      const end = next + range - 1n < to ? next + range - 1n : to;
      const logs = await this.l1.getLogs({
        address: this.config.hub,
        event: DOMAIN_TRANSACTION_SEQUENCED_EVENT,
        args: { domainChainId: d.config.chainId },
        fromBlock: next,
        toBlock: end,
      });
      for (const log of logs) if (log.blockNumber !== null) blocks.add(log.blockNumber);
    }
    const points: FinalizePoint[] = [];
    for (const block of [...blocks].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))) {
      const receipts = (await d.domain.request({
        method: "eth_getBlockReceipts" as never,
        params: [toHex(block)] as never,
      })) as { status: Hex; from: Address; to: Address | null; transactionHash: Hex; transactionIndex: Hex }[] | null;
      for (const receipt of receipts ?? []) {
        if (receipt.status !== "0x1" || !receipt.to) continue;
        if (receipt.from.toLowerCase() !== d.operator.toLowerCase()) continue;
        if (receipt.to.toLowerCase() !== d.config.spoke.toLowerCase()) continue;
        const tx = await d.domain.getTransaction({ hash: receipt.transactionHash });
        if (!tx.input.toLowerCase().startsWith(FINALIZE_SELECTOR)) continue;
        points.push({ blockNumber: block, transactionIndex: Number(receipt.transactionIndex) });
      }
    }
    if (points.length > 0) {
      this.log(`relayer[${d.config.chainId}]: recovered ${points.length} finalize execution(s) between blocks ${from} and ${to}`);
    }
    return points;
  }

  // ---------------------------------------------------------------------
  // Finalize
  // ---------------------------------------------------------------------

  /** Sequences `finalizeDomainMessages()` whenever the spoke holds pending messages. */
  private async finalizePending(d: DomainState): Promise<void> {
    const pending = await d.domain.readContract({
      address: d.config.spoke,
      abi: SPOKE_ABI,
      functionName: "getPendingDomainMessages",
    });
    if (pending.length === 0) return;
    this.log(`relayer[${d.config.chainId}]: finalizing ${pending.length} pending message(s)`);

    const sequenced = await sequenceTransaction({
      l1RpcUrl: this.config.l1RpcUrl,
      hub: this.config.hub,
      domainChainId: d.config.chainId,
      senderKey: d.config.operatorKey,
      to: d.config.spoke,
      data: encodeFunctionData({ abi: SPOKE_ABI, functionName: "finalizeDomainMessages" }),
      gas: FINALIZE_GAS,
      domainRpcUrl: d.domainRpcUrl,
      sequencingFee: this.config.sequencingFee,
      viewingKey: d.config.viewingKey,
      nonceManager: this.config.nonceManager,
    });

    const deadline = Date.now() + (this.config.finalizeTimeoutMs ?? 120_000);
    let receipt: Awaited<ReturnType<PublicClient["getTransactionReceipt"]>> | null = null;
    while (receipt === null) {
      receipt = await d.domain.getTransactionReceipt({ hash: sequenced.domainTxHash }).catch(() => null);
      if (receipt !== null) break;
      if (Date.now() > deadline) {
        throw new Error(`finalize ${sequenced.domainTxHash} (L1 ${sequenced.l1TxHash}) was not executed in time`);
      }
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    if (receipt.status !== "success") {
      throw new Error(`finalize ${sequenced.domainTxHash} reverted on the domain`);
    }
    this.addFinalizePoint(d, { blockNumber: receipt.blockNumber, transactionIndex: receipt.transactionIndex });
    this.log(`relayer[${d.config.chainId}]: finalize executed at domain block ${receipt.blockNumber} (tx ${sequenced.domainTxHash})`);
    // Index through the finalize block and cut the batch right away.
    await this.scan(d);
    await this.reconcile(d);
  }

  // ---------------------------------------------------------------------
  // Attest
  // ---------------------------------------------------------------------

  /** Attests every known batch whose anchor the hub does not have yet, in order. */
  private async attestBatches(d: DomainState): Promise<void> {
    for (const batch of d.batches) {
      if (await this.isAnchorRecorded(d, batch.anchor)) continue;
      if (!(await this.attest(d, batch.anchor, batch.blockNumber))) return;
    }
  }

  /** Keeps the state commitment moving while the domain records no messages. */
  private async attestOnTimer(d: DomainState): Promise<void> {
    const interval = this.config.attestIntervalMs ?? 60_000;
    if (interval <= 0) return;
    if (d.lastAttestedAt !== null && Date.now() - d.lastAttestedAt < interval) return;
    for (const batch of d.batches) {
      if (!d.anchored.has(batch.anchor)) return; // never spend a header on a zero anchor while a batch waits
    }
    await this.attest(d, zeroHash, 0n);
  }

  private async isAnchorRecorded(d: DomainState, anchor: Hex): Promise<boolean> {
    if (d.anchored.has(anchor)) return true;
    const recorded = await this.l1.readContract({
      address: this.config.hub,
      abi: HUB_ABI,
      functionName: "domainAnchors",
      args: [d.config.chainId, anchor],
    });
    if (recorded) d.anchored.add(anchor);
    return recorded;
  }

  /**
   * Submits each configured validator's signature over the latest finalized domain header
   * with `anchor`, until the hub reports the state advanced. The header must be at or after
   * `notBefore` (the block the batch was finalized in) and newer than the hub's commitment.
   * Returns false when there is no suitable header yet.
   */
  private async attest(d: DomainState, anchor: Hex, notBefore: bigint): Promise<boolean> {
    let header = await getDomainHeader(d.domain, "finalized");
    if (!header) {
      this.log(`relayer[${d.config.chainId}]: no domain header to attest yet`);
      return false;
    }
    if (header.number < notBefore) {
      // Finality is a couple of blocks away; wait for it here rather than one poll interval later.
      const deadline = Date.now() + (this.config.finalityWaitMs ?? 5_000);
      while (header.number < notBefore && Date.now() < deadline && this.running !== false) {
        await new Promise((resolve) => setTimeout(resolve, 300));
        header = (await getDomainHeader(d.domain, "finalized")) ?? header;
      }
      if (header.number < notBefore) {
        this.log(`relayer[${d.config.chainId}]: waiting for domain block ${notBefore} to finalize (at ${header.number})`);
        return false;
      }
    }
    const committed = await this.l1.readContract({
      address: this.config.hub,
      abi: HUB_ABI,
      functionName: "domainBlockNumbers",
      args: [d.config.chainId],
    });
    if (header.number <= committed) {
      if (anchor !== zeroHash) {
        this.log(`relayer[${d.config.chainId}]: batch ${anchor} needs a domain block after ${committed} (latest ${header.number})`);
      } else {
        d.lastAttestedAt = Date.now();
      }
      return false;
    }

    const digest = await this.l1.readContract({
      address: this.config.hub,
      abi: HUB_ABI,
      functionName: "stateTransitionDigest",
      args: [d.config.chainId, header.number, header.stateRoot, anchor],
    });
    let advanced = false;
    for (const key of d.config.validatorKeys) {
      const validator = privateKeyToAccount(key);
      const voted = await this.l1.readContract({
        address: this.config.hub,
        abi: HUB_ABI,
        functionName: "hasVotedFor",
        args: [digest, validator.address],
      });
      if (voted) continue;
      const signature = serializeSignature(await sign({ hash: digest, privateKey: key }));
      const txHash = await this.wallet.writeContract({
        account: this.submitter,
        chain: this.l1Chain,
        address: this.config.hub,
        abi: HUB_ABI,
        functionName: "submitStateSignature",
        args: [d.config.chainId, header.number, header.stateRoot, anchor, signature],
      });
      const receipt = await this.l1.waitForTransactionReceipt({ hash: txHash });
      if (receipt.status !== "success") {
        throw new Error(`submitStateSignature by ${validator.address} reverted (${txHash})`);
      }
      const [updated] = parseEventLogs({ abi: HUB_ABI, eventName: "DomainStateUpdated", logs: receipt.logs });
      const [vote] = parseEventLogs({ abi: HUB_ABI, eventName: "StateSignatureSubmitted", logs: receipt.logs });
      this.log(
        `relayer[${d.config.chainId}]: validator ${validator.address} signed block ${header.number} root ${header.stateRoot} ` +
          `anchor ${anchor} (votes ${vote?.args.votes ?? "?"}, L1 tx ${txHash})`,
      );
      if (updated) {
        advanced = true;
        break;
      }
    }
    d.lastAttestedAt = Date.now();
    if (advanced) {
      if (anchor !== zeroHash) d.anchored.add(anchor);
      this.log(`relayer[${d.config.chainId}]: hub advanced to domain block ${header.number}`);
    }
    return advanced;
  }

  // ---------------------------------------------------------------------
  // Relay
  // ---------------------------------------------------------------------

  /** Proves and relays every finalized message whose anchor the hub has recorded. */
  private async relayBatches(d: DomainState): Promise<void> {
    for (const batch of d.batches) {
      if (batch.leaves.every((leaf) => d.relayed.has(leaf))) continue;
      if (!(await this.isAnchorRecorded(d, batch.anchor))) continue;
      for (const [index, leaf] of batch.leaves.entries()) {
        if (d.relayed.has(leaf)) continue;
        const alreadyRelayed = await this.l1.readContract({
          address: this.config.hub,
          abi: HUB_ABI,
          functionName: "relayedDomainMessages",
          args: [d.config.chainId, leaf],
        });
        if (alreadyRelayed) {
          d.relayed.add(leaf);
          continue;
        }
        const position = d.byHash.get(leaf);
        if (position === undefined) {
          this.log(`relayer[${d.config.chainId}]: no preimage indexed for ${leaf}`);
          continue;
        }
        await this.relay(d, batch, index, d.messages[position]!);
      }
    }
  }

  private async relay(d: DomainState, batch: Batch, index: number, indexed: IndexedMessage): Promise<void> {
    const request = {
      account: this.submitter,
      chain: this.l1Chain,
      address: this.config.hub,
      abi: HUB_ABI,
      functionName: "relayDomainMessage",
      args: [indexed.message, batch.anchor, getProof(batch.leaves, index)],
    } as const;
    // A failed receiver call still returns successfully, so the estimate covers the real
    // path; the margin absorbs the 63/64 rule and state growth between estimate and inclusion.
    let gas: bigint;
    try {
      gas = ((await this.l1.estimateContractGas(request)) * 3n) / 2n + 100_000n;
    } catch {
      gas = 1_500_000n;
    }
    const txHash = await this.wallet.writeContract({ ...request, gas });
    const receipt = await this.l1.waitForTransactionReceipt({ hash: txHash });
    if (receipt.status !== "success") {
      this.log(`relayer[${d.config.chainId}]: relay of ${indexed.messageHash} reverted (${txHash})`);
      return;
    }
    d.relayed.add(indexed.messageHash);
    const { message } = indexed;
    const [relayed] = parseEventLogs({ abi: HUB_ABI, eventName: "DomainMessageRelayed", logs: receipt.logs });
    const [routed] = parseEventLogs({ abi: HUB_ABI, eventName: "DomainMessageRouted", logs: receipt.logs });
    const outcome = routed
      ? `queued for domain ${routed.args.destinationChainId} (delivery nonce ${routed.args.deliveryNonce})`
      : relayed?.args.success
        ? "delivered on the L1"
        : "delivered, receiver call failed (retryable via retryDomainMessage)";
    this.log(
      `relayer[${d.config.chainId}]: message ${indexed.messageHash} (${message.from} -> ${message.to} on ${message.destinationChainId}, ` +
        `nonce ${message.sourceNonce}) ${outcome} in L1 tx ${txHash}`,
    );
  }
}
