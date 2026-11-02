import assert from "node:assert/strict";
import { test } from "node:test";
import { domainFeeCaps } from "../src/sequence.js";

test("domain fee caps remain valid above the observed base fee", () => {
  assert.deepEqual(domainFeeCaps(50n), { maxFeePerGas: 100n, maxPriorityFeePerGas: 0n });
  assert.deepEqual(domainFeeCaps(0n), { maxFeePerGas: 1n, maxPriorityFeePerGas: 0n });
});
