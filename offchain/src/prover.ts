import { parseAbiItem, type Address, type Hex, type PublicClient } from "viem";
import { batchRoot, domainMessageCountAt, fetchDomainMessageIds } from "./checkpoint.js";
import { decryptMessage } from "./encryption.js";
import { hashMessage, hashDomainMessage, decodeDomainMessage, type DomainMessage, type MessageContext, type Message } from "./message.js";
import { getProof, root } from "./merkle.js";

export const L1_MESSAGE_RECORDED_EVENT = parseAbiItem(
  "event L1MessageRecorded(uint64 indexed domainChainId, uint64 sourceChainId, address indexed from, address indexed to, bytes data, uint256 nonce, bytes32 messageHash)",
);

export const ENCRYPTED_L1_MESSAGE_RECORDED_EVENT = parseAbiItem(
  "event EncryptedL1MessageRecorded(uint64 indexed domainChainId, uint64 sourceChainId, address indexed from, bytes ciphertext, uint256 nonce)",
);

export const DOMAIN_MESSAGE_RECORDED_EVENT = parseAbiItem(
  "event DomainMessageRecorded(bytes32 indexed messageId, bytes message)",
);

/** Emitted by the spoke for every protocol-delivered L1 -> domain message. */
export const L1_MESSAGE_RELAYED_EVENT = parseAbiItem(
  "event L1MessageRelayed(bytes32 indexed messageHash, uint64 sourceChainId, address indexed from, address indexed to, uint256 nonce, bool success)",
);

export const DOMAIN_MESSAGE_RELAYED_EVENT = parseAbiItem(
  "event DomainMessageRelayed(uint64 indexed domainChainId, bytes32 indexed messageHash, address indexed from, address to, uint256 nonce, bool success)",
);

/** Emitted by the hub when a quorum attests a checkpoint; `domainAnchor` is that batch's root. */
export const DOMAIN_STATE_UPDATED_EVENT = parseAbiItem(
  "event DomainStateUpdated(uint64 indexed domainChainId, uint256 stateNonce, uint64 domainBlockNumber, bytes32 newStateRoot, bytes32 domainAnchor)",
);

