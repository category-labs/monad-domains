import { parseAbiItem, type Address, type Hex, type PublicClient } from "viem";
import { batchRoot, domainBlockAt, domainMessageCountAt, fetchDomainMessageIds } from "./checkpoint.js";
import {
  decodeDomainMessage,
  domainDeliveryEnvelope,
  hashDomainMessage,
  hashMessage,
  type DomainMessage,
  type Message,
  type MessageContext,
  type MessagePlaintext,
} from "./message.js";
import { getProof, root } from "./merkle.js";

export const L1_MESSAGE_RECORDED_EVENT = parseAbiItem(
  "event L1MessageRecorded(uint64 indexed domainChainId, uint64 sourceChainId, address indexed from, address indexed to, bytes data, uint256 nonce, uint256 fee, bytes32 messageHash)",
);

export const ENCRYPTED_MESSAGE_RECORDED_EVENT = parseAbiItem(
  "event EncryptedMessageRecorded(uint64 indexed domainChainId, uint64 indexed sourceChainId, uint256 sourceNonce, bytes ciphertext, uint256 nonce, uint256 fee)",
);

export const DOMAIN_MESSAGE_RECORDED_EVENT = parseAbiItem(
  "event DomainMessageRecorded(bytes32 indexed messageId, bytes message)",
);

/** Emitted by the spoke for every protocol-delivered L1 -> domain message. */
export const L1_MESSAGE_RELAYED_EVENT = parseAbiItem(
  "event L1MessageRelayed(bytes32 indexed messageHash, uint64 sourceChainId, address indexed from, address indexed to, uint256 nonce, bool success)",
);

export const DOMAIN_MESSAGE_RELAYED_EVENT = parseAbiItem(
  "event DomainMessageRelayed(uint64 indexed sourceChainId, bytes32 indexed messageHash, address indexed from, address to, uint256 nonce, bool success)",
);

/** Emitted by the hub when it forwards a domain message; `deliveryNonce` is its nonce on the destination. */
export const DOMAIN_MESSAGE_ROUTED_EVENT = parseAbiItem(
  "event DomainMessageRouted(bytes32 indexed messageId, uint64 indexed sourceChainId, uint64 indexed destinationChainId, uint256 deliveryNonce)",
);

/** Emitted by the hub when a quorum attests a checkpoint; `domainAnchor` is that batch's root. */
export const DOMAIN_STATE_UPDATED_EVENT = parseAbiItem(
  "event DomainStateUpdated(uint64 indexed domainChainId, uint256 stateNonce, uint64 domainBlockNumber, bytes32 newBlockHash, bytes32 domainAnchor)",
);

const HUB_DELIVERY_ABI = [
  parseAbiItem("function relayedDomainMessages(uint64 sourceChainId, bytes32 messageHash) view returns (bool)"),
  parseAbiItem("function failedDomainMessages(uint64 sourceChainId, bytes32 messageHash) view returns (bool)"),
] as const;

const DOMAIN_ANCHOR_ABI = [
  parseAbiItem("function domainAnchors(uint64 domainChainId, bytes32 anchor) view returns (bool)"),
] as const;

/** A message as recorded on-chain, with the position metadata needed for batching. */
export interface RecordedMessage<T = Message> {
  message: T;
  messageHash: Hex;
  blockNumber: bigint;
  logIndex: number;
}

/** Proof arguments for DomainHub.relayDomainMessage; the message includes its source domain. */
export interface MessageProof<T = DomainMessage> {
  message: T;
  anchor: Hex;
  proof: Hex[];
}

function toRecorded(log: {
  args: { sourceChainId?: bigint; from?: Address; to?: Address; data?: Hex; nonce?: bigint; messageHash?: Hex };
  blockNumber: bigint;
  logIndex: number;
}): RecordedMessage {
  const { sourceChainId, from, to, data, nonce, messageHash } = log.args;
  if (sourceChainId === undefined || !from || !to || data === undefined || nonce === undefined || !messageHash) {
    throw new Error("prover: incomplete event log");
  }
  const message: Message = { sourceChainId, from, to, data, nonce };
  const computed = hashMessage(message);
  if (computed.toLowerCase() !== messageHash.toLowerCase()) {
    throw new Error(`prover: event messageHash mismatch (computed ${computed}, recorded ${messageHash})`);
  }
  return { message, messageHash, blockNumber: log.blockNumber, logIndex: log.logIndex };
}

