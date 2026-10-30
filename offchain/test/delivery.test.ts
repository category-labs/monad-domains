import assert from "node:assert/strict";
import { test } from "node:test";
import { type Address, type Hex, type PublicClient } from "viem";
import { hashDomainMessage, MessageKind, type DomainMessage } from "../src/message.js";
import { domainMessageDeliveryStatus } from "../src/prover.js";

const hub = "0x0000000000000000000000000000000000001234" as Address;
const context = { l1ChainId: 1n, hub };
const message: DomainMessage = { kind: MessageKind.Plain, sourceChainId: 7777n, destinationChainId: 1n,
  from: hub, to: hub, sourceNonce: 0n, data: "0x" };
const messageHash = hashDomainMessage(message, context);

for (const [relayed, failed, expected] of [
  [false, false, "pending"],
  [true, true, "failed"],
  [true, false, "delivered"],
] as const) {
  test(`domain delivery status is ${expected}`, async () => {
    const reads: Record<string, unknown>[] = [];
    const client = {
      getBlockNumber: async () => 42n,
      readContract: async (request: Record<string, unknown>) => {
        reads.push(request);
        return request.functionName === "relayedDomainMessages" ? relayed : failed;
      },
    } as unknown as PublicClient;
    assert.equal(await domainMessageDeliveryStatus(client, message, context), expected);
    assert.equal(reads.length, 2);
    for (const request of reads) {
      assert.equal(request.address, hub);
      assert.deepEqual(request.args, [7777n, messageHash]);
      assert.equal(request.blockNumber, 42n, "both flags must describe the same block");
    }
  });
}

test("delivery read errors cannot be mistaken for successful delivery", async () => {
  const client = {
    getBlockNumber: async () => 42n,
    readContract: async () => { throw new Error("RPC unavailable"); },
  } as unknown as PublicClient;
  await assert.rejects(domainMessageDeliveryStatus(client, message, context), /RPC unavailable/);
});


test("hub relay success means queued when destination is another domain", async () => {
  const client = { getBlockNumber: async () => 42n,
    readContract: async ({ functionName }: { functionName: string }) => functionName === "relayedDomainMessages",
  } as unknown as PublicClient;
  assert.equal(await domainMessageDeliveryStatus(client, { ...message, destinationChainId: 8888n }, context), "queued");
});
