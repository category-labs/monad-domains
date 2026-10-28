import assert from "node:assert/strict";
import { test } from "node:test";
import { zeroAddress, zeroHash, type Address, type Hex, type PublicClient } from "viem";
import {
  decodeDomainMessage, encodeDomainMessage, hashMessage, hashDomainMessage,
  domainDeliveryEnvelope, isEncryptedDomainMessage, MessageKind, type DomainMessage,
} from "../src/message.js";
import { fetchDomainBatch, fetchDomainMessages, findBatchForNonce, proveMessage } from "../src/prover.js";
import { routedMessageDeliveryStatus } from "../src/routing.js";
import { verify, root } from "../src/merkle.js";

const addr = (n: number) => `0x${n.toString(16).padStart(40,"0")}` as Address;
const context = { l1ChainId: 1n, hub: addr(1) };
const spoke = addr(2);
const routed: DomainMessage = {
  kind: MessageKind.Plain, sourceChainId: 7777n, destinationChainId: 8888n,
  from: addr(3), to: addr(4), sourceNonce: 9n, data: "0x1234",
};
const legacy: DomainMessage = { ...routed, destinationChainId: 1n, sourceNonce: 8n, data: "0xabcd" };
const routeId = hashDomainMessage(routed, context);
const legacyId = hashDomainMessage(legacy, context);
const logs = {
  legacy: { args: { message: encodeDomainMessage(legacy), messageId: legacyId }, blockNumber: 10n, logIndex: 3 },
  routed: { args: { message: encodeDomainMessage(routed), messageId: routeId }, blockNumber: 10n, logIndex: 4 },
};

function clientWithLogs(routeLog = logs.routed): PublicClient {
  return {
    getLogs: async ({ event }: { event: { name: string } }) =>
      event.name === "DomainMessageRecorded" ? [routeLog, logs.legacy] : [],
  } as unknown as PublicClient;
}

test("routed envelope round-trips and rejects non-canonical encodings", () => {
  assert.deepEqual(decodeDomainMessage(encodeDomainMessage(routed)), routed);
  assert.throws(() => decodeDomainMessage(`${encodeDomainMessage(routed)}00`), /non-canonical/);
});

test("message IDs commit to every field and deployment context", () => {
  for (const message of [
    { ...routed, kind: MessageKind.Encrypted },
    { ...routed, sourceChainId: 7778n },
    { ...routed, destinationChainId: 8889n }, { ...routed, from: addr(5) },
    { ...routed, to: addr(5) }, { ...routed, sourceNonce: 10n }, { ...routed, data: "0x1235" as Hex },
  ]) assert.notEqual(hashDomainMessage(message, context), routeId);
  assert.notEqual(hashDomainMessage(routed, { ...context, l1ChainId: 2n }), routeId);
  assert.notEqual(hashDomainMessage(routed, { ...context, hub: addr(5) }), routeId);
});

test("mixed batches prove withdrawals and native messages against the same complete anchor", async () => {
  const batch = await fetchDomainMessages(clientWithLogs(), { fromBlock: 10n, toBlock: 10n }, spoke, context);
  assert.deepEqual(batch.map(m => m.messageHash), [legacyId, routeId]);
  const withdrawal = proveMessage(batch, legacyId);
  const route = proveMessage(batch, routeId);
  assert.equal(withdrawal.message.destinationChainId, 1n);
  assert.equal(route.message.destinationChainId, 8888n);
  assert.equal(route.anchor, root([legacyId, routeId]));
  assert.equal(withdrawal.anchor, route.anchor);
  assert.ok(verify(route.proof, route.anchor, routeId));
  assert.ok(verify(withdrawal.proof, withdrawal.anchor, legacyId));
});

test("indexer rejects altered preimages or the wrong deployment context", async () => {
  const corrupt = { ...logs.routed, args: { ...logs.routed.args, message: encodeDomainMessage({ ...routed, sourceNonce: 10n }) } };
  await assert.rejects(fetchDomainMessages(clientWithLogs(corrupt), { fromBlock: 10n, toBlock: 10n }, spoke, context), /mismatch/);
  await assert.rejects(fetchDomainMessages(clientWithLogs(), { fromBlock: 10n, toBlock: 10n }, spoke, { ...context, l1ChainId: 2n }), /mismatch/);
});

for (const [success, expected] of [
  [undefined, "pending"], [false, "failed"], [true, "delivered"],
] as const) {
  test(`routed delivery status ${expected} queries destination events by delivery hash`, async () => {
    const queries: Record<string, unknown>[] = [];
    const client = {
      getBlockNumber: async () => 42n,
      getLogs: async (request: Record<string, unknown>) => {
        queries.push(request);
        return success === undefined ? [] : [{ args: { success }, blockNumber: 41n, logIndex: 0 }];
      },
    } as unknown as PublicClient;
    assert.equal(await routedMessageDeliveryStatus(client, routed, spoke, 3n), expected);
    assert.equal(queries.length, 1);
    const query = queries[0]!;
    assert.deepEqual(query.args, { messageHash: hashMessage(domainDeliveryEnvelope(routed, 3n)) });
    assert.equal(query.address, spoke);
    assert.equal(query.fromBlock, 0n);
    assert.equal(query.toBlock, 42n);
    assert.equal(query.strict, true);
    assert.equal((query.event as { name: string }).name, "L1MessageRelayed");
  });
}

