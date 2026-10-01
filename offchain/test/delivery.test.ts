import assert from "node:assert/strict";
import { test } from "node:test";
import { type Address, type Hex, type PublicClient } from "viem";
import { domainMessageDeliveryStatus } from "../src/prover.js";

const hub = "0x0000000000000000000000000000000000001234" as Address;
const messageHash = `0x${"ab".repeat(32)}` as Hex;

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
    assert.equal(await domainMessageDeliveryStatus(client, 7777n, messageHash, hub), expected);
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
  await assert.rejects(domainMessageDeliveryStatus(client, 7777n, messageHash, hub), /RPC unavailable/);
});
