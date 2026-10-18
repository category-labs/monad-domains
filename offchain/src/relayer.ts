import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  nonceManager as defaultNonceManager,
  parseAbi,
  parseEventLogs,
  zeroHash,
  type Address,
  type Chain,
  type Hex,
  type NonceManager,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { attestCheckpoint, buildCheckpoint, domainMessageCountAt, getDomainHeader, HUB_CHECKPOINT_ABI } from "./checkpoint.js";
import { getProof } from "./merkle.js";
import type { DomainMessage, MessageContext } from "./message.js";
import {
  DEFAULT_MAX_LOG_RANGE,
  DOMAIN_STATE_UPDATED_EVENT,
  fetchDomainBatch,
  type DomainBatch,
  type RecordedMessage,
} from "./prover.js";
import type { NonceManagerLike } from "./sequence.js";

/**
 * Off-chain service that carries a domain's checkpoints and domain-origin messages onto the L1.
 *
 * The protocol delivers L1 -> domain messages by itself. The other direction needs the
 * domain's validators to sign checkpoints and someone to prove each message to the hub. For
 * every configured domain this service:
 *
 *   1. attests checkpoints. Once the L1 has finalized a new height on the domain's schedule
 *      (a multiple of its checkpoint interval), it signs the domain state root there together
 *      with the root of the messages recorded since the hub's previous checkpoint, with the
 *      configured validator keys, and submits the signatures (`buildCheckpoint` /
 *      `attestCheckpoint`). It attests as soon as messages wait, and otherwise every
 *      `attestIntervalMs` so the hub's commitment keeps following the domain;
 *   2. relays. It walks the hub's `DomainStateUpdated` events, rebuilds every attested batch
 *      from the spoke's events and state (`fetchDomainBatch`) and proves each message the hub
 *      has not seen yet to `relayDomainMessage`, which executes an L1 target or forwards the
 *      message to another domain.
 *
 * Every step is idempotent against on-chain state (`domainBlockNumbers`, `hasVotedFor`,
 * `relayedDomainMessages`), so the service can be restarted at any time. It attests the
 * latest finalized scheduled height, skipping missed ones, which suits a service that holds
 * the validator keys it submits for; validators that run independently of each other should
 * use `npm run checkpoint` instead, whose rule converges without coordination.
 */
export interface RelayerDomainConfig {
  chainId: bigint;
  /** The DomainSpoke on this domain. */
  spoke: Address;
  /** Domain JSON-RPC endpoint. Default `${l1RpcUrl}/domain/${chainId}`. */
  domainRpcUrl?: string;
  /** Keys of the registered validators this service signs checkpoints with. */
  validatorKeys: Hex[];
  /**
   * First L1 block to scan for the hub's attestations of this domain; at or before the
   * domain's first attestation, e.g. the block it was registered in. Default 0.
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
  /**
   * Attest the latest finalized scheduled height even when no message waits, once this long
   * has passed since the last attestation. Default 60000 ms; 0 attests only for messages.
   */
  attestIntervalMs?: number;
  /** Largest `eth_getLogs` block range the RPC accepts. Default `DEFAULT_MAX_LOG_RANGE`. */
  logRange?: bigint;
  /** Nonce manager for the submitter key; share it with other senders of the same key. */
  nonceManager?: NonceManagerLike;
  log?: (line: string) => void;
}

/** Snapshot of what the service knows about one domain, for tests and status output. */
export interface DomainRelayerStatus {
  chainId: bigint;
  spoke: Address;
  /** L1 block the hub's attestation events were scanned through. */
  scannedThrough: bigint | null;
  /** The hub's attested height for the domain, as last read. */
  attested: bigint | null;
  /** Attested batches that carried messages and are fully relayed. */
  batches: number;
  /** Messages in those batches. */
  recorded: number;
  relayed: number;
  lastAttestedAt: number | null;
  lastError: string | null;
}

export const RELAY_ABI = parseAbi([
  "function relayedDomainMessages(uint64 domainChainId, bytes32 messageHash) view returns (bool)",
  "function relayDomainMessage((uint64 sourceChainId, uint64 destinationChainId, address from, address to, uint256 sourceNonce, bytes data) message, bytes32 anchor, bytes32[] proof) returns (bool)",
  "event DomainMessageRelayed(uint64 indexed domainChainId, bytes32 indexed messageHash, address indexed from, address to, uint256 nonce, bool success)",
  "event DomainMessageRouted(bytes32 indexed messageId, uint64 indexed sourceChainId, uint64 indexed destinationChainId, uint256 deliveryNonce)",
]);

/** The largest scheduled height at or below `finalized`: the one this service attests. */
export function latestScheduledHeight(finalized: bigint, interval: bigint): bigint {
  if (interval <= 0n) throw new Error("relayer: interval must be positive");
  return (finalized / interval) * interval;
}

/** One `DomainStateUpdated` event of the hub. */
interface Attestation {
  stateNonce: bigint;
  height: bigint;
  anchor: Hex;
}

