import assert from "node:assert/strict";
import { test } from "node:test";
import { encodeAbiParameters, encodeEventTopics, getAddress, zeroAddress, type Address, type PublicClient } from "viem";
import { ERC20_ABI, L2_BANK_ABI } from "../src/abi.js";
import { AccountIndex } from "../src/account-index.js";
import type { DemoDomain } from "../src/config.js";

const BANK = "0x00000000000000000000000000000000000000b1" as Address;
const LEDGER = "0x00000000000000000000000000000000000000e1" as Address;
const alice = getAddress("0x000000000000000000000000000000000000a11c");
const bob = getAddress("0x0000000000000000000000000000000000000b0b");
const START = 72_906_962n;

const domain = (startBlock: bigint): DemoDomain => ({
  chainId: 206751,
  spoke: zeroAddress,
  viewingKey: "0x",
  startBlock: Number(startBlock),
  l1Bridge: zeroAddress,
  domainBridge: "0x00000000000000000000000000000000000000d1",
  bank: BANK,
  token: "0x00000000000000000000000000000000000000f1",
});

const registered = (user: Address, block: bigint) => ({
  address: BANK,
  blockNumber: block,
  topics: encodeEventTopics({ abi: L2_BANK_ABI, eventName: "ReceiveAllowanceSet", args: { user } }),
  data: encodeAbiParameters([{ type: "uint256" }], [1n]),
});
const transfer = (from: Address, to: Address, block: bigint) => ({
  address: LEDGER,
  blockNumber: block,
  topics: encodeEventTopics({ abi: ERC20_ABI, eventName: "Transfer", args: { from, to } }),
  data: encodeAbiParameters([{ type: "uint256" }], [1n]),
});

/** A domain client over a fixed log list; records every getLogs range it is asked for. */
function fakeClient(head: { value: bigint }, logs: ReturnType<typeof registered>[], ledger: { value: Address }) {
  const ranges: [bigint, bigint][] = [];
  const client = {
    getBlockNumber: async () => head.value,
    readContract: async () => ledger.value,
    getLogs: async ({ address, fromBlock, toBlock }: { address: Address; fromBlock: bigint; toBlock: bigint }) => {
      assert.ok(toBlock - fromBlock < 1000n, "a log window spans at most 1000 blocks");
      ranges.push([fromBlock, toBlock]);
      return logs
        .filter((l) => l.address === address && l.blockNumber >= fromBlock && l.blockNumber <= toBlock)
        .map((l, i) => ({ ...l, logIndex: i, transactionIndex: 0, transactionHash: `0x${"0".repeat(64)}`, blockHash: `0x${"0".repeat(64)}`, removed: false }));
    },
  } as unknown as PublicClient;
  return { client, ranges };
}

test("the account index scans from the domain's start block, never from 0", async () => {
  const head = { value: START + 1500n };
  const { client, ranges } = fakeClient(head, [registered(alice, START + 10n), registered(bob, START + 1499n)], { value: zeroAddress });
  const index = new AccountIndex({ A: { domain: domain(START), client }, B: { domain: domain(START), client } }, () => {});
  await index.tick();
  assert.equal(ranges[0]![0], START);
  assert.deepEqual(index.accounts().A.customers.sort(), [alice, bob].sort());
});

test("the account index catches up over several passes and then reads only new blocks", async () => {
  const head = { value: START + 250_000n }; // more windows than one pass reads
  const { client, ranges } = fakeClient(head, [registered(alice, START + 249_999n)], { value: zeroAddress });
  const index = new AccountIndex({ A: { domain: domain(START), client }, B: { domain: domain(START), client } }, () => {});
  await index.tick();
  assert.deepEqual(index.accounts().A.customers, [], "not there yet after one pass");
  await index.tick();
  assert.deepEqual(index.accounts().A.customers, [alice], "caught up after the second pass");
  const scanned = ranges.length;
  head.value += 5n;
  await index.tick();
  assert.equal(ranges.length - scanned, 2, "one new window per bank once caught up");
});

test("the account index finds the ledger once it exists, scans it from the start, and leaves out the bank", async () => {
  const head = { value: START + 100n };
  const ledger = { value: zeroAddress as Address };
  const logs = [transfer(zeroAddress, alice, START + 5n), transfer(alice, BANK, START + 6n), transfer(alice, bob, START + 7n)];
  const { client } = fakeClient(head, logs, ledger);
  const index = new AccountIndex({ A: { domain: domain(START), client }, B: { domain: domain(START), client } }, () => {});
  await index.tick();
  assert.deepEqual(index.accounts().A.holders, [], "no ledger yet");
  ledger.value = LEDGER; // created by the first deposit
  await index.tick();
  assert.deepEqual(index.accounts().A.holders.sort(), [alice, bob].sort());
});

test("the account index lists the most recently active accounts first", async () => {
  const carol = getAddress("0x00000000000000000000000000000000000ca201");
  const head = { value: START + 100n };
  const filed = (user: Address, block: bigint) => ({
    address: BANK,
    blockNumber: block,
    topics: encodeEventTopics({ abi: L2_BANK_ABI, eventName: "TransferRequested", args: { requestId: 0n, user, recipient: bob } }),
    data: encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }, { type: "bool" }], [1n, 1n, false]),
  });
  const logs = [
    registered(alice, START + 1n),
    registered(bob, START + 2n),
    registered(carol, START + 3n),
    filed(alice, START + 50n), // alice files a payment order: her latest activity
    transfer(zeroAddress, bob, START + 10n),
    transfer(zeroAddress, carol, START + 20n),
    transfer(bob, alice, START + 30n),
  ];
  const { client } = fakeClient(head, logs, { value: LEDGER });
  const index = new AccountIndex({ A: { domain: domain(START), client }, B: { domain: domain(START), client } }, () => {});
  await index.tick();
  // Activity is per bank, across the registry and the ledger: alice filed an order (block 50),
  // bob last moved money (30), carol last at her ledger mint (20).
  assert.deepEqual(index.accounts().A.customers, [alice, bob, carol]);
  assert.deepEqual(index.accounts().A.holders, [alice, bob, carol]);
});

test("the ledger list holds every account: former holders at 0 and customers who never deposited", async () => {
  const carol = getAddress("0x00000000000000000000000000000000000ca201");
  const head = { value: START + 100n };
  const logs = [
    registered(alice, START + 1n),
    registered(carol, START + 2n), // KYC'd, never deposits
    transfer(zeroAddress, alice, START + 10n), // alice deposits ...
    transfer(alice, BANK, START + 20n), // ... and spends it all: balance 0, still an account
    transfer(zeroAddress, bob, START + 30n), // bob holds without being in this bank's registry
  ];
  const { client } = fakeClient(head, logs, { value: LEDGER });
  const index = new AccountIndex({ A: { domain: domain(START), client }, B: { domain: domain(START), client } }, () => {});
  await index.tick();
  assert.deepEqual(index.accounts().A.holders, [bob, alice, carol]);
  assert.deepEqual(index.accounts().A.customers, [alice, carol]);
});