function sortByPosition<T extends { blockNumber: bigint; logIndex: number }>(items: T[]): T[] {
  return items.sort((a, b) =>
    a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1,
  );
}

/**
 * Fetches all L1 -> domain messages recorded for `domainChainId` in the block
 * range, in recording order. This event stream is the protocol's derivation source:
 * the domain client injects one system delivery transaction per event, in this
 * order. No proofs exist in this direction — pair with `l1MessageDeliveryStatus` to
 * track a message through the spoke's delivery queue.
 */
export async function fetchL1Messages(
  client: PublicClient,
  domainChainId: bigint,
  range: { fromBlock: bigint; toBlock: bigint },
  hub: Address,
): Promise<RecordedMessage[]> {
  const logs = await client.getLogs({
    address: hub,
    event: L1_MESSAGE_RECORDED_EVENT,
    args: { domainChainId },
    ...range,
  });
  return sortByPosition(logs.map(toRecorded));
}

/**
 * Fetches every domain-origin message the spoke recorded in the block range, in log order,
 * with each envelope checked against its recorded id. L1 callbacks and domain destinations
 * share this stream. For proving, use `fetchDomainBatch`, which selects exactly the messages
 * one attestation anchored.
 */
export async function fetchDomainMessages(
  client: PublicClient,
  range: { fromBlock: bigint; toBlock: bigint },
  spoke: Address,
  context: MessageContext,
): Promise<RecordedMessage<DomainMessage>[]> {
  const logs = await client.getLogs({ address: spoke, event: DOMAIN_MESSAGE_RECORDED_EVENT, ...range });
  const messages = logs.map(log => {
    const { message: encoded, messageId } = log.args;
    if (encoded === undefined || messageId === undefined) throw new Error("prover: incomplete event log");
    const message = decodeDomainMessage(encoded);
    if (hashDomainMessage(message, context).toLowerCase() !== messageId.toLowerCase()) {
      throw new Error("prover: event messageId mismatch");
    }
    return { message, messageHash: messageId, blockNumber: log.blockNumber, logIndex: log.logIndex };
  });
  return sortByPosition(messages);
}

/**
 * The set of messages one attestation anchored: nonces in `[fromNonce, toNonce)`, recorded
 * after the previously attested L1 height `fromBlock` and up to the attested height `toBlock`.
 * On the domain's own chain, which is numbered by domain block, those are the blocks
 * `[firstDomainBlock, lastDomainBlock]`. Obtain it from `findBatchForNonce`.
 */
export interface DomainBatch {
  /** The hub's state nonce of the checkpoint that anchored the batch: its position in the domain's history. */
  stateNonce: bigint;
  fromNonce: bigint;
  toNonce: bigint;
  /** Previously attested L1 height; zero for the first batch. */
  fromBlock: bigint;
  /** Attested L1 height. */
  toBlock: bigint;
  /** First domain block after the previous checkpoint; zero for the first batch. */
  firstDomainBlock: bigint;
  /** The domain's latest block as of the attested height. */
  lastDomainBlock: bigint;
  /** The anchor the hub recorded, when known. */
  anchor?: Hex;
  /** L1 block the checkpoint's quorum was reached in, when known. */
  attestedInBlock?: bigint;
}

/** Largest block range one `eth_getLogs` call is sent for; wider scans are split. */
export const DEFAULT_MAX_LOG_RANGE = 1000n;

export interface BatchScanOptions {
  /** Block range per `eth_getLogs` call. Default `DEFAULT_MAX_LOG_RANGE`. */
  maxLogRange?: bigint;
  /** Lowest domain block worth scanning, e.g. the spoke's deployment block. Default 0. */
  scanFromBlock?: bigint;
  /** Ids read per spoke call when cross-checking against state. */
  idPageSize?: bigint;
}