interface DomainState {
  config: RelayerDomainConfig;
  domainRpcUrl: string;
  domain: PublicClient;
  interval: bigint | null;
  scannedThrough: bigint | null;
  attested: bigint | null;
  /** The hub's attestations in state-nonce order, contiguous from the first one. */
  updates: Attestation[];
  /** State nonces whose batch is fully relayed (or empty). */
  done: Set<bigint>;
  batches: number;
  recorded: number;
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
        // Batching sends each page of `domainMessageIds` reads as one JSON-RPC request.
        domain: createPublicClient({ chain, transport: http(domainRpcUrl, { batch: true }) }),
        interval: null,
        scannedThrough: null,
        attested: null,
        updates: [],
        done: new Set(),
        batches: 0,
        recorded: 0,
        relayed: new Set(),
        lastAttestedAt: null,
        lastError: null,
      };
    });
  }

  /** Current attestation and relay counters per domain. */
  status(): DomainRelayerStatus[] {
    return this.domains.map((d) => ({
      chainId: d.config.chainId,
      spoke: d.config.spoke,
      scannedThrough: d.scannedThrough,
      attested: d.attested,
      batches: d.batches,
      recorded: d.recorded,
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
      this.log(`relayer: domain ${d.config.chainId} spoke ${d.config.spoke} via ${d.domainRpcUrl}, validators ${validators.join(",")}`);
    }
  }

  /** One pass over every domain. Failures are logged and retried on the next pass. */
  async tick(): Promise<void> {
    await this.connect();
    for (const d of this.domains) {
      try {
        await this.attest(d);
        await this.scanAttestations(d);
        await this.relayBatches(d);
        d.lastError = null;
      } catch (error) {
        d.lastError = error instanceof Error ? error.message : String(error);
        this.log(`relayer[${d.config.chainId}]: pass failed: ${d.lastError}`);
      }
    }
  }

  private async interval(d: DomainState): Promise<bigint> {
    if (d.interval !== null) return d.interval;
    const interval = BigInt(
      await this.l1.readContract({ address: this.config.hub, abi: HUB_CHECKPOINT_ABI, functionName: "checkpointIntervals", args: [d.config.chainId] }),
    );
    if (interval === 0n) throw new Error(`domain ${d.config.chainId} is not registered on hub ${this.config.hub}`);
    d.interval = interval;
    return interval;
  }

  // ---------------------------------------------------------------------
  // Attest
  // ---------------------------------------------------------------------

  /**
   * Attests the latest finalized scheduled height when it is above the hub's commitment and
   * either messages were recorded since that commitment or the heartbeat interval elapsed.
   */
  private async attest(d: DomainState): Promise<void> {
    const interval = await this.interval(d);
    const [committed, finalized] = await Promise.all([
      this.l1
        .readContract({ address: this.config.hub, abi: HUB_CHECKPOINT_ABI, functionName: "domainBlockNumbers", args: [d.config.chainId] })
        .then((n) => BigInt(n)),
      this.l1.getBlock({ blockTag: "finalized" }).then((block) => block.number),
    ]);
    d.attested = committed;
    const target = latestScheduledHeight(finalized, interval);
    if (target <= committed) return;

    const heartbeat = this.config.attestIntervalMs ?? 60_000;
    const due = heartbeat > 0 && (d.lastAttestedAt === null || Date.now() - d.lastAttestedAt >= heartbeat);
    if (!due) {
      const [before, now] = await Promise.all([
        committed === 0n ? Promise.resolve(0n) : domainMessageCountAt(d.domain, d.config.spoke, committed),
        domainMessageCountAt(d.domain, d.config.spoke, target),
      ]);
      if (now === before) return;
    }
    if ((await getDomainHeader(d.domain, target)) === null) {
      // Nothing has executed on the domain yet; there is no state root to attest.
      d.lastAttestedAt = Date.now();
      return;
    }

    const checkpoint = await buildCheckpoint({
      l1: this.l1,
      domain: d.domain,
      hub: this.config.hub,
      spoke: d.config.spoke,
      domainChainId: d.config.chainId,
      height: target,
    });
    const result = await attestCheckpoint({
      l1: this.l1,
      submitter: this.wallet,
      chain: this.l1Chain,
      hub: this.config.hub,
      checkpoint,
      validatorKeys: d.config.validatorKeys,
    });
    d.lastAttestedAt = Date.now();
    this.log(
      `relayer[${d.config.chainId}]: checkpoint ${target} root ${checkpoint.stateRoot} batch [${checkpoint.fromNonce}, ${checkpoint.toNonce}) ` +
        `anchor ${checkpoint.anchor}: ${result.submitted.length} signature(s) submitted, ` +
        (result.advanced ? "hub advanced" : "waiting for more validators"),
    );
    if (result.advanced) d.attested = target;
  }

  // ---------------------------------------------------------------------
  // Relay
  // ---------------------------------------------------------------------

  /**
   * Indexes the hub's `DomainStateUpdated` events for the domain up to the finalized L1
   * block, a log window at a time. Finalized blocks have their logs served completely, so no
   * window needs re-reading.
   */
  private async scanAttestations(d: DomainState): Promise<void> {
    const finalized = (await this.l1.getBlock({ blockTag: "finalized" })).number;
    const range = this.config.logRange ?? DEFAULT_MAX_LOG_RANGE;
    let next = d.scannedThrough === null ? (d.config.startBlock ?? 0n) : d.scannedThrough + 1n;
    const seen = new Set(d.updates.map((u) => u.stateNonce));
    while (next <= finalized) {
      const to = next + range - 1n < finalized ? next + range - 1n : finalized;
      const logs = await this.l1.getLogs({
        address: this.config.hub,
        event: DOMAIN_STATE_UPDATED_EVENT,
        args: { domainChainId: d.config.chainId },
        fromBlock: next,
        toBlock: to,
      });
      for (const log of logs) {
        const { stateNonce, domainBlockNumber, domainAnchor } = log.args;
        if (stateNonce === undefined || domainBlockNumber === undefined || domainAnchor === undefined) {
          throw new Error("incomplete DomainStateUpdated log");
        }
        if (seen.has(stateNonce)) continue;
        seen.add(stateNonce);
        d.updates.push({ stateNonce, height: BigInt(domainBlockNumber), anchor: domainAnchor });
      }
      d.scannedThrough = to;
      next = to + 1n;
    }
    d.updates.sort((a, b) => (a.stateNonce < b.stateNonce ? -1 : a.stateNonce > b.stateNonce ? 1 : 0));
  }

  /** Rebuilds every attested batch not yet fully relayed, in order, and relays its messages. */
  private async relayBatches(d: DomainState): Promise<void> {
    for (let i = 0; i < d.updates.length; i++) {
      const update = d.updates[i]!;
      if (d.done.has(update.stateNonce)) continue;
      if (i === 0 && update.stateNonce !== 0n) {
        throw new Error(
          `start block ${d.config.startBlock ?? 0n} is after the domain's first attestation (state nonce ${update.stateNonce}); ` +
            "configure it at or before the registration block",
        );
      }
      if (i > 0 && d.updates[i - 1]!.stateNonce !== update.stateNonce - 1n) {
        throw new Error(`attestation with state nonce ${update.stateNonce - 1n} is missing from the scan`);
      }
      if (update.anchor === zeroHash) {
        d.done.add(update.stateNonce);
        continue;
      }
      const previousHeight = i === 0 ? 0n : d.updates[i - 1]!.height;
      const fromNonce = i === 0 ? 0n : await domainMessageCountAt(d.domain, d.config.spoke, previousHeight);
      const toNonce = await domainMessageCountAt(d.domain, d.config.spoke, update.height);
      const batch: DomainBatch = { fromNonce, toNonce, fromBlock: previousHeight, toBlock: update.height, anchor: update.anchor };
      const messages = await fetchDomainBatch(d.domain, d.config.spoke, batch, this.context, {
        scanFromBlock: d.config.startBlock ?? 0n,
        maxLogRange: this.config.logRange ?? DEFAULT_MAX_LOG_RANGE,
      });
      let complete = true;
      for (const [index, recorded] of messages.entries()) {
        if (d.relayed.has(recorded.messageHash)) continue;
        const alreadyRelayed = await this.l1.readContract({
          address: this.config.hub,
          abi: RELAY_ABI,
          functionName: "relayedDomainMessages",
          args: [d.config.chainId, recorded.messageHash],
        });
        if (alreadyRelayed) {
          d.relayed.add(recorded.messageHash);
          continue;
        }
        if (!(await this.relay(d, batch, messages, index))) complete = false;
      }
      if (!complete) return;
      d.done.add(update.stateNonce);
      d.batches++;
      d.recorded += messages.length;
    }
  }

  private async relay(d: DomainState, batch: DomainBatch, messages: RecordedMessage<DomainMessage>[], index: number): Promise<boolean> {
    const recorded = messages[index]!;
    const leaves = messages.map((m) => m.messageHash);
    const request = {
      account: this.submitter,
      chain: this.l1Chain,
      address: this.config.hub,
      abi: RELAY_ABI,
      functionName: "relayDomainMessage",
      args: [recorded.message, batch.anchor!, getProof(leaves, index)],
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
      this.log(`relayer[${d.config.chainId}]: relay of ${recorded.messageHash} reverted (${txHash})`);
      return false;
    }
    d.relayed.add(recorded.messageHash);
    const { message } = recorded;
    const [relayed] = parseEventLogs({ abi: RELAY_ABI, eventName: "DomainMessageRelayed", logs: receipt.logs });
    const [routed] = parseEventLogs({ abi: RELAY_ABI, eventName: "DomainMessageRouted", logs: receipt.logs });
    const outcome = routed
      ? `queued for domain ${routed.args.destinationChainId} (delivery nonce ${routed.args.deliveryNonce})`
      : relayed?.args.success
        ? "delivered on the L1"
        : "delivered, receiver call failed (retryable via retryDomainMessage)";
    this.log(
      `relayer[${d.config.chainId}]: message ${recorded.messageHash} (${message.from} -> ${message.to} on ${message.destinationChainId}, ` +
        `nonce ${message.sourceNonce}) ${outcome} in L1 tx ${txHash}`,
    );
    return true;
  }
}
