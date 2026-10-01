import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeFunctionData,
  getContractAddress,
  http,
  parseEventLogs,
  serializeSignature,
  toFunctionSelector,
  zeroHash,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { privateKeyToAccount, sign } from "viem/accounts";
import { loadArtifact } from "./artifacts.js";
import { setupDomain } from "./setup.js";
import { sequenceTransaction } from "./sequence.js";
import {
  fetchL1Messages,
  fetchDomainMessages,
  l1MessageDeliveryStatus,
  domainMessageDeliveryStatus,
  proveMessage,
  type L1DeliveryStatus,
  type RecordedMessage,
} from "./prover.js";
import { type DomainMessage, type MessageContext } from "./message.js";

/**
 * End-to-end exercise of the domain token bridge against a live L1-sequencing
 * node (monad single-node devnet with `--private-domain` /
 * `--private-domain-sequencer` pointing at the hub deployed here):
 *
 *   1. setup: hub + L1Bridge on the L1, spoke + DomainBridge seeded by sequencing
 *      their creation transactions through the hub;
 *   2. deposit: lock TestERC20 on the L1 — delivery is protocol-driven (the node
 *      derives a system transaction per hub L1MessageRecorded event and injects it
 *      as spoke.relayL1Message), so the CLI only watches the spoke until the mint lands;
 *   3. withdrawal: burn on the domain, finalize the domain batch, validator
 *      attests the state transition on the hub, prove and release on the L1;
 *   4. access control: deploy a token through `spoke.deployContract`, restrict
 *      `balanceOf` to its subject, and check that the execution client (which calls
 *      `spoke.canCall` before every domain CALL) denies both eth_call and sequenced
 *      transactions — including nested calls whose failure the caller catches — until the
 *      policy owner grants a reader.
 *
 * Configuration via env: L1_RPC_URL (default http://localhost:8080),
 * DOMAIN_CHAIN_ID (default (1 << 16) | 20143 = 85679), and VIEWING_KEY — the
 * domain viewing public key matching the PEM the node was started with
 * (`--private-domain <id> <spoke address> <key.pem>`, where the spoke address is
 * CREATE(admin, 0) on the domain = the hub address on the L1); every sequenced
 * transaction is encrypted to it. The well-known dev accounts below exist in
 * MONAD_DEVNET_ALLOC with huge balances.
 */

const L1_RPC_URL = process.env.L1_RPC_URL ?? "http://localhost:8080";
const DOMAIN_CHAIN_ID = BigInt(process.env.DOMAIN_CHAIN_ID ?? String((1n << 16n) | 20143n));
const DOMAIN_RPC_URL = process.env.DOMAIN_RPC_URL ?? `${L1_RPC_URL}/domain/${DOMAIN_CHAIN_ID}`;
// Domain viewing public key (65-byte uncompressed P-256 point). Unset => plaintext sequencing,
// which a node running with a receiver key for the domain drops.
const VIEWING_KEY = process.env.VIEWING_KEY as Hex | undefined;

// The hub address the running node's --private-domain-sequencer flag points at.
// Must equal CREATE(admin, 0), i.e. the admin's first L1 transaction ever.
const EXPECTED_HUB = (process.env.EXPECTED_HUB ?? "0x5FbDB2315678afecb367f032d93F642f64180aa3") as Address;

// Hardhat/Anvil dev keys, funded in the monad devnet genesis alloc.
const ADMIN_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as Hex; // acct 0: operator/seed
const VALIDATOR_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" as Hex; // acct 1
const ALICE_KEY = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a" as Hex; // acct 2: L1 depositor
const BOB_KEY = "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6" as Hex; // acct 3: domain recipient
const CAROL = "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65" as Address; // acct 4: L1 withdrawal recipient

const DEPOSIT = 100n * 10n ** 18n;
const WITHDRAWAL = 40n * 10n ** 18n;

const admin = privateKeyToAccount(ADMIN_KEY);
const validator = privateKeyToAccount(VALIDATOR_KEY);
const alice = privateKeyToAccount(ALICE_KEY);
const bob = privateKeyToAccount(BOB_KEY);

function step(label: string) {
  console.log(`\n=== ${label} ===`);
}

