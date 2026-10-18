import type { Hex } from "viem";
import { loadDeployment } from "./config.js";
import { OperatorService, type OperatorConfig } from "./operator.js";
import { startTunnel } from "./rpc-tunnel.js";

/**
 * CLI wrapper: runs the demo operator service (relayer for both domains, Bank A's back
 * office, the onboarding faucet and the HTTP API) configured from the environment.
 *
 *   L1_RPC_URL=...                    \
 *   DEPLOYMENT=testnet                \  # deployments/<name>.json, or a path to a JSON file
 *   OPERATOR_KEY=0x...                \  # spoke operator; default for every other key
 *   [VALIDATOR_KEYS=0x..,0x..]        \  # registered validators (default: OPERATOR_KEY)
 *   [SUBMITTER_KEY=0x...]             \  # pays submitStateSignature / relayDomainMessage
 *   [BANK_KEY=0x...]                  \  # BANK on both L2Banks and the pool locker
 *   [FAUCET_KEY=0x...]                \  # funds drips and mints demo EUR
 *   [DOMAIN_A_RPC_URL=...]            \  # default $L1_RPC_URL/domain/<A>
 *   [DOMAIN_B_RPC_URL=...]            \
 *   [PORT=8787] [CORS_ORIGIN=*]       \
 *   [FAUCET_DRIP_WEI=...] [FAUCET_MINT_EUR_WEI=...] [FAUCET_RECEIVE_LIMIT_WEI=...]
 *   [FAUCET_COOLDOWN_MS=600000] [FAUCET_PER_IP_LIMIT=10]
 *   [POLL_INTERVAL_MS=500] [ATTEST_INTERVAL_MS=60000] [FINALITY_WAIT_MS=5000] [LOCK_TTL_SECONDS=600] [SEQUENCING_FEE=0]
 *   [RPC_GATEWAY=true]                \  # serve /rpc and /rpc/domain/<id> for the frontend
 *     npm run operator
 *
 * When the node's domain routes are not published (only its localhost RPC serves them), the
 * service can open its own ssh port-forward to the node instead of L1_RPC_URL:
 *
 *   RPC_SSH_HOST=swe-013.devcore4.com RPC_SSH_PORT=9022 RPC_SSH_USER=monad \
 *   RPC_SSH_KEY="$(cat key)"  [RPC_SSH_KNOWN_HOSTS="<host key line>"] \
 *   [RPC_SSH_REMOTE=127.0.0.1:8080] [RPC_SSH_LOCAL_PORT=18080]
 */
function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`operator: ${name} is required`);
  return value;
}

function list(value: string | undefined): Hex[] {
  return (value ?? "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean) as Hex[];
}

async function main() {
  const log = (line: string) => console.log(`${new Date().toISOString()} ${line}`);
  let l1RpcUrl = process.env.L1_RPC_URL;
  if (process.env.RPC_SSH_HOST) {
    const tunnel = await startTunnel({
      host: required("RPC_SSH_HOST"),
      port: process.env.RPC_SSH_PORT ? Number(process.env.RPC_SSH_PORT) : undefined,
      user: required("RPC_SSH_USER"),
      privateKey: process.env.RPC_SSH_KEY,
      keyFile: process.env.RPC_SSH_KEY_FILE,
      knownHosts: process.env.RPC_SSH_KNOWN_HOSTS,
      remote: process.env.RPC_SSH_REMOTE,
      localPort: process.env.RPC_SSH_LOCAL_PORT ? Number(process.env.RPC_SSH_LOCAL_PORT) : undefined,
      log,
    });
    l1RpcUrl = tunnel.url;
  }
  if (!l1RpcUrl) throw new Error("operator: L1_RPC_URL (or RPC_SSH_HOST) is required");
  const config: OperatorConfig = {
    l1RpcUrl,
    deployment: loadDeployment(process.env.DEPLOYMENT ?? "testnet"),
    operatorKey: required("OPERATOR_KEY") as Hex,
    log,
  };
  if (process.env.RPC_GATEWAY) config.rpcGateway = process.env.RPC_GATEWAY !== "false" && process.env.RPC_GATEWAY !== "0";
  const validators = list(process.env.VALIDATOR_KEYS);
  if (validators.length) config.validatorKeys = validators;
  if (process.env.SUBMITTER_KEY) config.submitterKey = process.env.SUBMITTER_KEY as Hex;
  if (process.env.BANK_KEY) config.bankKey = process.env.BANK_KEY as Hex;
  if (process.env.FAUCET_KEY) config.faucetKey = process.env.FAUCET_KEY as Hex;
  if (process.env.DOMAIN_A_RPC_URL || process.env.DOMAIN_B_RPC_URL) {
    config.domainRpcUrls = { A: process.env.DOMAIN_A_RPC_URL, B: process.env.DOMAIN_B_RPC_URL };
  }
  if (process.env.PORT) config.port = Number(process.env.PORT);
  if (process.env.CORS_ORIGIN) config.corsOrigin = process.env.CORS_ORIGIN;
  if (process.env.POLL_INTERVAL_MS) config.pollIntervalMs = Number(process.env.POLL_INTERVAL_MS);
  if (process.env.ATTEST_INTERVAL_MS) config.attestIntervalMs = Number(process.env.ATTEST_INTERVAL_MS);
  if (process.env.FINALITY_WAIT_MS) config.finalityWaitMs = Number(process.env.FINALITY_WAIT_MS);
  if (process.env.LOCK_TTL_SECONDS) config.lockTtlSeconds = Number(process.env.LOCK_TTL_SECONDS);
  if (process.env.SEQUENCING_FEE) config.sequencingFee = BigInt(process.env.SEQUENCING_FEE);
  config.faucet = {};
  if (process.env.FAUCET_DRIP_WEI) config.faucet.dripWei = BigInt(process.env.FAUCET_DRIP_WEI);
  if (process.env.FAUCET_DRIP_BELOW_WEI) config.faucet.dripBelowWei = BigInt(process.env.FAUCET_DRIP_BELOW_WEI);
  if (process.env.FAUCET_MINT_EUR_WEI) config.faucet.mintEur = BigInt(process.env.FAUCET_MINT_EUR_WEI);
  if (process.env.FAUCET_RECEIVE_LIMIT_WEI) config.faucet.receiveLimit = BigInt(process.env.FAUCET_RECEIVE_LIMIT_WEI);
  if (process.env.FAUCET_COOLDOWN_MS) config.faucet.cooldownMs = Number(process.env.FAUCET_COOLDOWN_MS);
  if (process.env.FAUCET_PER_IP_LIMIT) config.faucet.perIpLimit = Number(process.env.FAUCET_PER_IP_LIMIT);

  const service = new OperatorService(config);
  const shutdown = () => {
    console.log("operator: stopping after the current pass");
    void service.stop();
  };
  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
  return service.start();
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