const HUB_DELIVERY_ABI = [
  parseAbiItem("function relayedDomainMessages(uint64 domainChainId, bytes32 messageHash) view returns (bool)"),
  parseAbiItem("function failedDomainMessages(uint64 domainChainId, bytes32 messageHash) view returns (bool)"),
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

function sortByPosition<T>(messages: RecordedMessage<T>[]): RecordedMessage<T>[] {
  return messages.sort((a, b) =>
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

/** An encrypted message event whose ciphertext the viewing key could not open. */
export interface UndecryptableMessage {
  nonce: bigint;
  blockNumber: bigint;
  logIndex: number;
}

/**
 * Fetches all encrypted L1 -> domain messages recorded for `domainChainId` in the
 * block range and decrypts them with the domain viewing secret key, in recording order.
 * The event's `sourceChainId`/`from` are the authenticated origin: the L1 caller of
 * `sendEncryptedL1Message`, or the source domain and sender of a forwarded
 * `sendEncryptedDomainMessage`; the decrypted envelope carries them through.
 * A decrypted message is returned in the exact shape the plaintext stream yields — its
 * `messageHash` is the plaintext hash the spoke derives at delivery — so
 * `l1MessageDeliveryStatus` works on it unchanged.
 *
 * The protocol's full derivation stream is the nonce-ordered union of this stream and
 * `fetchL1Messages`: both draw from one per-domain nonce sequence.
 *
 * A ciphertext that fails to decrypt still consumed its nonce on the hub, so it is surfaced
 * under `undecryptable` rather than dropped; the client never delivers that nonce, and the
 * spoke accepts the gap (delivery nonces are strictly increasing rather than gapless).
 */
export async function fetchEncryptedL1Messages(
  client: PublicClient,
  domainChainId: bigint,
  range: { fromBlock: bigint; toBlock: bigint },
  hub: Address,
  viewingSecretKey: Hex,
): Promise<{ messages: RecordedMessage[]; undecryptable: UndecryptableMessage[] }> {
  const logs = await client.getLogs({
    address: hub,
    event: ENCRYPTED_L1_MESSAGE_RECORDED_EVENT,
    args: { domainChainId },
    ...range,
  });

  const messages: RecordedMessage[] = [];
  const undecryptable: UndecryptableMessage[] = [];
  for (const log of logs) {
    const { sourceChainId, from, ciphertext, nonce } = log.args;
    if (sourceChainId === undefined || !from || ciphertext === undefined || nonce === undefined) {
      throw new Error("prover: incomplete event log");
    }
    try {
      const { to, data } = await decryptMessage(viewingSecretKey, ciphertext);
      const message: Message = { sourceChainId, from, to, data, nonce };
      messages.push({
        message,
        messageHash: hashMessage(message),
        blockNumber: log.blockNumber,
        logIndex: log.logIndex,
      });
    } catch {
      undecryptable.push({ nonce, blockNumber: log.blockNumber, logIndex: log.logIndex });
    }
  }
  return { messages: sortByPosition(messages), undecryptable };
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
 * The set of messages one attestation anchored: nonces in `[fromNonce, toNonce)`, recorded in
 * domain blocks `(fromBlock, toBlock]` where `toBlock` is the attested height and `fromBlock`
 * the previously attested one. Obtain it from `findBatchForNonce` or from two consecutive
 * `DomainStateUpdated` events.
 */
export interface DomainBatch {
  fromNonce: bigint;
  toNonce: bigint;
  /** Previously attested height; the batch's messages were recorded after it. */
  fromBlock: bigint;
  /** Attested height. */
  toBlock: bigint;
  /** The anchor the hub recorded, when known. */
  anchor?: Hex;
}

/** Largest block range one `eth_getLogs` call is sent for; wider scans are split. */
export const DEFAULT_MAX_LOG_RANGE = 1000n;

export interface BatchScanOptions {
  /** Block range per `eth_getLogs` call. Default `DEFAULT_MAX_LOG_RANGE`. */
  maxLogRange?: bigint;
  /** Lowest block worth scanning, e.g. the spoke's deployment block. Default 0. */
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
 * from the spoke's events in `(batch.fromBlock, batch.toBlock]`, scanned in chunks the RPC
 * accepts; their nonces must cover `[fromNonce, toNonce)` exactly and each id must equal the
 * id the spoke stored for that nonce as of the attested height, so a proof built from the
 * result is a proof against the recorded anchor.
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
  const firstBlock = batch.fromBlock + 1n > scanFromBlock ? batch.fromBlock + 1n : scanFromBlock;
  const recorded: RecordedMessage<DomainMessage>[] = [];
  for (const range of logRanges(firstBlock, batch.toBlock, maxLogRange)) {
    recorded.push(...(await fetchDomainMessages(domain, range, spoke, context)));
  }
  const inRange = recorded
    .filter((m) => m.message.sourceNonce >= batch.fromNonce && m.message.sourceNonce < batch.toNonce)
    .sort((a, b) => (a.message.sourceNonce < b.message.sourceNonce ? -1 : a.message.sourceNonce > b.message.sourceNonce ? 1 : 0));
  if (BigInt(inRange.length) !== expected) {
    throw new Error(`prover: batch [${batch.fromNonce}, ${batch.toNonce}) has ${inRange.length} events, expected ${expected}`);
  }
  const stateIds = await fetchDomainMessageIds(domain, spoke, batch.fromNonce, batch.toNonce, batch.toBlock, idPageSize);
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

/**
 * Locates the attested batch containing source nonce `nonce` by walking the hub's
 * `DomainStateUpdated` events for `domainChainId` in `range` (L1 blocks, scanned in chunks)
 * and reading the spoke's message count at each attested height. `range` must start at or
 * before the domain's first attestation, because batches are defined by consecutive ones.
 * Null if no attestation covers the nonce yet.
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
  const { maxLogRange = DEFAULT_MAX_LOG_RANGE } = options;
  const updates: { height: bigint; anchor: Hex; stateNonce: bigint }[] = [];
  for (const chunk of logRanges(range.fromBlock, range.toBlock, maxLogRange)) {
    const logs = await l1.getLogs({ address: hub, event: DOMAIN_STATE_UPDATED_EVENT, args: { domainChainId }, ...chunk });
    for (const log of logs) {
      const { domainBlockNumber, domainAnchor, stateNonce } = log.args;
      if (domainBlockNumber === undefined || domainAnchor === undefined || stateNonce === undefined) {
        throw new Error("prover: incomplete event log");
      }
      updates.push({ height: BigInt(domainBlockNumber), anchor: domainAnchor, stateNonce });
    }
  }
  updates.sort((a, b) => (a.stateNonce < b.stateNonce ? -1 : a.stateNonce > b.stateNonce ? 1 : 0));
  if (updates.length > 0 && updates[0]!.stateNonce !== 0n) {
    throw new Error(
      `prover: scan range starts after the domain's first attestation (first state nonce seen: ${updates[0]!.stateNonce})`,
    );
  }

  let previousHeight = 0n;
  let previousCount = 0n;
  for (const update of updates) {
    const count = await domainMessageCountAt(domain, spoke, update.height);
    if (nonce >= previousCount && nonce < count) {
      return { fromNonce: previousCount, toNonce: count, fromBlock: previousHeight, toBlock: update.height, anchor: update.anchor };
    }
    previousHeight = update.height;
    previousCount = count;
  }
  return null;
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
  const domainChainId = message.sourceChainId;
  const messageHash = hashDomainMessage(message, context);
  const hub = context.hub;
  const blockNumber = await client.getBlockNumber({ cacheTime: 0 });
  const [relayed, failed] = await Promise.all([
    client.readContract({
      address: hub,
      abi: HUB_DELIVERY_ABI,
      functionName: "relayedDomainMessages",
      args: [domainChainId, messageHash],
      blockNumber,
    }),
    client.readContract({
      address: hub,
      abi: HUB_DELIVERY_ABI,
      functionName: "failedDomainMessages",
      args: [domainChainId, messageHash],
      blockNumber,
    }),
  ]);
  return !relayed ? "pending" : failed ? "failed" : message.destinationChainId === context.l1ChainId ? "delivered" : "queued";
}

/** Returns the latest delivery outcome recorded by the destination spoke.
 * An absent event means pending, even if the queue has advanced past the nonce.
 */
export async function l1MessageDeliveryStatus(
  client: PublicClient,
  recorded: RecordedMessage,
  spoke: Address,
): Promise<L1DeliveryStatus> {
  const toBlock = await client.getBlockNumber({ cacheTime: 0 });
  const logs = await client.getLogs({
    address: spoke,
    event: L1_MESSAGE_RELAYED_EVENT,
    args: { messageHash: recorded.messageHash },
    fromBlock: 0n,
    toBlock,
    strict: true,
  });
  const latest = logs.sort((a, b) =>
    a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1,
  ).at(-1);
  return latest === undefined ? "pending" : latest.args.success ? "delivered" : "failed";
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