/** Splits `[fromBlock, toBlock]` into ranges of at most `maxLogRange` blocks. */
function logRanges(fromBlock: bigint, toBlock: bigint, maxLogRange: bigint): { fromBlock: bigint; toBlock: bigint }[] {
  if (maxLogRange <= 0n) throw new Error("prover: maxLogRange must be positive");
  const ranges: { fromBlock: bigint; toBlock: bigint }[] = [];
  for (let start = fromBlock; start <= toBlock; start += maxLogRange) {
    const end = start + maxLogRange - 1n < toBlock ? start + maxLogRange - 1n : toBlock;
    ranges.push({ fromBlock: start, toBlock: end });
  }
  return ranges;
}

/**
 * Fetches the complete, nonce-ordered batch an attestation anchored. The envelopes come
 * from the spoke's events in domain blocks `[batch.firstDomainBlock, batch.lastDomainBlock]`,
 * scanned in chunks the RPC accepts; their nonces must cover `[fromNonce, toNonce)` exactly
 * and each id must equal the id the spoke stored for that nonce as of the attested height, so
 * a proof built from the result is a proof against the recorded anchor.
 */
export async function fetchDomainBatch(
  domain: PublicClient,
  spoke: Address,
  batch: DomainBatch,
  context: MessageContext,
  options: BatchScanOptions = {},
): Promise<RecordedMessage<DomainMessage>[]> {
  const expected = batch.toNonce - batch.fromNonce;
  if (expected <= 0n) return [];
  const { maxLogRange = DEFAULT_MAX_LOG_RANGE, scanFromBlock = 0n, idPageSize } = options;
  const firstBlock = batch.firstDomainBlock > scanFromBlock ? batch.firstDomainBlock : scanFromBlock;
  const recorded: RecordedMessage<DomainMessage>[] = [];
  for (const range of logRanges(firstBlock, batch.lastDomainBlock, maxLogRange)) {
    recorded.push(...(await fetchDomainMessages(domain, range, spoke, context)));
  }
  const inRange = recorded
    .filter((m) => m.message.sourceNonce >= batch.fromNonce && m.message.sourceNonce < batch.toNonce)
    .sort((a, b) => (a.message.sourceNonce < b.message.sourceNonce ? -1 : a.message.sourceNonce > b.message.sourceNonce ? 1 : 0));
  if (BigInt(inRange.length) !== expected) {
    throw new Error(`prover: batch [${batch.fromNonce}, ${batch.toNonce}) has ${inRange.length} events, expected ${expected}`);
  }
  const stateIds = await fetchDomainMessageIds(domain, spoke, batch.fromNonce, batch.toNonce, batch.lastDomainBlock, idPageSize);
  for (let i = 0; i < inRange.length; i++) {
    const nonce = batch.fromNonce + BigInt(i);
    if (inRange[i]!.message.sourceNonce !== nonce) {
      throw new Error(`prover: batch is missing nonce ${nonce}`);
    }
    if (inRange[i]!.messageHash.toLowerCase() !== stateIds[i]!.toLowerCase()) {
      throw new Error(`prover: event id for nonce ${nonce} differs from the spoke's stored id ${stateIds[i]}`);
    }
  }
  const eventRoot = batchRoot(inRange.map((m) => m.messageHash));
  if (batch.anchor && batch.anchor.toLowerCase() !== eventRoot.toLowerCase()) {
    throw new Error(`prover: batch root ${eventRoot} differs from the attested anchor ${batch.anchor}`);
  }
  return inRange;
}

/** One checkpoint the hub recorded: a `DomainStateUpdated` event. */
export interface Attestation {
  stateNonce: bigint;
  /** Attested L1 height. */
  height: bigint;
  anchor: Hex;
  /** L1 block the quorum was reached in. */
  blockNumber: bigint;
}

/**
 * Every checkpoint the hub recorded for `domainChainId` in `range` (L1 blocks, scanned in
 * chunks), in state nonce order.
 */
