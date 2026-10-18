import assert from "node:assert/strict";
import { test } from "node:test";
import { encodeAbiParameters, keccak256, toHex, type Address, type Hex, type Log, type PublicClient } from "viem";
import { root } from "../src/merkle.js";
import { DOMAIN_MESSAGES_FINALIZED_EVENT, parseFinalizedBatches } from "../src/prover.js";
import {
  DomainRelayer,
  getDomainHeader,
  partitionByFinalizePoints,
  recordedBefore,
  type IndexedMessage,
} from "../src/relayer.js";

const spoke = "0x0000000000000000000000000000000000005afe" as Address;
const hub = "0x0000000000000000000000000000000000001234" as Address;
const key = (n: number): Hex => toHex(n, { size: 32 });

/** Builds a `DomainMessagesFinalized` log as a spoke that emits it would. */
function finalizedLog(anchor: Hex, leaves: Hex[], address: Address = spoke, blockNumber = 7n, logIndex = 3): Log {
  return {
    address,
    topics: [keccak256(toHex("DomainMessagesFinalized(bytes32,bytes32[])")), anchor],
    data: encodeAbiParameters([{ type: "bytes32[]" }], [leaves]),
    blockNumber,
    logIndex,
    blockHash: key(1),
    transactionHash: key(2),
    transactionIndex: 0,
    removed: false,
  } as Log;
}

const leaves: Hex[] = [keccak256("0x01"), keccak256("0x02"), keccak256("0x03")];

/** An indexed message at a position; the envelope itself is irrelevant to partitioning. */
function at(n: number, blockNumber: bigint, transactionIndex: number, logIndex = transactionIndex * 10): IndexedMessage {
  return {
    message: {
      sourceChainId: 85679n,
      destinationChainId: 20143n,
      from: spoke,
      to: hub,
      sourceNonce: BigInt(n),
      data: "0x",
    },
    messageHash: keccak256(toHex(n)),
    blockNumber,
    transactionIndex,
    logIndex,
  };
}

test("the finalized event signature matches the spoke", () => {
  assert.equal(DOMAIN_MESSAGES_FINALIZED_EVENT.name, "DomainMessagesFinalized");
});

test("parseFinalizedBatches rebuilds a batch from the finalize event", () => {
  const anchor = root(leaves);
  const [batch] = parseFinalizedBatches([finalizedLog(anchor, leaves)], spoke);
  assert.ok(batch);
  assert.equal(batch.anchor, anchor);
  assert.deepEqual(batch.leaves, leaves);
  assert.equal(batch.blockNumber, 7n);
  assert.equal(batch.logIndex, 3);
});

test("parseFinalizedBatches ignores events from other contracts", () => {
  const other = "0x0000000000000000000000000000000000000bad" as Address;
  assert.deepEqual(parseFinalizedBatches([finalizedLog(root(leaves), leaves, other)], spoke), []);
});

test("parseFinalizedBatches rejects an anchor that is not the root of its leaves", () => {
  assert.throws(() => parseFinalizedBatches([finalizedLog(keccak256("0xdead"), leaves)], spoke), /not the root of its leaves/);
});

test("recordedBefore orders by block, then by transaction within a block", () => {
  const point = { blockNumber: 10n, transactionIndex: 2 };
  assert.equal(recordedBefore(at(0, 9n, 7), point), true);
  assert.equal(recordedBefore(at(0, 10n, 1), point), true);
  assert.equal(recordedBefore(at(0, 10n, 2), point), false);
  assert.equal(recordedBefore(at(0, 10n, 3), point), false);
  assert.equal(recordedBefore(at(0, 11n, 0), point), false);
});

test("partitionByFinalizePoints cuts the message list at every finalize, in order", () => {
  const messages = [at(0, 5n, 0), at(1, 5n, 1), at(2, 8n, 0), at(3, 8n, 2), at(4, 9n, 0)];
  // Finalizes: one after the first two (block 6), one in block 8 between tx 0 and tx 2, and a
  // stray earlier one (block 2) that cuts nothing. Given out of order on purpose.
  const points = [
    { blockNumber: 8n, transactionIndex: 1 },
    { blockNumber: 2n, transactionIndex: 0 },
    { blockNumber: 6n, transactionIndex: 0 },
  ];
  const { batches, consumed } = partitionByFinalizePoints(messages, points, 3);
  assert.equal(consumed, 3);
  assert.equal(batches.length, 2);
  assert.deepEqual(batches[0]!.leaves, [messages[0]!.messageHash, messages[1]!.messageHash]);
  assert.equal(batches[0]!.anchor, root(batches[0]!.leaves));
  assert.equal(batches[0]!.blockNumber, 6n);
  assert.equal(batches[0]!.start, 3);
  assert.deepEqual(batches[1]!.leaves, [messages[2]!.messageHash]);
  assert.equal(batches[1]!.blockNumber, 8n);
  assert.equal(batches[1]!.start, 5);
});

test("partitionByFinalizePoints leaves messages after the last finalize unbatched", () => {
  const messages = [at(0, 5n, 0), at(1, 7n, 0)];
  const { batches, consumed } = partitionByFinalizePoints(messages, []);
  assert.equal(consumed, 0);
  assert.deepEqual(batches, []);
});

test("getDomainHeader asks the domain route for the latest committed header", async () => {
  const requests: unknown[] = [];
  const client = {
    request: async (args: unknown) => {
      requests.push(args);
      return { number: "0x2a", stateRoot: key(9), parentHash: key(8), timestamp: "0x10" };
    },
  } as unknown as PublicClient;
  const latest = await getDomainHeader(client);
  assert.deepEqual(latest, { number: 42n, stateRoot: key(9), parentHash: key(8), timestamp: 16n });
  await getDomainHeader(client, 5n);
  await getDomainHeader(client, "finalized");
  assert.deepEqual(requests, [
    { method: "monad_getDomainHeader", params: ["latest"] },
    { method: "monad_getDomainHeader", params: ["0x5"] },
    { method: "monad_getDomainHeader", params: ["finalized"] },
  ]);
});

test("getDomainHeader reports a domain without history as null", async () => {
  const client = { request: async () => null } as unknown as PublicClient;
  assert.equal(await getDomainHeader(client), null);
});

test("the relayer refuses to start without domains or validator keys", () => {
  const submitterKey = key(1);
  assert.throws(() => new DomainRelayer({ l1RpcUrl: "http://localhost:8080", hub, submitterKey, domains: [] }), /no domains/);
  assert.throws(
    () =>
      new DomainRelayer({
        l1RpcUrl: "http://localhost:8080",
        hub,
        submitterKey,
        domains: [{ chainId: 85679n, spoke, operatorKey: key(2), validatorKeys: [] }],
      }),
    /no validator keys/,
  );
  const relayer = new DomainRelayer({
    l1RpcUrl: "http://localhost:8080",
    hub,
    submitterKey,
    domains: [{ chainId: 85679n, spoke, operatorKey: key(2), validatorKeys: [key(3)] }],
  });
  assert.deepEqual(relayer.status(), [
    {
      chainId: 85679n,
      spoke,
      scannedThrough: null,
      recorded: 0,
      batches: 0,
      anchored: 0,
      relayed: 0,
      lastAttestedAt: null,
      lastError: null,
    },
  ]);
});
