import assert from "node:assert/strict";
import { test } from "node:test";
import { zeroAddress, zeroHash, type Address, type Hex, type PublicClient } from "viem";
import {
  decodeDomainMessage, decodePlaintext, encodeDomainMessage, encodePlaintext, hashMessage, hashDomainMessage,
  domainDeliveryEnvelope, type DomainMessage,
} from "../src/message.js";
import {
  fetchBatches, fetchDomainBatch, fetchDomainMessages, findBatchForNonce, proveMessage, routedMessageDeliveryStatus,
} from "../src/prover.js";
import { verify, root } from "../src/merkle.js";

const addr = (n: number) => `0x${n.toString(16).padStart(40,"0")}` as Address;
const context = { l1ChainId: 1n, hub: addr(1) };
const spoke = addr(2);
const routed: DomainMessage = {
  sourceChainId: 7777n, destinationChainId: 8888n,
  from: zeroAddress, to: zeroAddress, sourceNonce: 9n, salt: zeroHash, data: "0x04c0ffee",
};
const plaintext = { from: addr(3), to: addr(4), data: "0x1234" as Hex };
const legacy: DomainMessage = {
  sourceChainId: 7777n, destinationChainId: 1n,
  from: addr(3), to: addr(4), sourceNonce: 8n, salt: `0x${"02".repeat(32)}`, data: "0xabcd",
};
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
    { ...routed, sourceChainId: 7778n },
    { ...routed, destinationChainId: 8889n }, { ...routed, from: addr(5) },
    { ...routed, to: addr(5) }, { ...routed, sourceNonce: 10n }, { ...routed, data: "0x04c0ffef" as Hex },
    { ...routed, salt: `0x${"01".repeat(32)}` as Hex },
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
    assert.equal(await routedMessageDeliveryStatus(client, routed, spoke, 3n, plaintext), expected);
    assert.equal(queries.length, 1);
    const query = queries[0]!;
    assert.deepEqual(query.args, { messageHash: hashMessage(domainDeliveryEnvelope(routed, 3n, plaintext)) });
    assert.equal(query.address, spoke);
    assert.equal(query.fromBlock, 0n);
    assert.equal(query.toBlock, 42n);
    assert.equal(query.strict, true);
    assert.equal((query.event as { name: string }).name, "L1MessageRelayed");
  });
}

// ---------------------------------------------------------------------------
// Sealed envelopes: naming nobody, delivered as the sealed plaintext
// ---------------------------------------------------------------------------

test("plaintext encoding round-trips the sender, target and payload", () => {
  const encoded = encodePlaintext(plaintext);
  assert.deepEqual(decodePlaintext(encoded), plaintext);
  assert.notEqual(encodePlaintext({ ...plaintext, from: addr(5) }), encoded);
  assert.deepEqual(decodePlaintext(encodePlaintext({ ...plaintext, data: "0x" })), { ...plaintext, data: "0x" });
});

test("a forwarded envelope delivers as its plaintext", () => {
  assert.deepEqual(domainDeliveryEnvelope(routed, 3n, plaintext), {
    sourceChainId: routed.sourceChainId, from: plaintext.from, to: plaintext.to, data: plaintext.data, nonce: 3n,
  });
});

// ---------------------------------------------------------------------------
// Attested batches: nonce ranges between consecutive checkpoints
// ---------------------------------------------------------------------------

const batchContext = { l1ChainId: 1n, hub: addr(1) };
// Attested at L1 height 30 after one at 20; on the domain's own chain the batch is block 10 alone.
const batch = { stateNonce: 4n, fromNonce: 8n, toNonce: 10n, fromBlock: 20n, toBlock: 30n, firstDomainBlock: 10n, lastDomainBlock: 10n };

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
  assert.equal(logQuery.fromBlock, 10n, "events are scanned in domain blocks, after the previous checkpoint");
  assert.equal(logQuery.toBlock, 10n);
  const idReads = calls.filter((c) => c.functionName === "domainMessageIds");
  assert.deepEqual(idReads.map((c) => c.args), [[8n], [9n]]);
  for (const read of idReads) assert.equal(read.blockNumber, 10n, "the spoke's ids are read at the batch's last domain block");
});

