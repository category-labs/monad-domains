import assert from "node:assert/strict";
import { test } from "node:test";
import { type Address, type Hex, type PublicClient } from "viem";
import {
  decodeDomainMessage, encodeDomainMessage, hashMessage, hashDomainMessage,
  domainDeliveryEnvelope, type DomainMessage,
} from "../src/message.js";
import { fetchDomainMessages, proveMessage } from "../src/prover.js";
import { routedMessageDeliveryStatus } from "../src/routing.js";
import { verify, root } from "../src/merkle.js";

const addr = (n: number) => `0x${n.toString(16).padStart(40,"0")}` as Address;
const context = { l1ChainId: 1n, hub: addr(1) };
const spoke = addr(2);
const routed: DomainMessage = {
  sourceChainId: 7777n, destinationChainId: 8888n,
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

test("routing status does not turn RPC errors into delivery success", async () => {
  const client = {
    getBlockNumber: async () => 42n,
    getLogs: async () => { throw new Error("RPC unavailable"); },
  } as unknown as PublicClient;
  await assert.rejects(routedMessageDeliveryStatus(client, routed, spoke, 3n), /RPC unavailable/);
});
