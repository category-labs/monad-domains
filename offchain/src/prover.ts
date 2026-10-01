import { parseAbiItem, type Address, type Hex, type PublicClient } from "viem";
import { decryptMessage } from "./encryption.js";
import { hashMessage, type Message } from "./message.js";
import { getProof, root } from "./merkle.js";

export const L1_MESSAGE_RECORDED_EVENT = parseAbiItem(
  "event L1MessageRecorded(uint64 indexed domainChainId, address indexed from, address indexed to, bytes data, uint256 nonce, bytes32 messageHash)",
);

export const ENCRYPTED_L1_MESSAGE_RECORDED_EVENT = parseAbiItem(
  "event EncryptedL1MessageRecorded(uint64 indexed domainChainId, address indexed from, bytes ciphertext, uint256 nonce)",
);

export const DOMAIN_MESSAGE_RECORDED_EVENT = parseAbiItem(
  "event DomainMessageRecorded(address indexed from, address indexed to, bytes data, uint256 nonce, bytes32 messageHash)",
);

/** Emitted by the spoke for every protocol-delivered L1 -> domain message. */
export const L1_MESSAGE_RELAYED_EVENT = parseAbiItem(
  "event L1MessageRelayed(bytes32 indexed messageHash, address indexed from, address indexed to, uint256 nonce, bool success)",
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

const SPOKE_DELIVERY_ABI = [
  parseAbiItem("function nextL1Nonce() view returns (uint256)"),
  parseAbiItem("function failedL1Messages(bytes32 messageHash) view returns (bool)"),
] as const;

/** A message as recorded on-chain, with the position metadata needed for batching. */
export interface RecordedMessage {
  message: Message;
  messageHash: Hex;
  blockNumber: bigint;
  logIndex: number;
}

/** Proof arguments for `DomainHub.relayDomainMessage`, alongside the source domain id. */
export interface MessageProof {
  message: Message;
  anchor: Hex;
  proof: Hex[];
}

function toRecorded(log: {
  args: { from?: Address; to?: Address; data?: Hex; nonce?: bigint; messageHash?: Hex };
  blockNumber: bigint;
  logIndex: number;
}): RecordedMessage {
  const { from, to, data, nonce, messageHash } = log.args;
  if (!from || !to || data === undefined || nonce === undefined || !messageHash) {
    throw new Error("prover: incomplete event log");
  }
  const message: Message = { from, to, data, nonce };
  const computed = hashMessage(message);
  if (computed.toLowerCase() !== messageHash.toLowerCase()) {
    throw new Error(`prover: event messageHash mismatch (computed ${computed}, recorded ${messageHash})`);
  }
  return { message, messageHash, blockNumber: log.blockNumber, logIndex: log.logIndex };
}

function sortByPosition(messages: RecordedMessage[]): RecordedMessage[] {
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
    const { from, ciphertext, nonce } = log.args;
    if (!from || ciphertext === undefined || nonce === undefined) {
      throw new Error("prover: incomplete event log");
    }
    try {
      const { to, data } = await decryptMessage(viewingSecretKey, ciphertext);
      const message: Message = { from, to, data, nonce };
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
 * Fetches all domain -> L1 messages recorded in the block range, in recording
 * order. For the domain direction one anchor is posted per state-root update, so a
 * batch spans all messages recorded between two consecutive updates — the caller
 * supplies that range.
 */
export async function fetchDomainMessages(
  client: PublicClient,
  range: { fromBlock: bigint; toBlock: bigint },
  spoke: Address,
): Promise<RecordedMessage[]> {
  const logs = await client.getLogs({
    address: spoke,
    event: DOMAIN_MESSAGE_RECORDED_EVENT,
    ...range,
  });
  return sortByPosition(logs.map(toRecorded));
}

/**
 * Builds the anchor and merkle proof for one message within its batch. The batch must
 * be the complete, ordered set of messages the operator merkleized into one anchor
 * (everything pending when `finalizeDomainMessages` was called).
 */
export function proveMessage(batch: readonly RecordedMessage[], messageHash: Hex): MessageProof {
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

export type DomainDeliveryStatus = "pending" | "delivered" | "failed";

/**
 * Reads both hub delivery flags at the same block. A successful relay transaction can
 * still contain a failed receiver call; only "delivered" means the application ran.
 */
export async function domainMessageDeliveryStatus(
  client: PublicClient,
  domainChainId: bigint,
  messageHash: Hex,
  hub: Address,
): Promise<DomainDeliveryStatus> {
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
  return !relayed ? "pending" : failed ? "failed" : "delivered";
}

/**
 * Reads the delivery status of a recorded L1 -> domain message from the spoke. The
 * protocol delivers messages strictly in nonce order, so a message is "pending" until
 * `nextL1Nonce` passes its nonce. A delivery whose target call reverted reads "failed"
 * until someone re-executes it via `retryL1Message` (after which it reads "delivered").
 */
export async function l1MessageDeliveryStatus(
  client: PublicClient,
  recorded: RecordedMessage,
  spoke: Address,
): Promise<L1DeliveryStatus> {
  const nextNonce = await client.readContract({
    address: spoke,
    abi: SPOKE_DELIVERY_ABI,
    functionName: "nextL1Nonce",
  });
  if (recorded.message.nonce >= nextNonce) return "pending";
  const failed = await client.readContract({
    address: spoke,
    abi: SPOKE_DELIVERY_ABI,
    functionName: "failedL1Messages",
    args: [recorded.messageHash],
  });
  return failed ? "failed" : "delivered";
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
