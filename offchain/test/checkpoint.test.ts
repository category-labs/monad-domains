import assert from "node:assert/strict";
import { test } from "node:test";
import {
  BlockNotFoundError, keccak256, toHex, zeroHash, type Address, type Chain, type Hex, type PublicClient, type WalletClient,
} from "viem";
import {
  attestCheckpoint, batchRoot, buildCheckpoint, domainBlockAt, fetchDomainMessageIds, getDomainHeader,
  nextActiveCheckpointHeight, nextCheckpointHeight, type Checkpoint,
} from "../src/checkpoint.js";
import { root } from "../src/merkle.js";

const addr = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as Address;
const hub = addr(1);
const spoke = addr(2);
const ids: Hex[] = Array.from({ length: 5 }, (_, i) => keccak256(toHex(`id-${i}`)));

test("nextCheckpointHeight is the smallest scheduled slot above the hub's last attested height, once finalized", () => {
  // Validators with different finality lags derive the same slot.
  assert.equal(nextCheckpointHeight(0n, 10n, 34n), 10n);
  assert.equal(nextCheckpointHeight(0n, 10n, 41n), 10n);
  // A validator whose node has not finalized the slot waits rather than picking another.
  assert.equal(nextCheckpointHeight(10n, 10n, 19n), null);
  assert.equal(nextCheckpointHeight(10n, 10n, 20n), 20n);
  // The rule only depends on the hub's attested height, even after an off-rule attestation.
  assert.equal(nextCheckpointHeight(25n, 10n, 100n), 30n);
  assert.throws(() => nextCheckpointHeight(0n, 0n, 1n), /positive/);
});

test("nextActiveCheckpointHeight is the first scheduled slot that covers the oldest unattested input", () => {
  assert.equal(nextActiveCheckpointHeight(10n, 10n, 100n, null), null);
  assert.equal(nextActiveCheckpointHeight(10n, 10n, 100n, 7n), 70n);
  assert.equal(nextActiveCheckpointHeight(10n, 10n, 69n, 7n), null);
});

test("batchRoot is zero for an empty batch and the merkle root otherwise", () => {
  assert.equal(batchRoot([]), zeroHash);
  assert.equal(batchRoot(ids), root(ids));
});

