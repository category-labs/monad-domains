import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeDeployData,
  encodeFunctionData,
  http,
  parseEventLogs,
  type Address,
  type Hex,
  type PublicClient,
  zeroAddress,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { loadArtifact } from "./artifacts.js";
import { setupDomain } from "./setup.js";
import { sequenceTransaction } from "./sequence.js";
import { attestCheckpoint, buildCheckpoint, HUB_CHECKPOINT_ABI } from "./checkpoint.js";
import { encryptMessage } from "./encryption.js";
import {
  decodeDomainMessage,
  isEncryptedDomainMessage,
  MessageKind,
  type DomainMessage,
  type MessageContext,
  type MessagePlaintext,
} from "./message.js";
import {
  ENCRYPTED_L1_MESSAGE_RECORDED_EVENT,
  fetchDomainBatch,
  fetchL1Messages,
  findBatchForNonce,
  proveMessage,
} from "./prover.js";
import { routedMessageDeliveryStatus } from "./routing.js";

/**
 * End-to-end domain -> domain messaging against a fresh single-node devnet serving two
 * domains: set up both on one hub, deploy a receiver on B, record a plaintext message, a
 * ciphertext sealed to the wrong key and one sealed to B's key on spoke A in one batch, attest,
 * relay all three and check the hub's events and B's deliveries (the wrong-key one is skipped).
 *
 * Env: L1_RPC_URL (default http://localhost:8080), DOMAIN_A_CHAIN_ID (85679),
 * DOMAIN_B_CHAIN_ID (151215), VIEWING_KEY_A / VIEWING_KEY_B (required: the node's keys),
 * CHECKPOINT_INTERVAL (5), EXPECTED_HUB (the node's `--private-domain-sequencer`; the chain
 * must be fresh so the admin's first L1 transaction deploys the hub there), DOMAIN_ACCESS_KEY
 * (signs the domain routes' access token; default admin, the devnet's `--domain-operator`).
 */

const L1_RPC_URL = process.env.L1_RPC_URL ?? "http://localhost:8080";
const DOMAIN_A = BigInt(process.env.DOMAIN_A_CHAIN_ID ?? String((1n << 16n) | 20143n));
const DOMAIN_B = BigInt(process.env.DOMAIN_B_CHAIN_ID ?? String((2n << 16n) | 20143n));
const CHECKPOINT_INTERVAL = BigInt(process.env.CHECKPOINT_INTERVAL ?? "5");
const VIEWING_KEY_A = process.env.VIEWING_KEY_A as Hex | undefined;
const VIEWING_KEY_B = process.env.VIEWING_KEY_B as Hex | undefined;
const EXPECTED_HUB = (process.env.EXPECTED_HUB ?? "0x5FbDB2315678afecb367f032d93F642f64180aa3") as Address;

// Hardhat/Anvil dev keys, funded in the monad devnet genesis alloc.
const ADMIN_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as Hex; // acct 0
const VALIDATOR_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" as Hex; // acct 1
const ALICE_KEY = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a" as Hex; // acct 2
const DOMAIN_ACCESS_KEY = (process.env.DOMAIN_ACCESS_KEY ?? ADMIN_KEY) as Hex;

const PAYLOAD_PLAIN = "0x01" as Hex;
const PAYLOAD_UNDECRYPTABLE = "0x02" as Hex;
const PAYLOAD_SECRET = "0x5ec2e7" as Hex;

const admin = privateKeyToAccount(ADMIN_KEY);
const validator = privateKeyToAccount(VALIDATOR_KEY);
const alice = privateKeyToAccount(ALICE_KEY);

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