test("fetchDomainBatch scans wide ranges in chunks and honours a scan floor", async () => {
  const client = batchClient();
  await fetchDomainBatch(client, spoke, { ...batch, firstDomainBlock: 1n }, batchContext, { maxLogRange: 4n });
  const ranges = (client as unknown as { calls: Record<string, unknown>[] }).calls
    .filter((c) => "event" in c)
    .map((c) => [c.fromBlock, c.toBlock]);
  assert.deepEqual(ranges, [[1n, 4n], [5n, 8n], [9n, 10n]]);

  const floored = batchClient();
  await fetchDomainBatch(floored, spoke, { ...batch, firstDomainBlock: 0n }, batchContext, { scanFromBlock: 7n });
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
      { args: { domainChainId: 7777n, stateNonce: 1n, domainBlockNumber: 20n, newBlockHash: "0x" as Hex, domainAnchor: anchorB }, blockNumber: 21n, logIndex: 0 },
      { args: { domainChainId: 7777n, stateNonce: 0n, domainBlockNumber: 10n, newBlockHash: "0x" as Hex, domainAnchor: anchorA }, blockNumber: 11n, logIndex: 0 },
    ],
    // The hub's latest domain block as of each attested L1 height: [l1BlockNumber, domainBlockNumber].
    readContract: async ({ functionName, blockNumber }: { functionName: string; blockNumber: bigint }) => {
      assert.equal(functionName, "latestDomainBlock");
      return ({ "10": [8n, 3n], "20": [17n, 5n] } as Record<string, [bigint, bigint]>)[String(blockNumber)] ?? [0n, 0n];
    },
  } as unknown as PublicClient;
  const countsByDomainBlock: Record<string, bigint> = { "3": 9n, "5": 10n };
  const domain = {
    readContract: async ({ blockNumber }: { blockNumber: bigint }) => countsByDomainBlock[String(blockNumber)] ?? 0n,
  } as unknown as PublicClient;
  const range = { fromBlock: 0n, toBlock: 30n };

  assert.deepEqual(await findBatchForNonce(l1, domain, addr(1), spoke, 7777n, 8n, range), {
    stateNonce: 0n, fromNonce: 0n, toNonce: 9n, fromBlock: 0n, toBlock: 10n,
    firstDomainBlock: 0n, lastDomainBlock: 3n, anchor: anchorA, attestedInBlock: 11n,
  });
  assert.deepEqual(await findBatchForNonce(l1, domain, addr(1), spoke, 7777n, 9n, range), {
    stateNonce: 1n, fromNonce: 9n, toNonce: 10n, fromBlock: 10n, toBlock: 20n,
    firstDomainBlock: 4n, lastDomainBlock: 5n, anchor: anchorB, attestedInBlock: 21n,
  });
  assert.equal(await findBatchForNonce(l1, domain, addr(1), spoke, 7777n, 10n, range), null, "not attested yet");

  // A scan can continue after the last batch of an earlier one instead of starting over.
  const [first, second] = await fetchBatches(l1, domain, addr(1), spoke, 7777n, range);
  assert.deepEqual(await fetchBatches(l1, domain, addr(1), spoke, 7777n, range, { after: first }), [second]);
  assert.deepEqual(await fetchBatches(l1, domain, addr(1), spoke, 7777n, range, { after: second }), []);
});

test("findBatchForNonce rejects a scan range that starts after the first attestation", async () => {
  const l1 = {
    getLogs: async () => [
      { args: { domainChainId: 7777n, stateNonce: 2n, domainBlockNumber: 30n, newBlockHash: "0x" as Hex, domainAnchor: root([routeId]) }, blockNumber: 31n, logIndex: 0 },
    ],
  } as unknown as PublicClient;
  const domain = { readContract: async () => 10n } as unknown as PublicClient;
  await assert.rejects(
    findBatchForNonce(l1, domain, addr(1), spoke, 7777n, 9n, { fromBlock: 25n, toBlock: 40n }),
    /starts after the checkpoint with state nonce 0/,
  );
});