async function retry<T>(label: string, fn: () => Promise<T>, predicate: (v: T) => boolean, timeoutMs = 60_000): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  let lastError: unknown;
  for (;;) {
    try {
      const value = await fn();
      if (predicate(value)) return value;
      lastError = new Error(`predicate not satisfied (last value: ${String(value)})`);
    } catch (error) {
      lastError = error;
    }
    if (Date.now() > deadline) {
      throw new Error(`timeout waiting for ${label}: ${lastError instanceof Error ? lastError.message : String(lastError)}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 1_000));
  }
}

/**
 * Per-block domain log scan. The client's domain-scoped eth_getLogs fails with
 * "error traversing db" for a range spanning blocks in which the domain retained no
 * transactions (its per-block tables are simply absent), so query one block at a time and
 * treat errors as empty. A single-block query for such a quiet block does not fail either:
 * it serves the most recent domain block's logs stamped with the queried block number,
 * so the same message shows up once per quiet block after it. Keep the first sighting of
 * each message hash — that is its real block.
 */
async function fetchDomainMessagesPerBlock(
  domain: PublicClient,
  range: { fromBlock: bigint; toBlock: bigint },
  spoke: Address,
  context: MessageContext,
): Promise<RecordedMessage<DomainMessage>[]> {
  const messages: RecordedMessage<DomainMessage>[] = [];
  const seen = new Set<Hex>();
  for (let b = range.fromBlock; b <= range.toBlock; b++) {
    try {
      for (const recorded of await fetchDomainMessages(domain, { fromBlock: b, toBlock: b }, spoke, context)) {
        if (seen.has(recorded.messageHash)) continue;
        seen.add(recorded.messageHash);
        messages.push(recorded);
      }
    } catch {
      // domain-empty block: tables absent, treat as no events
    }
  }
  return messages;
}

/** Waits until the domain has executed the sequenced transaction, preferring the
 * domain-scoped receipt and reporting a revert immediately. */
async function waitForDomainTx(domain: PublicClient, hash: Hex, label: string) {
  const receipt = await retry(
    `${label} domain receipt`,
    async () => domain.getTransactionReceipt({ hash }).catch(() => null),
    (r) => r !== null,
    90_000,
  );
  if (receipt!.status !== "success") {
    throw new Error(`${label}: domain transaction reverted (hash ${hash})`);
  }
  console.log(`  domain receipt ok: ${label} (block ${receipt!.blockNumber}, gasUsed ${receipt!.gasUsed})`);
  return receipt!;
}

/** Waits for the domain receipt of a sequenced transaction and asserts that it reverted. */
async function expectDomainRevert(domain: PublicClient, hash: Hex, label: string) {
  const receipt = await retry(
    `${label} domain receipt`,
    async () => domain.getTransactionReceipt({ hash }).catch(() => null),
    (r) => r !== null,
    90_000,
  );
  if (receipt!.status !== "reverted") {
    throw new Error(`${label}: expected the domain transaction to revert, receipt status is ${receipt!.status}`);
  }
  console.log(`  domain receipt reverted as expected: ${label} (block ${receipt!.blockNumber}, gasUsed ${receipt!.gasUsed})`);
  return receipt!;
}

/**
 * Runs a domain eth_call and asserts that the client denied it. A denial surfaces as a
 * plain revert; "private domain is not configured" instead means the RPC was started
 * without `--private-domain-spoke` for this domain and is reported as a failure.
 */
async function expectCallDenied(label: string, fn: () => Promise<unknown>) {
  let value: unknown;
  try {
    value = await fn();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (message.includes("not configured")) {
      throw new Error(`${label}: ${message.split("\n")[0]}`);
    }
    console.log(`  denied as expected: ${label} (${message.split("\n")[0]})`);
    return;
  }
  throw new Error(`${label}: expected the call to be denied, it returned ${String(value)}`);
}

async function main() {
  // --- Clients ---
  const l1Probe = createPublicClient({ transport: http(L1_RPC_URL) });
  const l1ChainId = await l1Probe.getChainId();
  const l1Chain = defineChain({
    id: l1ChainId,
    name: `l1-${l1ChainId}`,
    nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
    rpcUrls: { default: { http: [L1_RPC_URL] } },
  });
  const l1 = createPublicClient({ chain: l1Chain, transport: http(L1_RPC_URL) });
  const domainChain = defineChain({
    id: Number(DOMAIN_CHAIN_ID),
    name: `domain-${DOMAIN_CHAIN_ID}`,
    nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
    rpcUrls: { default: { http: [DOMAIN_RPC_URL] } },
  });
  const domain = createPublicClient({ chain: domainChain, transport: http(DOMAIN_RPC_URL) });
  const adminWallet = createWalletClient({ account: admin, chain: l1Chain, transport: http(L1_RPC_URL) });
  const aliceWallet = createWalletClient({ account: alice, chain: l1Chain, transport: http(L1_RPC_URL) });
  const validatorWallet = createWalletClient({ account: validator, chain: l1Chain, transport: http(L1_RPC_URL) });

  console.log("L1 chain id:", l1ChainId);
  console.log("domain chain id:", DOMAIN_CHAIN_ID.toString());
  console.log("viewing key:", VIEWING_KEY ? `${VIEWING_KEY.slice(0, 12)}… (sequenced transactions are encrypted)` : "none (plaintext)");
  const domainReportedChainId = await domain.getChainId();
  if (BigInt(domainReportedChainId) !== DOMAIN_CHAIN_ID) {
    throw new Error(`domain RPC reports chain id ${domainReportedChainId}, expected ${DOMAIN_CHAIN_ID}`);
  }

  const hubArt = loadArtifact("DomainHub.sol", "DomainHub");
  const l1BridgeArt = loadArtifact("L1Bridge.sol", "L1Bridge");
  const spokeArt = loadArtifact("DomainSpoke.sol", "DomainSpoke");
  const domainBridgeArt = loadArtifact("DomainBridge.sol", "DomainBridge");
  const bridgedArt = loadArtifact("BridgedERC20.sol", "BridgedERC20");
  const tokenArt = loadArtifact("TestERC20.sol", "TestERC20");

  const confirm = async (hash: Hex, label: string) => {
    const receipt = await l1.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`${label}: L1 transaction reverted (${hash})`);
    console.log(`  L1 tx ok: ${label} (block ${receipt.blockNumber})`);
    return receipt;
  };

  // -------------------------------------------------------------------------
  step("1. domain setup (hub + L1Bridge on L1, spoke + bridge seeded via sequencing)");
  // -------------------------------------------------------------------------
  const adminNonce = await l1.getTransactionCount({ address: admin.address });
  if (adminNonce !== 0) {
    throw new Error(
      `admin ${admin.address} has L1 nonce ${adminNonce}; expected 0 so the hub lands at ${EXPECTED_HUB} ` +
        `(the address baked into the node's --private-domain-sequencer flag). Restart from a fresh chain.`,
    );
  }
  const hubDeployBlock = await l1.getBlockNumber();

  // The client consults the configured spoke before every domain call and fails closed
  // while the spoke has no code, so on a fresh chain even a plain call to an EOA is denied.
  await expectCallDenied("domain eth_call before the spoke exists (fail closed)", () =>
    domain.call({ to: admin.address, data: "0x", account: admin.address }),
  );

  const setup = await setupDomain({
    l1RpcUrl: L1_RPC_URL,
    adminKey: ADMIN_KEY,
    domainChainId: DOMAIN_CHAIN_ID,
    validators: [validator.address],
    quorum: 1n,
    viewingKey: VIEWING_KEY,
  });
  const { hub, l1Bridge, spoke, domainBridge } = setup;
  if (hub.toLowerCase() !== EXPECTED_HUB.toLowerCase()) {
    throw new Error(`hub deployed at ${hub}, but the node's scanner watches ${EXPECTED_HUB} — aborting`);
  }

  // The node's scanner should have executed the two seeded creation transactions.
  await retry("spoke code on domain", () => domain.getCode({ address: spoke }), (c) => !!c && c !== "0x", 90_000);
  await retry("bridge code on domain", () => domain.getCode({ address: domainBridge }), (c) => !!c && c !== "0x", 90_000);
  console.log("  spoke + domain bridge code present on the domain");

  // -------------------------------------------------------------------------
  step("2. L1 token setup (deploy TestERC20, mint to alice, allowlist)");
  // -------------------------------------------------------------------------
  const tokenDeployHash = await aliceWallet.deployContract({ abi: tokenArt.abi, bytecode: tokenArt.bytecode });
  const tokenReceipt = await confirm(tokenDeployHash, "deploy TestERC20");
  const token = tokenReceipt.contractAddress!;
  console.log("  TestERC20:", token);

  await confirm(
    await aliceWallet.writeContract({ address: token, abi: tokenArt.abi, functionName: "mint", args: [alice.address, 1000n * 10n ** 18n] }),
    "mint 1000 TEST to alice",
  );
  await confirm(
    await aliceWallet.writeContract({ address: token, abi: tokenArt.abi, functionName: "approve", args: [l1Bridge, 2n ** 256n - 1n] }),
    "alice approves L1Bridge",
  );
  await confirm(
    await adminWallet.writeContract({ address: l1Bridge, abi: l1BridgeArt.abi, functionName: "setTokenAllowed", args: [token, true] }),
    "allowlist TestERC20",
  );

  // -------------------------------------------------------------------------
  step("3. deposit: alice locks 100 TEST on the L1 for bob on the domain");
  // -------------------------------------------------------------------------
  await confirm(
    await aliceWallet.writeContract({
      address: l1Bridge,
      abi: l1BridgeArt.abi,
      functionName: "bridgeToDomain",
      args: [bob.address, token, DEPOSIT],
    }),
    "bridgeToDomain(bob, TEST, 100)",
  );

  // Off-chain listener: index the recorded L1 -> domain message from hub events.
  // eth_getLogs can lag the receipt path by a few blocks, so poll until the event shows up.
  const depositBatch = await retry(
    "L1MessageRecorded event",
    async () => fetchL1Messages(l1, DOMAIN_CHAIN_ID, { fromBlock: hubDeployBlock, toBlock: await l1.getBlockNumber() }, hub),
    (batch) => batch.length === 1,
  );
  const deposit = depositBatch[0]!;
  console.log(`  listener indexed L1MessageRecorded (nonce ${deposit.message.nonce}, hash ${deposit.messageHash})`);

  // Delivery is protocol-driven: the node derives a system transaction from the recorded
  // event (spoke.relayL1Message from the reserved system sender, in event order) and
  // injects it into the derived domain block. Nothing to submit — watch the spoke's
  // delivery queue until the message lands.
  let delivery: L1DeliveryStatus;
  try {
    delivery = await retry(
      "protocol delivery of the deposit message",
      () => l1MessageDeliveryStatus(domain, deposit, spoke),
      (status) => status !== "pending",
      120_000,
    );
  } catch (error) {
    throw new Error(
      `the domain never delivered the deposit message (nonce ${deposit.message.nonce}). ` +
        `The node must inject one system transaction per hub L1MessageRecorded event ` +
        `(spoke.relayL1Message from spoke.SYSTEM_RELAYER, in event order); if the running ` +
        `node does not support system-transaction injection yet, the deposit leg cannot ` +
        `complete. (${error instanceof Error ? error.message : String(error)})`,
    );
  }
  if (delivery === "failed") {
    throw new Error(
      `deposit delivered but the bridge call reverted (failedL1Messages[${deposit.messageHash}] is set); ` +
        `re-executable permissionlessly via spoke.retryL1Message with the message preimage`,
    );
  }
  console.log("  protocol delivered the message (spoke.nextL1Nonce advanced past it)");

  const bridgedToken = (await domain.readContract({
    address: domainBridge,
    abi: domainBridgeArt.abi,
    functionName: "bridgedTokens",
    args: [token],
  })) as Address;
  const bobBalance = (await domain.readContract({
    address: bridgedToken,
    abi: bridgedArt.abi,
    functionName: "balanceOf",
    args: [bob.address],
  })) as bigint;
  console.log(`  bridged token ${bridgedToken}, bob balance on domain: ${bobBalance}`);
  if (bobBalance !== DEPOSIT) throw new Error(`deposit mismatch: bob has ${bobBalance}, expected ${DEPOSIT}`);
  console.log("  ✅ L1 -> domain deposit complete");

  // -------------------------------------------------------------------------
  step("4. withdrawal: bob burns 40 TEST on the domain for carol on the L1");
  // -------------------------------------------------------------------------
  const bridgeToL1 = await sequenceTransaction({
    l1RpcUrl: L1_RPC_URL,
    hub,
    domainChainId: DOMAIN_CHAIN_ID,
    senderKey: BOB_KEY,
    to: domainBridge,
    data: encodeFunctionData({ abi: domainBridgeArt.abi, functionName: "bridgeToL1", args: [CAROL, token, WITHDRAWAL] }),
    gas: 500_000n,
    domainRpcUrl: DOMAIN_RPC_URL,
    viewingKey: VIEWING_KEY,
  });
  console.log("  sequenced domainBridge.bridgeToL1:", bridgeToL1.domainTxHash);
  await waitForDomainTx(domain, bridgeToL1.domainTxHash, "domainBridge.bridgeToL1");

  // Off-chain listener: index the recorded domain -> L1 messages from spoke events.
  const withdrawalBatch = await retry(
    "DomainMessageRecorded event",
    async () => fetchDomainMessagesPerBlock(domain, { fromBlock: hubDeployBlock, toBlock: await domain.getBlockNumber() }, spoke, { l1ChainId: BigInt(await l1.getChainId()), hub }),
    (batch) => batch.length === 1,
  );
  console.log(`  listener indexed ${withdrawalBatch.length} DomainMessageRecorded event(s)`);
  const withdrawalProof = proveMessage(withdrawalBatch, withdrawalBatch[0]!.messageHash);
  console.log("  computed anchor:", withdrawalProof.anchor);

  // Operator finalizes the domain batch on the spoke (sequenced tx).
  const finalizeDomain = await sequenceTransaction({
    l1RpcUrl: L1_RPC_URL,
    hub,
    domainChainId: DOMAIN_CHAIN_ID,
    senderKey: ADMIN_KEY,
    to: spoke,
    data: encodeFunctionData({ abi: spokeArt.abi, functionName: "finalizeDomainMessages", args: [] }),
    gas: 300_000n,
    domainRpcUrl: DOMAIN_RPC_URL,
    viewingKey: VIEWING_KEY,
  });
  console.log("  sequenced spoke.finalizeDomainMessages:", finalizeDomain.domainTxHash);
  await waitForDomainTx(domain, finalizeDomain.domainTxHash, "spoke.finalizeDomainMessages");
  const pendingAfter = (await domain.readContract({
    address: spoke,
    abi: spokeArt.abi,
    functionName: "getPendingDomainMessages",
    args: [],
  })) as Hex[];
  if (pendingAfter.length !== 0) throw new Error("spoke still has pending domain messages after finalize");

  // Validator attests the state transition carrying the anchor onto the hub.
  const committedBn = (await l1.readContract({
    address: hub,
    abi: hubArt.abi,
    functionName: "domainBlockNumbers",
    args: [DOMAIN_CHAIN_ID],
  })) as bigint;
  const nextBn = committedBn + 1n;
  const newStateRoot = zeroHash; // demo value; bridging only consumes the anchor
  const digest = (await l1.readContract({
    address: hub,
    abi: hubArt.abi,
    functionName: "stateTransitionDigest",
    args: [DOMAIN_CHAIN_ID, nextBn, newStateRoot, withdrawalProof.anchor],
  })) as Hex;
  const signature = serializeSignature(await sign({ hash: digest, privateKey: VALIDATOR_KEY }));
  await confirm(
    await validatorWallet.writeContract({
      address: hub,
      abi: hubArt.abi,
      functionName: "submitStateSignature",
      args: [DOMAIN_CHAIN_ID, nextBn, newStateRoot, withdrawalProof.anchor, signature],
    }),
    "hub.submitStateSignature (quorum 1 -> state advances)",
  );
  const anchorOnHub = await l1.readContract({
    address: hub,
    abi: hubArt.abi,
    functionName: "domainAnchors",
    args: [DOMAIN_CHAIN_ID, withdrawalProof.anchor],
  });
  if (!anchorOnHub) throw new Error("withdrawal anchor not recorded on the hub after quorum");

  // Anyone proves and relays the withdrawal through the hub (alice does).
  await confirm(
    await aliceWallet.writeContract({
      address: hub,
      abi: hubArt.abi,
      functionName: "relayDomainMessage",
      args: [withdrawalProof.message, withdrawalProof.anchor, withdrawalProof.proof],
      // Caller-selected budget for this test token's callback. Estimating the hub call
      // alone can underestimate gas because a failed delivery also returns successfully.
      gas: 500_000n,
    }),
    "hub.relayDomainMessage",
  );
  const withdrawalStatus = await domainMessageDeliveryStatus(
    l1, withdrawalProof.message, { l1ChainId: BigInt(await l1.getChainId()), hub },
  );
  if (withdrawalStatus !== "delivered") {
    throw new Error(`withdrawal delivery ${withdrawalStatus}; failed calls can be retried via hub.retryDomainMessage`);
  }

  // -------------------------------------------------------------------------
  step("5. access control: the client calls spoke.canCall before every domain CALL");
  // -------------------------------------------------------------------------
  const readerArt = loadArtifact("BalanceReader.sol", "BalanceReader");
  const BALANCE_OF = toFunctionSelector("balanceOf(address)");
  const PRIVATE_SUPPLY = 1000n * 10n ** 18n;
  const sequence = (senderKey: Hex, to: Address, data: Hex, gas = 300_000n) =>
    sequenceTransaction({
      l1RpcUrl: L1_RPC_URL,
      hub,
      domainChainId: DOMAIN_CHAIN_ID,
      senderKey,
      to,
      data,
      gas,
      domainRpcUrl: DOMAIN_RPC_URL,
      viewingKey: VIEWING_KEY,
    });

  // Contracts get a policy owner only when created through spoke.deployContract (CREATE from
  // the spoke): the admin deploys a fresh TestERC20 and the BalanceReader probe that way.
  const deployViaSpoke = async (initCode: Hex, label: string): Promise<Address> => {
    const spokeNonce = await domain.getTransactionCount({ address: spoke });
    const predicted = getContractAddress({ from: spoke, nonce: BigInt(spokeNonce) });
    const seq = await sequence(
      ADMIN_KEY,
      spoke,
      encodeFunctionData({ abi: spokeArt.abi, functionName: "deployContract", args: [initCode, admin.address] }),
      3_000_000n,
    );
    const receipt = await waitForDomainTx(domain, seq.domainTxHash, `spoke.deployContract(${label}, policyOwner=admin)`);
    const [log] = parseEventLogs({ abi: spokeArt.abi, eventName: "ContractDeployed", logs: receipt.logs });
    const emitted = (log?.args as { target?: Address } | undefined)?.target;
    if (emitted && emitted.toLowerCase() !== predicted.toLowerCase()) {
      throw new Error(`${label}: ContractDeployed target ${emitted} != CREATE(spoke, ${spokeNonce}) = ${predicted}`);
    }
    const deployed = emitted ?? predicted;
    if (!emitted) console.log(`  (no ContractDeployed log in the domain receipt; using CREATE(spoke, ${spokeNonce}))`);
    await retry(`${label} code`, () => domain.getCode({ address: deployed }), (c) => !!c && c !== "0x", 30_000);
    const owner = (await domain.readContract({ address: spoke, abi: spokeArt.abi, functionName: "policyOwners", args: [deployed] })) as Address;
    if (owner.toLowerCase() !== admin.address.toLowerCase()) throw new Error(`${label}: policy owner is ${owner}, expected admin`);
    console.log(`  ${label} deployed through the spoke at ${deployed} (policy owner: admin)`);
    return deployed;
  };
  const privateToken = await deployViaSpoke(tokenArt.bytecode, "TestERC20");
  const reader = await deployViaSpoke(readerArt.bytecode, "BalanceReader");

  const mint = await sequence(
    ADMIN_KEY,
    privateToken,
    encodeFunctionData({ abi: tokenArt.abi, functionName: "mint", args: [alice.address, PRIVATE_SUPPLY] }),
  );
  await waitForDomainTx(domain, mint.domainTxHash, "privateToken.mint(alice, 1000)");

  const balanceOfData = (subject: Address) => encodeFunctionData({ abi: tokenArt.abi, functionName: "balanceOf", args: [subject] });
  const readBalance = (from: Address, subject: Address) =>
    domain.readContract({ address: privateToken, abi: tokenArt.abi, functionName: "balanceOf", args: [subject], account: from }) as Promise<bigint>;

  // No rule yet: canCall returns true for everyone, so bob can read alice's balance.
  const openRead = await readBalance(bob.address, alice.address);
  if (openRead !== PRIVATE_SUPPLY) throw new Error(`unrestricted read returned ${openRead}, expected ${PRIVATE_SUPPLY}`);
  console.log(`  before any rule, bob reads alice's balance: ${openRead}`);

  // The policy owner restricts balanceOf to its subject (argument 0) and approved readers.
  const restrict = await sequence(
    ADMIN_KEY,
    spoke,
    encodeFunctionData({ abi: spokeArt.abi, functionName: "setAccessControl", args: [privateToken, BALANCE_OF, true, 0] }),
  );
  await waitForDomainTx(domain, restrict.domainTxHash, "spoke.setAccessControl(privateToken, balanceOf, requireSubjectMatch, arg 0)");
  const [ruleOn, ruleIndex] = (await domain.readContract({
    address: spoke,
    abi: spokeArt.abi,
    functionName: "accessControl",
    args: [privateToken, BALANCE_OF],
  })) as [boolean, number];
  if (!ruleOn || ruleIndex !== 0) throw new Error(`rule not stored: (${ruleOn}, ${ruleIndex})`);

  // The spoke's own verdicts, read directly.
  const verdict = (caller: Address, subject: Address) =>
    domain.readContract({ address: spoke, abi: spokeArt.abi, functionName: "canCall", args: [caller, privateToken, balanceOfData(subject)] }) as Promise<boolean>;
  if ((await verdict(alice.address, alice.address)) !== true) throw new Error("canCall(alice, token, balanceOf(alice)) should be true");
  if ((await verdict(bob.address, alice.address)) !== false) throw new Error("canCall(bob, token, balanceOf(alice)) should be false");
  console.log("  spoke.canCall: alice->balanceOf(alice) true, bob->balanceOf(alice) false");

  // eth_call on the domain route runs the same check with caller = `from`.
  const aliceOwn = await readBalance(alice.address, alice.address);
  if (aliceOwn !== PRIVATE_SUPPLY) throw new Error(`alice's own read returned ${aliceOwn}`);
  console.log(`  eth_call alice -> balanceOf(alice): ${aliceOwn}`);
  const bobOwn = await readBalance(bob.address, bob.address);
  if (bobOwn !== 0n) throw new Error(`bob's own read returned ${bobOwn}`);
  console.log(`  eth_call bob -> balanceOf(bob): ${bobOwn}`);
  await expectCallDenied("eth_call bob -> balanceOf(alice)", () => readBalance(bob.address, alice.address));
  await expectCallDenied("eth_call admin (policy owner, no grant) -> balanceOf(alice)", () => readBalance(admin.address, alice.address));
  const supply = (await domain.readContract({ address: privateToken, abi: tokenArt.abi, functionName: "totalSupply", account: bob.address })) as bigint;
  if (supply !== PRIVATE_SUPPLY) throw new Error(`totalSupply (unrestricted selector) returned ${supply}`);
  console.log(`  eth_call bob -> totalSupply() (unrestricted selector): ${supply}`);

  // Sequenced transactions: a denied frame reverts the whole transaction.
  const bobDirect = await sequence(BOB_KEY, privateToken, balanceOfData(alice.address));
  await expectDomainRevert(domain, bobDirect.domainTxHash, "bob -> privateToken.balanceOf(alice)");
  const aliceDirect = await sequence(ALICE_KEY, privateToken, balanceOfData(alice.address));
  await waitForDomainTx(domain, aliceDirect.domainTxHash, "alice -> privateToken.balanceOf(alice)");

  // Nested call: the reader contract is the caller the client authenticates, and its
  // try/catch cannot hide the denial — the client reverts the transaction at the root.
  const tryReadAlice = encodeFunctionData({ abi: readerArt.abi, functionName: "tryRead", args: [privateToken, alice.address] });
  const bobViaReader = await sequence(BOB_KEY, reader, tryReadAlice);
  await expectDomainRevert(domain, bobViaReader.domainTxHash, "bob -> reader.tryRead(privateToken, alice) [inner denial caught by try/catch]");
  const aliceViaReader = await sequence(ALICE_KEY, reader, tryReadAlice);
  await expectDomainRevert(domain, aliceViaReader.domainTxHash, "alice -> reader.tryRead(privateToken, alice) [caller is the reader, not alice]");
  const readsBeforeGrant = (await domain.readContract({ address: reader, abi: readerArt.abi, functionName: "reads" })) as bigint;
  if (readsBeforeGrant !== 0n) throw new Error(`reader state changed by denied transactions: reads = ${readsBeforeGrant}`);

  // The policy owner approves the reader contract for alice's balance; the nested read now works.
  const grant = await sequence(
    ADMIN_KEY,
    spoke,
    encodeFunctionData({ abi: spokeArt.abi, functionName: "setReaderAllowed", args: [privateToken, BALANCE_OF, alice.address, reader, true] }),
  );
  await waitForDomainTx(domain, grant.domainTxHash, "spoke.setReaderAllowed(privateToken, balanceOf, subject alice, reader)");
  const bobViaApprovedReader = await sequence(
    BOB_KEY,
    reader,
    encodeFunctionData({ abi: readerArt.abi, functionName: "read", args: [privateToken, alice.address] }),
  );
  await waitForDomainTx(domain, bobViaApprovedReader.domainTxHash, "bob -> reader.read(privateToken, alice) [reader approved]");
  const lastBalance = (await domain.readContract({ address: reader, abi: readerArt.abi, functionName: "lastBalance" })) as bigint;
  if (lastBalance !== PRIVATE_SUPPLY) throw new Error(`reader stored ${lastBalance}, expected ${PRIVATE_SUPPLY}`);
  console.log(`  reader.lastBalance after the approved read: ${lastBalance}`);
  const bobOwnViaReader = await sequence(
    BOB_KEY,
    reader,
    encodeFunctionData({ abi: readerArt.abi, functionName: "tryRead", args: [privateToken, bob.address] }),
  );
  await expectDomainRevert(domain, bobOwnViaReader.domainTxHash, "bob -> reader.tryRead(privateToken, bob) [grant is per subject]");

  // eth_estimateGas on the domain route accounts for the canCall frames.
  const estimate = await domain.estimateContractGas({
    address: privateToken,
    abi: tokenArt.abi,
    functionName: "transfer",
    args: [bob.address, 1n],
    account: alice.address,
  });
  console.log(`  eth_estimateGas alice -> privateToken.transfer(bob, 1): ${estimate}`);
  console.log("  ✅ access control enforced by the client for eth_call and sequenced transactions");

  // -------------------------------------------------------------------------
  step("6. final accounting");
  // -------------------------------------------------------------------------
  const carolBalance = (await l1.readContract({ address: token, abi: tokenArt.abi, functionName: "balanceOf", args: [CAROL] })) as bigint;
  const lockedCollateral = (await l1.readContract({ address: token, abi: tokenArt.abi, functionName: "balanceOf", args: [l1Bridge] })) as bigint;
  const bobAfter = (await domain.readContract({ address: bridgedToken, abi: bridgedArt.abi, functionName: "balanceOf", args: [bob.address] })) as bigint;
  const bridgedSupply = (await domain.readContract({ address: bridgedToken, abi: bridgedArt.abi, functionName: "totalSupply", args: [] })) as bigint;

  console.log(`  carol L1 balance:        ${carolBalance} (expected ${WITHDRAWAL})`);
  console.log(`  locked collateral:       ${lockedCollateral} (expected ${DEPOSIT - WITHDRAWAL})`);
  console.log(`  bob domain balance:   ${bobAfter} (expected ${DEPOSIT - WITHDRAWAL})`);
  console.log(`  bridged total supply:    ${bridgedSupply} (expected ${DEPOSIT - WITHDRAWAL})`);

  if (carolBalance !== WITHDRAWAL) throw new Error("carol did not receive the withdrawal");
  if (lockedCollateral !== DEPOSIT - WITHDRAWAL) throw new Error("locked collateral mismatch");
  if (bobAfter !== DEPOSIT - WITHDRAWAL) throw new Error("bob domain balance mismatch");
  if (bridgedSupply !== DEPOSIT - WITHDRAWAL) throw new Error("bridged supply mismatch");

  console.log("\n✅ end-to-end deposit + withdrawal + access control succeeded");
  console.log(JSON.stringify({ hub, l1Bridge, spoke, domainBridge, token, bridgedToken, privateToken, reader }, null, 2));
}

main().catch((error) => {
  console.error("\n❌ e2e failed:", error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