async function waitForDomainTx(domain: PublicClient, hash: Hex, label: string) {
  const receipt = await retry(
    `${label} domain receipt`,
    async () => domain.getTransactionReceipt({ hash }).catch(() => null),
    (r) => r !== null,
    90_000,
  );
  if (receipt!.status !== "success") throw new Error(`${label}: domain transaction reverted (hash ${hash})`);
  console.log(`  domain receipt ok: ${label} (block ${receipt!.blockNumber}, gasUsed ${receipt!.gasUsed})`);
  return receipt!;
}

/** `<chain id>.<EIP-712 signature over DomainAccessToken(uint64 chainId)>`, the domain route's access token. */
async function domainAccessToken(key: Hex, chainId: bigint): Promise<string> {
  const signature = await privateKeyToAccount(key).signTypedData({
    domain: { name: "Monad Domain RPC", version: "1", chainId: Number(chainId) },
    types: { DomainAccessToken: [{ name: "chainId", type: "uint64" }] },
    primaryType: "DomainAccessToken",
    message: { chainId },
  });
  return `${chainId}.${signature}`;
}

function domainClient(chainId: bigint) {
  const url = `${L1_RPC_URL}/domain/${chainId}`;
  const chain = defineChain({
    id: Number(chainId),
    name: `domain-${chainId}`,
    nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
    rpcUrls: { default: { http: [url] } },
  });
  const token = domainAccessToken(DOMAIN_ACCESS_KEY, chainId);
  const transport = http(url, {
    batch: true,
    fetchFn: async (input, init) => {
      const headers = new Headers(init?.headers);
      headers.set("X-Authorization-Token", await token);
      return fetch(input, { ...init, headers });
    },
  });
  return { url, client: createPublicClient({ chain, transport }) };
}

