import assert from "node:assert/strict";
import { test } from "node:test";
import { toHex, type Address, type Hex } from "viem";
import { DomainRelayer, latestScheduledHeight } from "../src/relayer.js";

const spoke = "0x0000000000000000000000000000000000005afe" as Address;
const hub = "0x0000000000000000000000000000000000001234" as Address;
const key = (n: number): Hex => toHex(n, { size: 32 });

test("latestScheduledHeight is the largest multiple of the interval at or below the finalized height", () => {
  assert.equal(latestScheduledHeight(0n, 5n), 0n);
  assert.equal(latestScheduledHeight(4n, 5n), 0n);
  assert.equal(latestScheduledHeight(5n, 5n), 5n);
  assert.equal(latestScheduledHeight(23n, 5n), 20n);
  assert.throws(() => latestScheduledHeight(23n, 0n), /positive/);
});

test("the relayer refuses to start without domains or validator keys", () => {
  const submitterKey = key(1);
  assert.throws(() => new DomainRelayer({ l1RpcUrl: "http://localhost:8080", hub, submitterKey, domains: [] }), /no domains/);
  assert.throws(
    () => new DomainRelayer({ l1RpcUrl: "http://localhost:8080", hub, submitterKey, domains: [{ chainId: 85679n, spoke, validatorKeys: [] }] }),
    /no validator keys/,
  );
  const relayer = new DomainRelayer({
    l1RpcUrl: "http://localhost:8080",
    hub,
    submitterKey,
    domains: [{ chainId: 85679n, spoke, validatorKeys: [key(3)] }],
  });
  assert.deepEqual(relayer.status(), [
    {
      chainId: 85679n,
      spoke,
      scannedThrough: null,
      attested: null,
      batches: 0,
      recorded: 0,
      relayed: 0,
      lastAttestedAt: null,
      lastError: null,
    },
  ]);
});
