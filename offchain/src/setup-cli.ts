import type { Address, Hex } from "viem";
import { setupDomain, type SetupConfig } from "./setup.js";

/**
 * CLI wrapper: reads configuration from the environment and runs the end-to-end domain setup.
 *
 *   L1_RPC_URL=...          \
 *   ADMIN_KEY=0x...         \  # deploys hub + L1Bridge; becomes operator + owner
 *   DOMAIN_CHAIN_ID=..   \
 *   VALIDATORS=0x..,0x..    \  # comma-separated
 *   QUORUM=2                \
 *   [SEED_DEPLOYER_KEY=0x.] \  # domain seed account; defaults to ADMIN_KEY
 *   [SPOKE_OPERATOR=0x..]   \  # defaults to admin
 *   [ALLOWED_TOKEN=0x..]    \  # e.g. wrapped MON
 *   [SEQUENCING_FEE=0]      \  # wei forwarded per sequenceToDomain
 *   [DOMAIN_GAS=5000000]        \
 *   [VIEWING_KEY=0x04...]   \  # domain viewing public key; encrypts the seeded txs if set
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
  if (process.env.SEED_DEPLOYER_KEY) config.seedDeployerKey = process.env.SEED_DEPLOYER_KEY as Hex;
  if (process.env.SPOKE_OPERATOR) config.spokeOperator = process.env.SPOKE_OPERATOR as Address;
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