async function main() {
  if (!VIEWING_KEY_A || !VIEWING_KEY_B) throw new Error("set VIEWING_KEY_A and VIEWING_KEY_B (the node drops plaintext for a keyed domain)");

  const l1Probe = createPublicClient({ transport: http(L1_RPC_URL) });
  const l1ChainId = await l1Probe.getChainId();
  const l1Chain = defineChain({
    id: l1ChainId,
    name: `l1-${l1ChainId}`,
    nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
    rpcUrls: { default: { http: [L1_RPC_URL] } },
  });
  const l1 = createPublicClient({ chain: l1Chain, transport: http(L1_RPC_URL) });
  const aliceWallet = createWalletClient({ account: alice, chain: l1Chain, transport: http(L1_RPC_URL) });
  const validatorWallet = createWalletClient({ account: validator, chain: l1Chain, transport: http(L1_RPC_URL) });
  const { client: domainA } = domainClient(DOMAIN_A);
  const { client: domainB } = domainClient(DOMAIN_B);
  for (const [label, client, expected] of [["A", domainA, DOMAIN_A], ["B", domainB, DOMAIN_B]] as const) {
    const reported = await client.getChainId();
    if (BigInt(reported) !== expected) throw new Error(`domain ${label} RPC reports chain id ${reported}, expected ${expected}`);
  }
  console.log("L1 chain id:", l1ChainId);
  console.log(`domain A: ${DOMAIN_A}, domain B: ${DOMAIN_B}`);

  const hubArt = loadArtifact("DomainHub.sol", "DomainHub");
  const spokeArt = loadArtifact("DomainSpoke.sol", "DomainSpoke");
  const receiverArt = loadArtifact("CrossDomainReceiver.sol", "CrossDomainReceiver");

  const confirm = async (hash: Hex, label: string) => {
    const receipt = await l1.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`${label}: L1 transaction reverted (${hash})`);
    console.log(`  L1 tx ok: ${label} (block ${receipt.blockNumber})`);
    return receipt;
  };

  // -------------------------------------------------------------------------
  step("1. two domains on one hub (spokes seeded by sequencing)");
  // -------------------------------------------------------------------------
  const adminNonce = await l1.getTransactionCount({ address: admin.address });
  if (adminNonce !== 0) {
    throw new Error(`admin ${admin.address} has L1 nonce ${adminNonce}; expected 0 so the hub lands at ${EXPECTED_HUB}. Restart from a fresh chain.`);
  }
  const hubDeployBlock = await l1.getBlockNumber();
  const common = { l1RpcUrl: L1_RPC_URL, adminKey: ADMIN_KEY, validators: [validator.address], quorum: 1n, checkpointInterval: CHECKPOINT_INTERVAL };
  const setupA = await setupDomain({ ...common, domainChainId: DOMAIN_A, viewingKey: VIEWING_KEY_A });
  const hub = setupA.hub;
  if (hub.toLowerCase() !== EXPECTED_HUB.toLowerCase()) throw new Error(`hub deployed at ${hub}, the node watches ${EXPECTED_HUB}`);
  const setupB = await setupDomain({ ...common, existingHub: hub, domainChainId: DOMAIN_B, viewingKey: VIEWING_KEY_B });
  const spokeA = setupA.spoke;
  const spokeB = setupB.spoke;
  await retry("spoke A code", () => domainA.getCode({ address: spokeA }), (c) => !!c && c !== "0x", 90_000);
  await retry("spoke B code", () => domainB.getCode({ address: spokeB }), (c) => !!c && c !== "0x", 90_000);
  console.log(`  spoke A ${spokeA} and spoke B ${spokeB} have code`);
  const context: MessageContext = { l1ChainId: BigInt(l1ChainId), hub };

  // -------------------------------------------------------------------------
  step("2. receiver on domain B authenticating (spoke B, source A, alice)");
  // -------------------------------------------------------------------------
  const receiverDeploy = await sequenceTransaction({
    l1RpcUrl: L1_RPC_URL,
    hub,
    domainChainId: DOMAIN_B,
    senderKey: ADMIN_KEY,
    data: encodeDeployData({ abi: receiverArt.abi, bytecode: receiverArt.bytecode, args: [spokeB, DOMAIN_A, alice.address] }),
    gas: 2_000_000n,
    nonce: await domainB.getTransactionCount({ address: admin.address }),
  });
  const receiverReceipt = await waitForDomainTx(domainB, receiverDeploy.domainTxHash, "new CrossDomainReceiver(spokeB, A, alice)");
  const receiver = receiverReceipt.contractAddress;
  if (!receiver) throw new Error("receiver deployment receipt carries no contractAddress");
  await retry("receiver code", () => domainB.getCode({ address: receiver }), (c) => !!c && c !== "0x", 30_000);
  console.log(`  receiver ${receiver} on domain B`);

  // -------------------------------------------------------------------------
  step("3. alice records three messages for B on spoke A");
  // -------------------------------------------------------------------------
  // A sender reads the destination's viewing key from the hub, never from the destination.
  const publishedKeyB = (await l1.readContract({ address: hub, abi: hubArt.abi, functionName: "viewingKeys", args: [DOMAIN_B] })) as Hex;
  if (publishedKeyB.toLowerCase() !== VIEWING_KEY_B.toLowerCase()) throw new Error(`hub publishes ${publishedKeyB} for B, expected VIEWING_KEY_B`);
  const undecryptableCiphertext = await encryptMessage(VIEWING_KEY_A, receiver, PAYLOAD_UNDECRYPTABLE);
  const secretCiphertext = await encryptMessage(publishedKeyB, receiver, PAYLOAD_SECRET);

  const sends: { label: string; data: Hex; plaintext: MessagePlaintext; ciphertext?: Hex }[] = [
    {
      label: "sendDomainMessage(B, receiver, plain)",
      data: encodeFunctionData({ abi: spokeArt.abi, functionName: "sendDomainMessage", args: [DOMAIN_B, receiver, PAYLOAD_PLAIN] }),
      plaintext: { to: receiver, data: PAYLOAD_PLAIN },
    },
    {
      label: "sendEncryptedDomainMessage(B, sealed to A's key: undecryptable for B)",
      data: encodeFunctionData({ abi: spokeArt.abi, functionName: "sendEncryptedDomainMessage", args: [DOMAIN_B, undecryptableCiphertext] }),
      plaintext: { to: receiver, data: PAYLOAD_UNDECRYPTABLE },
      ciphertext: undecryptableCiphertext,
    },
    {
      label: "sendEncryptedDomainMessage(B, sealed to B's key)",
      data: encodeFunctionData({ abi: spokeArt.abi, functionName: "sendEncryptedDomainMessage", args: [DOMAIN_B, secretCiphertext] }),
      plaintext: { to: receiver, data: PAYLOAD_SECRET },
      ciphertext: secretCiphertext,
    },
  ];
  const recorded: { message: DomainMessage; messageId: Hex; plaintext: MessagePlaintext; ciphertext?: Hex; blockNumber: bigint }[] = [];
  for (const send of sends) {
    const seq = await sequenceTransaction({
      l1RpcUrl: L1_RPC_URL, hub, domainChainId: DOMAIN_A, senderKey: ALICE_KEY, to: spokeA, data: send.data, gas: 300_000n,
      nonce: await domainA.getTransactionCount({ address: alice.address }),
    });
    const receipt = await waitForDomainTx(domainA, seq.domainTxHash, send.label);
    const [log] = parseEventLogs({ abi: spokeArt.abi, eventName: "DomainMessageRecorded", logs: receipt.logs });
    const args = log?.args as { messageId?: Hex; message?: Hex } | undefined;
    if (!args?.messageId || !args.message) throw new Error(`${send.label}: no DomainMessageRecorded log in the domain receipt`);
    const message = decodeDomainMessage(args.message);
    if (message.from.toLowerCase() !== alice.address.toLowerCase() || message.sourceChainId !== DOMAIN_A || message.destinationChainId !== DOMAIN_B) {
      throw new Error(`${send.label}: unexpected envelope origin/destination`);
    }
    if (send.ciphertext) {
      if (!isEncryptedDomainMessage(message) || message.to !== zeroAddress) throw new Error(`${send.label}: expected an Encrypted envelope with no target, got kind ${message.kind} to ${message.to}`);
      if (message.data.toLowerCase() !== send.ciphertext.toLowerCase()) throw new Error(`${send.label}: envelope data is not the ciphertext`);
    } else if (message.kind !== MessageKind.Plain || message.to.toLowerCase() !== receiver.toLowerCase() || message.data !== PAYLOAD_PLAIN) {
      throw new Error(`${send.label}: plaintext envelope mismatch`);
    }
    recorded.push({ message, messageId: args.messageId, plaintext: send.plaintext, ciphertext: send.ciphertext, blockNumber: receipt.blockNumber });
    console.log(`  recorded nonce ${message.sourceNonce} (kind ${MessageKind[message.kind]}, to ${message.to}, ${(message.data.length - 2) / 2} data bytes)`);
  }

  // -------------------------------------------------------------------------
  step("4. validator attests A's next scheduled checkpoint (anchors the batch)");
  // -------------------------------------------------------------------------
  const interval = BigInt(await l1.readContract({ address: hub, abi: HUB_CHECKPOINT_ABI, functionName: "checkpointIntervals", args: [DOMAIN_A] }));
  const lastBlock = recorded[recorded.length - 1]!.blockNumber;
  const checkpointHeight = ((lastBlock + interval - 1n) / interval) * interval;
  await retry(`L1 block ${checkpointHeight} finalized`, () => l1.getBlock({ blockTag: "finalized" }).then((b) => b.number), (f) => f >= checkpointHeight, 120_000);
  const checkpoint = await buildCheckpoint({ l1, domain: domainA, hub, spoke: spokeA, domainChainId: DOMAIN_A, height: checkpointHeight });
  if (checkpoint.toNonce - checkpoint.fromNonce !== BigInt(recorded.length)) {
    throw new Error(`expected ${recorded.length} messages in the batch, got [${checkpoint.fromNonce}, ${checkpoint.toNonce})`);
  }
  const attestation = await attestCheckpoint({ l1, submitter: validatorWallet, chain: l1Chain, hub, checkpoint, validatorKeys: [VALIDATOR_KEY] });
  if (!attestation.advanced) throw new Error("hub did not advance after the single validator signed");
  console.log(`  checkpoint ${checkpointHeight}: anchor ${checkpoint.anchor} (${attestation.submitted[0]})`);

  // -------------------------------------------------------------------------
  step("5. relay all three through the hub: plaintext vs encrypted transport events");
  // -------------------------------------------------------------------------
  const located = await retry(
    "attested batch",
    async () => findBatchForNonce(l1, domainA, hub, spokeA, DOMAIN_A, recorded[0]!.message.sourceNonce, { fromBlock: hubDeployBlock, toBlock: await l1.getBlockNumber() }),
    (b) => b !== null,
  );
  const batch = await fetchDomainBatch(domainA, spokeA, located!, context, { scanFromBlock: hubDeployBlock });
  const deliveryNonces: bigint[] = [];
  for (const entry of recorded) {
    const proof = proveMessage(batch, entry.messageId);
    if (proof.anchor !== checkpoint.anchor) throw new Error(`rebuilt anchor ${proof.anchor} differs from the attested ${checkpoint.anchor}`);
    const receipt = await confirm(
      await aliceWallet.writeContract({ address: hub, abi: hubArt.abi, functionName: "relayDomainMessage", args: [proof.message, proof.anchor, proof.proof], gas: 500_000n }),
      `hub.relayDomainMessage(nonce ${entry.message.sourceNonce})`,
    );
    const routed = parseEventLogs({ abi: hubArt.abi, eventName: "DomainMessageRouted", logs: receipt.logs });
    const plain = parseEventLogs({ abi: hubArt.abi, eventName: "L1MessageRecorded", logs: receipt.logs });
    const sealed = parseEventLogs({ abi: hubArt.abi, eventName: "EncryptedL1MessageRecorded", logs: receipt.logs });
    const routedArgs = routed[0]?.args as { destinationChainId?: bigint; deliveryNonce?: bigint } | undefined;
    if (routed.length !== 1 || routedArgs?.destinationChainId !== DOMAIN_B || routedArgs.deliveryNonce === undefined) throw new Error("expected one DomainMessageRouted to B");
    deliveryNonces.push(routedArgs.deliveryNonce);
    if (entry.ciphertext) {
      if (plain.length !== 0 || sealed.length !== 1) throw new Error(`encrypted route emitted ${plain.length} plaintext and ${sealed.length} encrypted events`);
      const args = sealed[0]!.args as { domainChainId: bigint; sourceChainId: bigint; from: Address; ciphertext: Hex; nonce: bigint };
      if (args.domainChainId !== DOMAIN_B || args.sourceChainId !== DOMAIN_A || args.from.toLowerCase() !== alice.address.toLowerCase()) {
        throw new Error("EncryptedL1MessageRecorded carries the wrong origin");
      }
      if (args.ciphertext.toLowerCase() !== entry.ciphertext.toLowerCase() || args.nonce !== routedArgs.deliveryNonce) throw new Error("EncryptedL1MessageRecorded payload mismatch");
      console.log(`  delivery nonce ${args.nonce}: EncryptedL1MessageRecorded(B, A, alice, ${(args.ciphertext.length - 2) / 2}-byte ciphertext)`);
    } else {
      if (plain.length !== 1 || sealed.length !== 0) throw new Error(`plaintext route emitted ${plain.length} plaintext and ${sealed.length} encrypted events`);
      console.log(`  delivery nonce ${routedArgs.deliveryNonce}: L1MessageRecorded(B, A, alice, receiver, plain)`);
    }
  }

  // What an L1 observer learns about B's inbox: one plaintext target/payload, two ciphertexts.
  // eth_getLogs can trail the receipt path by a few blocks, so poll until the last relay shows.
  const inbox = await retry(
    "hub events for B's inbox",
    async () => {
      const l1Head = await l1.getBlockNumber();
      const plaintext = await fetchL1Messages(l1, DOMAIN_B, { fromBlock: hubDeployBlock, toBlock: l1Head }, hub);
      const encrypted = await l1.getLogs({ address: hub, event: ENCRYPTED_L1_MESSAGE_RECORDED_EVENT, args: { domainChainId: DOMAIN_B }, fromBlock: hubDeployBlock, toBlock: l1Head });
      return { plaintext: plaintext.length, encrypted: encrypted.length };
    },
    (view) => view.plaintext + view.encrypted >= recorded.length,
  );
  if (inbox.plaintext !== 1 || inbox.encrypted !== 2) throw new Error(`L1 shows ${inbox.plaintext} plaintext and ${inbox.encrypted} encrypted deliveries for B`);
  console.log(`  L1 view of B's inbox: ${inbox.plaintext} plaintext envelope, ${inbox.encrypted} ciphertexts (origin A / alice in the clear)`);

  // -------------------------------------------------------------------------
  step("6. B's client delivers the plaintext and the properly sealed message, skips the other");
  // -------------------------------------------------------------------------
  const status = (index: number) =>
    routedMessageDeliveryStatus(domainB, recorded[index]!.message, spokeB, deliveryNonces[index]!, recorded[index]!.plaintext);
  const secretStatus = await retry("delivery of the sealed message on B", () => status(2), (s) => s !== "pending", 120_000);
  if (secretStatus !== "delivered") throw new Error(`sealed message ${secretStatus}`);
  const plainStatus = await retry("delivery of the plaintext message on B", () => status(0), (s) => s !== "pending", 60_000);
  if (plainStatus !== "delivered") throw new Error(`plaintext message ${plainStatus}`);
  const undecryptableStatus = await status(1);
  if (undecryptableStatus !== "pending") throw new Error(`the undecryptable message was ${undecryptableStatus}; the client must never deliver it`);
  const nextNonce = (await domainB.readContract({ address: spokeB, abi: spokeArt.abi, functionName: "nextL1Nonce" })) as bigint;
  if (nextNonce !== deliveryNonces[2]! + 1n) throw new Error(`spoke B nextL1Nonce is ${nextNonce}, expected ${deliveryNonces[2]! + 1n}`);
  console.log(`  delivered nonces ${deliveryNonces[0]} and ${deliveryNonces[2]}; nonce ${deliveryNonces[1]} left as a gap (nextL1Nonce ${nextNonce})`);

  const read = (fn: string) => domainB.readContract({ address: receiver, abi: receiverArt.abi, functionName: fn });
  const [calls, source, sender, payload] = await Promise.all([read("calls"), read("source"), read("sender"), read("payload")]);
  if (calls !== 2n) throw new Error(`receiver saw ${calls} deliveries, expected 2`);
  if (BigInt(source as bigint) !== DOMAIN_A || (sender as Address).toLowerCase() !== alice.address.toLowerCase()) throw new Error("receiver recorded the wrong origin");
  if ((payload as Hex).toLowerCase() !== PAYLOAD_SECRET) throw new Error(`receiver's last payload is ${payload}, expected ${PAYLOAD_SECRET}`);
  console.log(`  receiver: ${calls} calls, last from domain ${source} / ${sender} with payload ${payload} (opened by B's client only)`);
  console.log("\n✅ domain -> domain messaging complete: plaintext and encrypted routes delivered, undecryptable one skipped");
}

main().catch((error) => {
  console.error("\n❌", error instanceof Error ? error.message : error);
  process.exit(1);
});