// ---------------------------------------------------------------------------
// Encrypted envelopes: kind Encrypted with no target, delivered as the plaintext the sender sealed
// ---------------------------------------------------------------------------

const encrypted: DomainMessage = { ...routed, kind: MessageKind.Encrypted, to: zeroAddress, sourceNonce: 11n, data: "0x04c0ffee" };
const plaintext = { to: addr(4), data: "0x1234" as Hex };

test("encrypted envelopes round-trip and unknown kinds are rejected", () => {
  assert.ok(isEncryptedDomainMessage(encrypted));
  assert.ok(!isEncryptedDomainMessage(routed));
  assert.deepEqual(decodeDomainMessage(encodeDomainMessage(encrypted)), encrypted);
  assert.notEqual(hashDomainMessage(encrypted, context), hashDomainMessage({ ...encrypted, data: "0x04c0ffef" }, context));
  const unknownKind = encodeDomainMessage({ ...encrypted, kind: 2 as MessageKind });
  assert.throws(() => decodeDomainMessage(unknownKind), /unknown message kind/);
});

test("an encrypted envelope delivers as its plaintext", () => {
  assert.throws(() => domainDeliveryEnvelope(encrypted, 3n), /plaintext/);
  assert.deepEqual(domainDeliveryEnvelope(encrypted, 3n, plaintext), {
    sourceChainId: encrypted.sourceChainId, from: encrypted.from, to: plaintext.to, data: plaintext.data, nonce: 3n,
  });
  // Same delivery hash as a plaintext route of the same content.
  assert.equal(
    hashMessage(domainDeliveryEnvelope(encrypted, 3n, plaintext)),
    hashMessage(domainDeliveryEnvelope({ ...routed, to: plaintext.to, data: plaintext.data }, 3n)),
  );
  assert.deepEqual(domainDeliveryEnvelope(routed, 3n, plaintext), domainDeliveryEnvelope(routed, 3n));
});

test("encrypted routed delivery status queries by the plaintext delivery hash", async () => {
  const queries: Record<string, unknown>[] = [];
  const client = {
    getBlockNumber: async () => 42n,
    getLogs: async (request: Record<string, unknown>) => {
      queries.push(request);
      return [{ args: { success: true }, blockNumber: 41n, logIndex: 0 }];
    },
  } as unknown as PublicClient;
  await assert.rejects(routedMessageDeliveryStatus(client, encrypted, spoke, 3n), /plaintext/);
  assert.equal(queries.length, 0);
  assert.equal(await routedMessageDeliveryStatus(client, encrypted, spoke, 3n, plaintext), "delivered");
  assert.deepEqual(queries[0]!.args, { messageHash: hashMessage(domainDeliveryEnvelope(encrypted, 3n, plaintext)) });
});

test("routing status does not turn RPC errors into delivery success", async () => {
  const client = {
    getBlockNumber: async () => 42n,
    getLogs: async () => { throw new Error("RPC unavailable"); },
  } as unknown as PublicClient;
  await assert.rejects(routedMessageDeliveryStatus(client, routed, spoke, 3n), /RPC unavailable/);
});

// ---------------------------------------------------------------------------
// Attested batches: nonce ranges between consecutive checkpoints
// ---------------------------------------------------------------------------

const batchContext = { l1ChainId: 1n, hub: addr(1) };
const batch = { fromNonce: 8n, toNonce: 10n, fromBlock: 9n, toBlock: 10n };

function batchClient(stateIds: Hex[] = [legacyId, routeId]): PublicClient {
  const calls: Record<string, unknown>[] = [];
  const client = {
    calls,
    getLogs: async (request: { event: { name: string }; fromBlock: bigint; toBlock: bigint }) => {
      calls.push(request);
      // Both messages were recorded in block 10; only the chunk covering it returns them.
      const coversBlock10 = request.fromBlock <= 10n && request.toBlock >= 10n;
      return request.event.name === "DomainMessageRecorded" && coversBlock10 ? [logs.routed, logs.legacy] : [];
    },
    readContract: async (request: { functionName: string; args: [bigint] }) => {
      calls.push(request);
      if (request.functionName !== "domainMessageIds") throw new Error(`unexpected read ${request.functionName}`);
      return stateIds[Number(request.args[0] - batch.fromNonce)] ?? zeroHash;
    },
  };
  return client as unknown as PublicClient;
}