export async function fetchAttestations(
  l1: PublicClient,
  hub: Address,
  domainChainId: bigint,
  range: { fromBlock: bigint; toBlock: bigint },
  options: Pick<BatchScanOptions, "maxLogRange"> = {},
): Promise<Attestation[]> {
  const { maxLogRange = DEFAULT_MAX_LOG_RANGE } = options;
  const updates: Attestation[] = [];
  for (const chunk of logRanges(range.fromBlock, range.toBlock, maxLogRange)) {
    const logs = await l1.getLogs({ address: hub, event: DOMAIN_STATE_UPDATED_EVENT, args: { domainChainId }, ...chunk });
    for (const log of logs) {
      const { domainBlockNumber, domainAnchor, stateNonce } = log.args;
      if (domainBlockNumber === undefined || domainAnchor === undefined || stateNonce === undefined) {
        throw new Error("prover: incomplete event log");
      }
      updates.push({ stateNonce, height: BigInt(domainBlockNumber), anchor: domainAnchor, blockNumber: log.blockNumber });
    }
  }
  return updates.sort((a, b) => (a.stateNonce < b.stateNonce ? -1 : a.stateNonce > b.stateNonce ? 1 : 0));
}

/**
 * The batch each checkpoint in `range` anchored, in order: the hub's `DomainStateUpdated`
 * events give the attested heights, the hub's state at each height names the domain's latest
 * block there, and the spoke's message count at that block bounds the batch. A checkpoint
 * that recorded no message yields an empty batch.
 *
 * Batches are defined by consecutive checkpoints, so the scan either starts at or before the
 * domain's first attestation, or continues `after` the last batch of an earlier scan, with
 * `range` starting no later than the L1 block that batch's quorum was reached in.
 */
export async function fetchBatches(
  l1: PublicClient,
  domain: PublicClient,
  hub: Address,
  spoke: Address,
  domainChainId: bigint,
  range: { fromBlock: bigint; toBlock: bigint },
  options: Pick<BatchScanOptions, "maxLogRange"> & { after?: DomainBatch } = {},
): Promise<DomainBatch[]> {
  const { after } = options;
  const nextStateNonce = after ? after.stateNonce + 1n : 0n;
  const updates = (await fetchAttestations(l1, hub, domainChainId, range, options)).filter(
    (update) => update.stateNonce >= nextStateNonce,
  );
  if (updates.length > 0 && updates[0]!.stateNonce !== nextStateNonce) {
    throw new Error(
      `prover: scan range starts after the checkpoint with state nonce ${nextStateNonce} ` +
        `(first state nonce seen: ${updates[0]!.stateNonce})`,
    );
  }
  const batches: DomainBatch[] = [];
  let previousHeight = after ? after.toBlock : 0n;
  let previousCount = after ? after.toNonce : 0n;
  let firstDomainBlock = after ? after.lastDomainBlock + 1n : 0n;
  for (const update of updates) {
    const block = await domainBlockAt(l1, hub, domainChainId, update.height);
    if (!block) throw new Error(`prover: domain ${domainChainId} is not registered as of attested height ${update.height}`);
    const count = await domainMessageCountAt(domain, spoke, block.number);
    batches.push({
      stateNonce: update.stateNonce,
      fromNonce: previousCount,
      toNonce: count,
      fromBlock: previousHeight,
      toBlock: update.height,
      firstDomainBlock,
      lastDomainBlock: block.number,
      anchor: update.anchor,
      attestedInBlock: update.blockNumber,
    });
    previousHeight = update.height;
    previousCount = count;
    firstDomainBlock = block.number + 1n;
  }
  return batches;
}

/**
 * Locates the attested batch containing source nonce `nonce` among the checkpoints the hub
 * recorded for `domainChainId` in `range` (see `fetchBatches`). Null if no attestation covers
 * the nonce yet.
 */
export async function findBatchForNonce(
  l1: PublicClient,
  domain: PublicClient,
  hub: Address,
  spoke: Address,
  domainChainId: bigint,
  nonce: bigint,
  range: { fromBlock: bigint; toBlock: bigint },
  options: Pick<BatchScanOptions, "maxLogRange"> = {},
): Promise<DomainBatch | null> {
  const batches = await fetchBatches(l1, domain, hub, spoke, domainChainId, range, options);
  return batches.find((batch) => nonce >= batch.fromNonce && nonce < batch.toNonce) ?? null;
}

/**
 * Builds the anchor and merkle proof for one message within its batch. The batch must
 * be the complete, nonce-ordered set of messages one attestation anchored (see
 * `fetchDomainBatch`).
 */
