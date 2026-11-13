import assert from "node:assert/strict";
import { test } from "node:test";
import { encodeAbiParameters, parseAbiParameters } from "viem";
import { domainFeeCaps, sequenceTransaction } from "../src/sequence.js";

test("domain fee caps remain valid above the observed base fee", () => {
  assert.deepEqual(domainFeeCaps(50n), { maxFeePerGas: 100n, maxPriorityFeePerGas: 0n });
  assert.deepEqual(domainFeeCaps(0n), { maxFeePerGas: 1n, maxPriorityFeePerGas: 0n });
});

for (const viewingKey of [undefined, "0x"] as const) {
  test(`missing viewing key never submits a plaintext transaction (${viewingKey ?? "hub lookup"})`, async (t) => {
    t.mock.method(globalThis, "fetch", async (_url: unknown, init: RequestInit) => {
      assert.ok(typeof init.body === "string");
      const request: unknown = JSON.parse(init.body);
      assert.ok(request !== null && typeof request === "object" && "method" in request && "id" in request);
      assert.ok(typeof request.method === "string");
      const method = request.method;
      const results: Record<string, unknown> = {
        eth_chainId: "0x7a69",
        eth_getBlockByNumber: { number: "0x1", gasLimit: "0x1c9c380", baseFeePerGas: "0x1" },
        eth_call: encodeAbiParameters(parseAbiParameters("bytes"), ["0x"]),
      };
      assert.ok(method in results, `unexpected RPC call: ${method}`);
      return Response.json({ jsonrpc: "2.0", id: request.id, result: results[method] });
    });

    await assert.rejects(sequenceTransaction({
      l1RpcUrl: "http://localhost:8545",
      hub: "0x0000000000000000000000000000000000000001",
      domainChainId: 7777n,
      senderKey: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
      nonce: 0,
      viewingKey,
    }), /domain has no viewing key/);
  });
}