test("fetchDomainMessageIds reads the spoke's mapping nonce by nonce at one domain block", async () => {
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

/** Timestamp of L1 block `number`, which the domain block derived from it copies. */
const l1Timestamp = (number: bigint) => 1_000n + number;

/**
 * The hub on an L1 at block 99. `domainBlocks` is what `latestDomainBlock` returns as of each
 * L1 height: `[l1BlockNumber, domainBlockNumber]`, zeros before the domain was registered.
 */
function hubClient(
  stateNonce: bigint,
  attested: bigint,
  domainBlocks: Record<string, [bigint, bigint]> = {},
  calls: Record<string, unknown>[] = [],
): PublicClient {
  return {
    getBlockNumber: async () => 99n,
    getBlock: async ({ blockNumber }: { blockNumber: bigint }) => ({ number: blockNumber, timestamp: l1Timestamp(blockNumber) }),
    readContract: async (request: { functionName: string; blockNumber?: bigint }) => {
      calls.push(request);
      if (request.functionName === "stateNonces") return stateNonce;
      if (request.functionName === "domainBlockNumbers") return attested;
      if (request.functionName === "latestDomainBlock") return domainBlocks[String(request.blockNumber)] ?? [0n, 0n];
      throw new Error(`unexpected hub read ${request.functionName}`);
    },
  } as unknown as PublicClient;
}

/**
 * A domain RPC whose blocks are `blocks`: domain block number to the L1 block it is derived
 * from. Every block has `stateRoot`.
 */
function domainClient(
  count: bigint,
  stateRoot: Hex,
  blocks: Record<string, bigint> = {},
  calls: Record<string, unknown>[] = [],
): PublicClient {
  return {
    getBlock: async ({ blockNumber }: { blockNumber: bigint }) => {
      const l1Block = blocks[String(blockNumber)];
      if (l1Block === undefined) throw new BlockNotFoundError({ blockNumber });
      return { number: blockNumber, hash: keccak256(toHex(blockNumber)), parentHash: zeroHash, stateRoot, timestamp: l1Timestamp(l1Block) };
    },
    readContract: async (request: { functionName: string; args?: [bigint]; blockNumber: bigint }) => {
      calls.push(request);
      if (request.functionName === "domainMessageCount") return count;
      if (request.functionName === "domainMessageIds") return ids[Number(request.args![0])] ?? zeroHash;
      throw new Error(`unexpected domain read ${request.functionName}`);
    },
  } as unknown as PublicClient;
}

test("domainBlockAt reads the hub's latest domain block as of an L1 height", async () => {
  const calls: Record<string, unknown>[] = [];
  const l1 = hubClient(0n, 0n, { "10": [9n, 4n] }, calls);
  assert.deepEqual(await domainBlockAt(l1, hub, 7777n, 10n), { number: 4n, l1BlockNumber: 9n });
  assert.equal(calls[0]!.blockNumber, 10n, "the hub is read at the L1 height itself");
  assert.equal(await domainBlockAt(l1, hub, 7777n, 5n), null, "the domain is not registered yet");
});

test("getDomainHeader serves the block the hub names, once the client executed it", async () => {
  const stateRoot = keccak256(toHex("state"));
  const l1 = hubClient(0n, 0n, { "10": [9n, 4n] });
  const source = (domain: PublicClient) => ({ l1, domain, hub, domainChainId: 7777n });

  const header = await getDomainHeader(source(domainClient(0n, stateRoot, { "4": 9n })), 10n);
  assert.deepEqual([header!.number, header!.l1BlockNumber, header!.stateRoot, header!.timestamp], [4n, 9n, stateRoot, l1Timestamp(9n)]);
  assert.equal(await getDomainHeader(source(domainClient(0n, stateRoot)), 5n), null, "not registered at that height");
  await assert.rejects(getDomainHeader(source(domainClient(0n, stateRoot, { "3": 8n })), 10n), /has not executed block 4/);
  // A block with that number that was derived from another L1 block belongs to another chain.
  await assert.rejects(getDomainHeader(source(domainClient(0n, stateRoot, { "4": 7n })), 10n), /serves another chain/);
});

test("buildCheckpoint pins hub reads to one block, reads no state before the first attestation, and hashes ids read per nonce", async () => {
  const l1Calls: Record<string, unknown>[] = [];
  const domainCalls: Record<string, unknown>[] = [];
  const stateRoot = keccak256(toHex("state"));
  // As of the checkpoint's L1 height 10, the domain's latest block is 4, derived from L1 block 9.
  const checkpoint = await buildCheckpoint({
    l1: hubClient(0n, 0n, { "10": [9n, 4n] }, l1Calls),
    domain: domainClient(5n, stateRoot, { "4": 9n }, domainCalls),
    hub, spoke, domainChainId: 7777n, height: 10n, idPageSize: 2n,
  });
  assert.equal(checkpoint.stateNonce, 0n);
  assert.equal(checkpoint.previousBlockNumber, 0n);
  assert.equal(checkpoint.domainBlockNumber, 10n, "the hub is told the L1 height");
  assert.deepEqual(checkpoint.domainBlock, { number: 4n, l1BlockNumber: 9n });
  assert.equal(checkpoint.fromNonce, 0n);
  assert.equal(checkpoint.toNonce, 5n);
  assert.equal(checkpoint.anchor, root(ids));
  assert.equal(checkpoint.blockHash, keccak256(toHex(4n)));
  for (const call of l1Calls.filter((c) => c.functionName !== "latestDomainBlock")) {
    assert.equal(call.blockNumber, 99n, "nonce and height come from the same L1 block");
  }
  assert.deepEqual(
    l1Calls.filter((c) => c.functionName === "latestDomainBlock").map((c) => c.blockNumber),
    [10n],
    "the previous height is not located before the first attestation",
  );
  const countReads = domainCalls.filter((c) => c.functionName === "domainMessageCount");
  assert.deepEqual(countReads.map((c) => c.blockNumber), [4n], "the domain is read at its own block number");
  const reads = domainCalls.filter((c) => c.functionName === "domainMessageIds");
  assert.deepEqual(reads.map((c) => c.args), [[0n], [1n], [2n], [3n], [4n]]);
  for (const read of reads) assert.equal(read.blockNumber, 4n);
});

test("buildCheckpoint starts the batch at the previous checkpoint's count and anchors zero when idle", async () => {
  const domainCalls: Record<string, unknown>[] = [];
  // No input since L1 block 25: the domain's latest block is 6 at both heights.
  const domainBlocks: Record<string, [bigint, bigint]> = { "30": [25n, 6n], "40": [25n, 6n] };
  const checkpoint = await buildCheckpoint({
    l1: hubClient(3n, 30n, domainBlocks),
    domain: domainClient(7n, zeroHash, { "6": 25n }, domainCalls),
    hub, spoke, domainChainId: 7777n, height: 40n,
  });
  assert.equal(checkpoint.stateNonce, 3n);
  assert.equal(checkpoint.previousBlockNumber, 30n);
  assert.deepEqual([checkpoint.fromNonce, checkpoint.toNonce], [7n, 7n]);
  assert.equal(checkpoint.anchor, zeroHash);
  const countReads = domainCalls.filter((c) => c.functionName === "domainMessageCount");
  assert.deepEqual(countReads.map((c) => c.blockNumber), [6n, 6n]);
  assert.equal(domainCalls.filter((c) => c.functionName === "domainMessageIds").length, 0);

  await assert.rejects(
    buildCheckpoint({ l1: hubClient(3n, 30n, domainBlocks), domain: domainClient(7n, zeroHash, { "6": 25n }), hub, spoke, domainChainId: 7777n, height: 30n }),
    /not above/,
  );
  await assert.rejects(
    buildCheckpoint({ l1: hubClient(0n, 0n), domain: domainClient(0n, zeroHash), hub, spoke, domainChainId: 7777n, height: 10n }),
    /not registered as of L1 height 10/,
  );
});

test("attestCheckpoint refuses a checkpoint built against a hub state the hub has moved past", async () => {
  const checkpoint: Checkpoint = {
    domainChainId: 7777n, domainBlockNumber: 30n, domainBlock: { number: 6n, l1BlockNumber: 25n },
    blockHash: zeroHash, anchor: root(ids.slice(0, 2)),
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