export function proveMessage<T>(batch: readonly RecordedMessage<T>[], messageHash: Hex): MessageProof<T> {
  const leaves = batch.map((m) => m.messageHash);
  const index = leaves.findIndex((h) => h.toLowerCase() === messageHash.toLowerCase());
  if (index === -1) throw new Error(`prover: message ${messageHash} not in batch`);
  return {
    message: batch[index]!.message,
    anchor: root(leaves),
    proof: getProof(leaves, index),
  };
}

/** Where a recorded L1 -> domain message stands in the protocol's delivery queue. */
export type L1DeliveryStatus = "pending" | "delivered" | "failed";

export type DomainDeliveryStatus = "pending" | "queued" | "delivered" | "failed";

/**
 * Reads both hub relay flags at one block. For L1 destinations, "delivered" means the
 * callback succeeded. For domain destinations, "queued" means forwarded; check the
 * destination spoke separately for execution. A successful transaction can contain a failed callback.
 */
export async function domainMessageDeliveryStatus(
  client: PublicClient,
  message: DomainMessage,
  context: MessageContext,
): Promise<DomainDeliveryStatus> {
  const messageHash = hashDomainMessage(message, context);
  const hub = context.hub;
  const blockNumber = await client.getBlockNumber({ cacheTime: 0 });
  const [relayed, failed] = await Promise.all([
    client.readContract({
      address: hub,
      abi: HUB_DELIVERY_ABI,
      functionName: "relayedDomainMessages",
      args: [message.sourceChainId, messageHash],
      blockNumber,
    }),
    client.readContract({
      address: hub,
      abi: HUB_DELIVERY_ABI,
      functionName: "failedDomainMessages",
      args: [message.sourceChainId, messageHash],
      blockNumber,
    }),
  ]);
  return !relayed ? "pending" : failed ? "failed" : message.destinationChainId === context.l1ChainId ? "delivered" : "queued";
}

/**
 * Returns the latest delivery outcome the destination spoke recorded for a message. An absent
 * event means pending, even if the queue has advanced past the nonce. The spoke's events are
 * scanned from `scanFromBlock` (a domain block, default 0) in chunks the RPC accepts.
 */
export async function l1MessageDeliveryStatus(
  client: PublicClient,
  recorded: Pick<RecordedMessage, "messageHash">,
  spoke: Address,
  options: Pick<BatchScanOptions, "maxLogRange" | "scanFromBlock"> = {},
): Promise<L1DeliveryStatus> {
  const { maxLogRange = DEFAULT_MAX_LOG_RANGE, scanFromBlock = 0n } = options;
  const toBlock = await client.getBlockNumber({ cacheTime: 0 });
  const logs = [];
  for (const range of logRanges(scanFromBlock, toBlock, maxLogRange)) {
    logs.push(
      ...(await client.getLogs({
        address: spoke,
        event: L1_MESSAGE_RELAYED_EVENT,
        args: { messageHash: recorded.messageHash },
        ...range,
        strict: true,
      })),
    );
  }
  const latest = sortByPosition(logs).at(-1);
  return latest === undefined ? "pending" : latest.args.success ? "delivered" : "failed";
}

/**
 * Execution status of a forwarded domain message on its destination spoke, which the caller
 * configures locally. Read `deliveryNonce` from the hub's `DomainMessageRouted` event. The
 * message is tracked by the plaintext its envelope seals, which the caller supplies.
 */
export async function routedMessageDeliveryStatus(
  client: PublicClient,
  message: DomainMessage,
  destinationSpoke: Address,
  deliveryNonce: bigint,
  plaintext: MessagePlaintext,
): Promise<L1DeliveryStatus> {
  const messageHash = hashMessage(domainDeliveryEnvelope(message, deliveryNonce, plaintext));
  return l1MessageDeliveryStatus(client, { messageHash }, destinationSpoke);
}

/** Checks a computed anchor is recorded in the hub's `domainAnchors`. */
export async function isDomainAnchorRecorded(
  client: PublicClient,
  domainChainId: bigint,
  anchor: Hex,
  hub: Address,
): Promise<boolean> {
  return client.readContract({
    address: hub,
    abi: DOMAIN_ANCHOR_ABI,
    functionName: "domainAnchors",
    args: [domainChainId, anchor],
  });
}
