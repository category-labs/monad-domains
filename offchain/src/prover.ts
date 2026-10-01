import { parseAbiItem, type Address, type Hex, type PublicClient } from "viem";
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

/** Fetch every domain-origin message in one finalized batch, in log order.
 * L1 callbacks and domain destinations share this stream, envelope and Merkle tree.
 * The range must match the operator's finalization boundaries exactly.
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
 * Builds the anchor and merkle proof for one message within its batch. The batch must
 * be the complete, ordered set of messages the operator merkleized into one anchor
 * (everything pending when `finalizeDomainMessages` was called).
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
