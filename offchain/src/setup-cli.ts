import type { Address, Hex } from "viem";
import { setupDomain, type SetupConfig } from "./setup.js";

/**
 * CLI wrapper: reads configuration from the environment and runs the end-to-end domain setup.
 *
 *   L1_RPC_URL=...          \
 *   ADMIN_KEY=0x...         \  # deploys hub + L1Bridge and registers the domain; L1Bridge owner
 *   DOMAIN_CHAIN_ID=..   \
 *   VALIDATORS=0x..,0x..    \  # comma-separated
 *   QUORUM=2                \
 *   [EXISTING_HUB_ADDRESS=0x..] \ # reuse the hub when adding another domain
 *   [SEED_DEPLOYER_KEY=0x.] \  # domain seed account; defaults to ADMIN_KEY
 *   [FEE_RECIPIENT=0x..]    \  # receives sequencing fees; defaults to admin
 *   [CHECKPOINT_INTERVAL=5] \  # attested heights are multiples of this
 *   [ALLOWED_TOKEN=0x..]    \  # e.g. wrapped MON
 *   [SEQUENCING_FEE=0]      \  # wei forwarded per sequenceToDomain
 *   [DOMAIN_GAS=5000000]        \
 *   [VIEWING_KEY=0x04...]   \  # viewing public key: published on the hub, encrypts the seeded txs
 *     npm run setup
 */
function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`setup: ${name} is required`);
  return value;
}

function main() {
  const config: SetupConfig = {
    l1RpcUrl: required("L1_RPC_URL"),
    adminKey: required("ADMIN_KEY") as Hex,
    domainChainId: BigInt(required("DOMAIN_CHAIN_ID")),
    validators: required("VALIDATORS")
      .split(",")
      .map((a) => a.trim())
      .filter(Boolean) as Address[],
    quorum: BigInt(required("QUORUM")),
  };
  if (process.env.EXISTING_HUB_ADDRESS) config.existingHub = process.env.EXISTING_HUB_ADDRESS as Address;
  if (process.env.SEED_DEPLOYER_KEY) config.seedDeployerKey = process.env.SEED_DEPLOYER_KEY as Hex;
  if (process.env.FEE_RECIPIENT) config.feeRecipient = process.env.FEE_RECIPIENT as Address;
  if (process.env.CHECKPOINT_INTERVAL) config.checkpointInterval = BigInt(process.env.CHECKPOINT_INTERVAL);
  if (process.env.ALLOWED_TOKEN) config.allowedToken = process.env.ALLOWED_TOKEN as Address;
  if (process.env.SEQUENCING_FEE) config.sequencingFee = BigInt(process.env.SEQUENCING_FEE);
  if (process.env.DOMAIN_GAS) config.domainGas = BigInt(process.env.DOMAIN_GAS);
  if (process.env.VIEWING_KEY) config.viewingKey = process.env.VIEWING_KEY as Hex;

  return setupDomain(config);
}

main()
  .then((result) => {
    console.log("\nSetup complete:");
    console.log(JSON.stringify(result, null, 2));
  })
  .catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  });
