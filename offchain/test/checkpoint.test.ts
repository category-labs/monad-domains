import assert from "node:assert/strict";
import { test } from "node:test";
import { keccak256, toHex, zeroHash, type Address, type Chain, type Hex, type PublicClient, type WalletClient } from "viem";
import {
  attestCheckpoint, batchRoot, buildCheckpoint, fetchDomainMessageIds, nextCheckpointHeight, type Checkpoint,
} from "../src/checkpoint.js";
import { root } from "../src/merkle.js";

const addr = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as Address;
const hub = addr(1);
const spoke = addr(2);
const ids: Hex[] = Array.from({ length: 5 }, (_, i) => keccak256(toHex(`id-${i}`)));

test("nextCheckpointHeight is the smallest scheduled slot above the hub's commitment, once finalized", () => {
  // Validators with different finality lags derive the same slot.
  assert.equal(nextCheckpointHeight(0n, 10n, 34n), 10n);
  assert.equal(nextCheckpointHeight(0n, 10n, 41n), 10n);
  // A validator whose node has not finalized the slot waits rather than picking another.
  assert.equal(nextCheckpointHeight(10n, 10n, 19n), null);
  assert.equal(nextCheckpointHeight(10n, 10n, 20n), 20n);
  // The rule only depends on the hub's commitment, even after an off-rule attestation.
  assert.equal(nextCheckpointHeight(25n, 10n, 100n), 30n);
  assert.throws(() => nextCheckpointHeight(0n, 0n, 1n), /positive/);
});

test("batchRoot is zero for an empty batch and the merkle root otherwise", () => {
  assert.equal(batchRoot([]), zeroHash);
  assert.equal(batchRoot(ids), root(ids));
});

test("fetchDomainMessageIds reads the spoke's mapping nonce by nonce at the attested height", async () => {
  const calls: Record<string, unknown>[] = [];
  const domain = {
    readContract: async (request: { functionName: string; args: [bigint]; blockNumber: bigint }) => {
      calls.push(request);
      return ids[Number(request.args[0])] ?? zeroHash;
    },
  } as unknown as PublicClient;
  assert.deepEqual(await fetchDomainMessageIds(domain, spoke, 1n, 5n, 10n, 2n), ids.slice(1, 5));
  assert.deepEqual(calls.map((c) => c.args), [[1n], [2n], [3n], [4n]]);
  for (const call of calls) {
    assert.equal(call.functionName, "domainMessageIds");
    assert.equal(call.blockNumber, 10n);
  }
  assert.deepEqual(await fetchDomainMessageIds(domain, spoke, 3n, 3n, 10n), []);
  await assert.rejects(fetchDomainMessageIds(domain, spoke, 4n, 6n, 10n), /no message id at nonce 5/);
});

function hubClient(stateNonce: bigint, attested: bigint, calls: Record<string, unknown>[] = []): PublicClient {
  return {
    getBlockNumber: async () => 99n,
    readContract: async (request: { functionName: string }) => {
      calls.push(request);
      if (request.functionName === "stateNonces") return stateNonce;
      if (request.functionName === "domainBlockNumbers") return attested;
      throw new Error(`unexpected hub read ${request.functionName}`);
    },
  } as unknown as PublicClient;
}

function domainClient(count: bigint, stateRoot: Hex, calls: Record<string, unknown>[] = []): PublicClient {
  return {
    request: async ({ method }: { method: string }) => {
      assert.equal(method, "monad_getDomainHeader");
      return { number: "0x8", stateRoot, parentHash: zeroHash, timestamp: "0x0" };
    },
    readContract: async (request: { functionName: string; args?: [bigint]; blockNumber: bigint }) => {
      calls.push(request);
      if (request.functionName === "domainMessageCount") return count;
      if (request.functionName === "domainMessageIds") return ids[Number(request.args![0])] ?? zeroHash;
      throw new Error(`unexpected domain read ${request.functionName}`);
    },
  } as unknown as PublicClient;
}

test("buildCheckpoint pins hub reads to one block, never reads state at height 0, and hashes ids read per nonce", async () => {
  const l1Calls: Record<string, unknown>[] = [];
  const domainCalls: Record<string, unknown>[] = [];
  const stateRoot = keccak256(toHex("state"));
  const checkpoint = await buildCheckpoint({
    l1: hubClient(0n, 0n, l1Calls),
    domain: domainClient(5n, stateRoot, domainCalls),
    hub, spoke, domainChainId: 7777n, height: 10n, idPageSize: 2n,
  });
  assert.equal(checkpoint.stateNonce, 0n);
  assert.equal(checkpoint.previousBlockNumber, 0n);
  assert.equal(checkpoint.fromNonce, 0n);
  assert.equal(checkpoint.toNonce, 5n);
  assert.equal(checkpoint.anchor, root(ids));
  assert.equal(checkpoint.stateRoot, stateRoot);
  for (const call of l1Calls) assert.equal(call.blockNumber, 99n, "nonce and height come from the same L1 block");
  const countReads = domainCalls.filter((c) => c.functionName === "domainMessageCount");
  assert.deepEqual(countReads.map((c) => c.blockNumber), [10n], "no count read at height 0 before the first attestation");
  const reads = domainCalls.filter((c) => c.functionName === "domainMessageIds");
  assert.deepEqual(reads.map((c) => c.args), [[0n], [1n], [2n], [3n], [4n]]);
  for (const read of reads) assert.equal(read.blockNumber, 10n);
});

test("buildCheckpoint starts the batch at the previous checkpoint's count and anchors zero when idle", async () => {
  const domainCalls: Record<string, unknown>[] = [];
  const checkpoint = await buildCheckpoint({
    l1: hubClient(3n, 30n),
    domain: domainClient(7n, zeroHash, domainCalls),
    hub, spoke, domainChainId: 7777n, height: 40n,
  });
  assert.equal(checkpoint.stateNonce, 3n);
  assert.equal(checkpoint.previousBlockNumber, 30n);
  assert.deepEqual([checkpoint.fromNonce, checkpoint.toNonce], [7n, 7n]);
  assert.equal(checkpoint.anchor, zeroHash);
  const countReads = domainCalls.filter((c) => c.functionName === "domainMessageCount");
  assert.deepEqual(countReads.map((c) => c.blockNumber), [30n, 40n]);
  assert.equal(domainCalls.filter((c) => c.functionName === "domainMessageIds").length, 0);

  await assert.rejects(
    buildCheckpoint({ l1: hubClient(3n, 30n), domain: domainClient(7n, zeroHash), hub, spoke, domainChainId: 7777n, height: 30n }),
    /not above/,
  );
});

test("attestCheckpoint refuses a checkpoint built against a hub state the hub has moved past", async () => {
  const checkpoint: Checkpoint = {
    domainChainId: 7777n, domainBlockNumber: 30n, stateRoot: zeroHash, anchor: root(ids.slice(0, 2)),
    fromNonce: 0n, toNonce: 2n, previousBlockNumber: 10n, stateNonce: 0n,
  };
  const l1 = {
    readContract: async ({ functionName }: { functionName: string }) => {
      if (functionName === "stateNonces") return 1n;
      throw new Error(`unexpected hub read ${functionName}`);
    },
  } as unknown as PublicClient;
  const submitter = { writeContract: async () => { throw new Error("must not sign or submit"); } } as unknown as WalletClient;
  await assert.rejects(
    attestCheckpoint({ l1, submitter, chain: { id: 1 } as unknown as Chain, hub, checkpoint, validatorKeys: [] }),
    /advanced to state nonce 1 .* nonce 0/,
  );
});
