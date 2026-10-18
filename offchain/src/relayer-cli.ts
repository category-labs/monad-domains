import type { Address, Hex } from "viem";
import { DomainRelayer, type RelayerConfig, type RelayerDomainConfig } from "./relayer.js";

/**
 * CLI wrapper: runs the relayer service for one or more domains, configured from the
 * environment. Every domain in RELAYER_DOMAINS has its own RELAYER_<chain id>_* block.
 *
 *   L1_RPC_URL=...                          \
 *   HUB_ADDRESS=0x...                       \
 *   SUBMITTER_KEY=0x...                     \  # L1 payer of submitStateSignature / relayDomainMessage
 *   RELAYER_DOMAINS=85679,151215            \
 *   RELAYER_85679_SPOKE=0x...               \
 *   RELAYER_85679_VALIDATOR_KEYS=0x..,0x..  \  # registered validators that sign checkpoints
 *   [RELAYER_85679_DOMAIN_RPC_URL=...]      \  # default $L1_RPC_URL/domain/85679
 *   [RELAYER_85679_START_BLOCK=0]           \  # L1 block at or before the domain's first attestation
 *   [POLL_INTERVAL_MS=2000]                 \
 *   [ATTEST_INTERVAL_MS=60000]              \  # heartbeat attestation; 0 attests only for messages
 *   [LOG_RANGE=1000]                        \  # largest eth_getLogs block range
 *     npm run relayer
 */
function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`relayer: ${name} is required`);
  return value;
}

function list(value: string): string[] {
  return value
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function domainConfig(chainId: string): RelayerDomainConfig {
  const prefix = `RELAYER_${chainId}_`;
  const config: RelayerDomainConfig = {
    chainId: BigInt(chainId),
    spoke: required(`${prefix}SPOKE`) as Address,
    validatorKeys: list(required(`${prefix}VALIDATOR_KEYS`)) as Hex[],
  };
  if (process.env[`${prefix}DOMAIN_RPC_URL`]) config.domainRpcUrl = process.env[`${prefix}DOMAIN_RPC_URL`];
  if (process.env[`${prefix}START_BLOCK`]) config.startBlock = BigInt(process.env[`${prefix}START_BLOCK`]!);
  return config;
}

async function main() {
  const config: RelayerConfig = {
    l1RpcUrl: required("L1_RPC_URL"),
    hub: required("HUB_ADDRESS") as Address,
    submitterKey: required("SUBMITTER_KEY") as Hex,
    domains: list(required("RELAYER_DOMAINS")).map(domainConfig),
  };
  if (process.env.POLL_INTERVAL_MS) config.pollIntervalMs = Number(process.env.POLL_INTERVAL_MS);
  if (process.env.ATTEST_INTERVAL_MS) config.attestIntervalMs = Number(process.env.ATTEST_INTERVAL_MS);
  if (process.env.LOG_RANGE) config.logRange = BigInt(process.env.LOG_RANGE);

  const relayer = new DomainRelayer({
    ...config,
    log: (line) => console.log(`${new Date().toISOString()} ${line}`),
  });
  const shutdown = () => {
    console.log("relayer: stopping after the current pass");
    void relayer.stop();
  };
  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
  return relayer.start();
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
