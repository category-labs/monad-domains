import { createPublicClient, createWalletClient, defineChain, http, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { attestCheckpoint, buildCheckpoint, HUB_CHECKPOINT_ABI, nextCheckpointHeight } from "./checkpoint.js";

/**
 * One validator pass: derive the next scheduled checkpoint from the finalized domain state
 * and attest it onto the hub. Every validator runs this independently with its own key; the
 * hub advances once a quorum signed the same proposal.
 *
 *   L1_RPC_URL=...            \
 *   HUB_ADDRESS=0x...         \
 *   DOMAIN_CHAIN_ID=...       \
 *   SPOKE_ADDRESS=0x...       \  # the DomainSpoke on the domain (CREATE(seed, 0) after `npm run setup`)
 *   VALIDATOR_KEYS=0x..,0x..  \  # keys that sign; usually one
 *   SUBMITTER_KEY=0x...       \  # L1 account that pays for submitStateSignature
 *   [DOMAIN_RPC_URL=...]      \  # default `${L1_RPC_URL}/domain/${DOMAIN_CHAIN_ID}`
 *   [CHECKPOINT_HEIGHT=...]   \  # attest this exact height instead of the next scheduled one
 *     npm run checkpoint
 */
function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`checkpoint: ${name} is required`);
  return value;
}

async function main() {
  const l1RpcUrl = required("L1_RPC_URL");
  const hub = required("HUB_ADDRESS") as Address;
  const domainChainId = BigInt(required("DOMAIN_CHAIN_ID"));
  const spoke = required("SPOKE_ADDRESS") as Address;
  const validatorKeys = required("VALIDATOR_KEYS").split(",").map((k) => k.trim()).filter(Boolean) as Hex[];
  const submitterKey = required("SUBMITTER_KEY") as Hex;
  const domainRpcUrl = process.env.DOMAIN_RPC_URL ?? `${l1RpcUrl}/domain/${domainChainId}`;

  const probe = createPublicClient({ transport: http(l1RpcUrl) });
  const l1ChainId = await probe.getChainId();
  const l1Chain = defineChain({
    id: l1ChainId,
    name: `l1-${l1ChainId}`,
    nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
    rpcUrls: { default: { http: [l1RpcUrl] } },
  });
  const l1 = createPublicClient({ chain: l1Chain, transport: http(l1RpcUrl) });
  // Batching sends each page of `domainMessageIds` reads as one JSON-RPC request.
  const domain = createPublicClient({ transport: http(domainRpcUrl, { batch: true }) });
  const submitter = createWalletClient({ account: privateKeyToAccount(submitterKey), chain: l1Chain, transport: http(l1RpcUrl) });

  const [lastAttested, interval] = await Promise.all([
    l1.readContract({ address: hub, abi: HUB_CHECKPOINT_ABI, functionName: "domainBlockNumbers", args: [domainChainId] }),
    l1.readContract({ address: hub, abi: HUB_CHECKPOINT_ABI, functionName: "checkpointIntervals", args: [domainChainId] }),
  ]);
  if (interval === 0n) throw new Error(`checkpoint: domain ${domainChainId} is not registered on ${hub}`);
  const finalized = await l1.getBlock({ blockTag: "finalized" });

  const height = process.env.CHECKPOINT_HEIGHT
    ? BigInt(process.env.CHECKPOINT_HEIGHT)
    : nextCheckpointHeight(BigInt(lastAttested), BigInt(interval), finalized.number);
  if (height === null) {
    console.log(`nothing to attest: last attested ${lastAttested}, interval ${interval}, finalized ${finalized.number}`);
    return;
  }

  const checkpoint = await buildCheckpoint({ l1, domain, hub, spoke, domainChainId, height });
  console.log(
    `checkpoint ${checkpoint.domainBlockNumber}: state root ${checkpoint.stateRoot}, ` +
      `batch [${checkpoint.fromNonce}, ${checkpoint.toNonce}) anchor ${checkpoint.anchor}`,
  );
  const result = await attestCheckpoint({ l1, submitter, chain: l1Chain, hub, checkpoint, validatorKeys });
  console.log(`digest ${result.digest}`);
  for (const hash of result.submitted) console.log(`submitted ${hash}`);
  console.log(result.advanced ? "hub advanced to this checkpoint" : "waiting for more validator signatures");
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