test("fetchDomainBatch returns the attested nonce range in order and cross-checks the spoke's ids", async () => {
  const client = batchClient();
  const messages = await fetchDomainBatch(client, spoke, batch, batchContext);
  assert.deepEqual(messages.map((m) => m.message.sourceNonce), [8n, 9n]);
  const { anchor, proof } = proveMessage(messages, routeId);
  assert.equal(anchor, root([legacyId, routeId]));
  assert.ok(verify(proof, anchor, routeId));

  const calls = (client as unknown as { calls: Record<string, unknown>[] }).calls;
  const logQuery = calls.find((c) => "event" in c)!;
  assert.equal(logQuery.fromBlock, 10n, "events are scanned after the previous checkpoint");
  assert.equal(logQuery.toBlock, 10n);
  const idReads = calls.filter((c) => c.functionName === "domainMessageIds");
  assert.deepEqual(idReads.map((c) => c.args), [[8n], [9n]]);
  for (const read of idReads) assert.equal(read.blockNumber, 10n, "the spoke's ids are read at the attested height");
});

test("fetchDomainBatch scans wide ranges in chunks and honours a scan floor", async () => {
  const client = batchClient();
  await fetchDomainBatch(client, spoke, { ...batch, fromBlock: 0n, toBlock: 10n }, batchContext, { maxLogRange: 4n });
  const ranges = (client as unknown as { calls: Record<string, unknown>[] }).calls
    .filter((c) => "event" in c)
    .map((c) => [c.fromBlock, c.toBlock]);
  assert.deepEqual(ranges, [[1n, 4n], [5n, 8n], [9n, 10n]]);

  const floored = batchClient();
  await fetchDomainBatch(floored, spoke, { ...batch, fromBlock: 0n, toBlock: 10n }, batchContext, { scanFromBlock: 7n });
  const flooredRanges = (floored as unknown as { calls: Record<string, unknown>[] }).calls
    .filter((c) => "event" in c)
    .map((c) => [c.fromBlock, c.toBlock]);
  assert.deepEqual(flooredRanges, [[7n, 10n]]);
});

test("fetchDomainBatch rejects a batch the spoke's state does not confirm", async () => {
  await assert.rejects(fetchDomainBatch(batchClient([routeId, legacyId]), spoke, batch, batchContext), /differs from the spoke's stored id/);
  await assert.rejects(
    fetchDomainBatch(batchClient(), spoke, { ...batch, anchor: root([routeId]) }, batchContext),
    /differs from the attested anchor/,
  );
});

test("fetchDomainBatch rejects incomplete nonce ranges", async () => {
  await assert.rejects(fetchDomainBatch(batchClient(), spoke, { ...batch, toNonce: 11n }, batchContext), /expected 3/);
  await assert.rejects(
    fetchDomainBatch(batchClient(), spoke, { ...batch, fromNonce: 7n, toNonce: 9n }, batchContext),
    /expected 2|missing nonce 7/,
  );
  assert.deepEqual(await fetchDomainBatch(batchClient(), spoke, { ...batch, toNonce: 8n }, batchContext), []);
});

test("findBatchForNonce pairs consecutive attestations with the spoke's counts at their heights", async () => {
  const anchorA = root([legacyId]);
  const anchorB = root([routeId]);
  const l1 = {
    getLogs: async () => [
      { args: { domainChainId: 7777n, stateNonce: 1n, domainBlockNumber: 20n, newStateRoot: "0x" as Hex, domainAnchor: anchorB }, blockNumber: 21n, logIndex: 0 },
      { args: { domainChainId: 7777n, stateNonce: 0n, domainBlockNumber: 10n, newStateRoot: "0x" as Hex, domainAnchor: anchorA }, blockNumber: 11n, logIndex: 0 },
    ],
  } as unknown as PublicClient;
  const countsByHeight: Record<string, bigint> = { "10": 9n, "20": 10n };
  const domain = {
    readContract: async ({ blockNumber }: { blockNumber: bigint }) => countsByHeight[String(blockNumber)] ?? 0n,
  } as unknown as PublicClient;
  const range = { fromBlock: 0n, toBlock: 30n };

  assert.deepEqual(await findBatchForNonce(l1, domain, addr(1), spoke, 7777n, 8n, range), {
    fromNonce: 0n, toNonce: 9n, fromBlock: 0n, toBlock: 10n, anchor: anchorA,
  });
  assert.deepEqual(await findBatchForNonce(l1, domain, addr(1), spoke, 7777n, 9n, range), {
    fromNonce: 9n, toNonce: 10n, fromBlock: 10n, toBlock: 20n, anchor: anchorB,
  });
  assert.equal(await findBatchForNonce(l1, domain, addr(1), spoke, 7777n, 10n, range), null, "not attested yet");
});

test("findBatchForNonce rejects a scan range that starts after the first attestation", async () => {
  const l1 = {
    getLogs: async () => [
      { args: { domainChainId: 7777n, stateNonce: 2n, domainBlockNumber: 30n, newStateRoot: "0x" as Hex, domainAnchor: root([routeId]) }, blockNumber: 31n, logIndex: 0 },
    ],
  } as unknown as PublicClient;
  const domain = { readContract: async () => 10n } as unknown as PublicClient;
  await assert.rejects(
    findBatchForNonce(l1, domain, addr(1), spoke, 7777n, 9n, { fromBlock: 25n, toBlock: 40n }),
    /starts after the domain's first attestation/,
  );
});
