import { createPublicClient, createWalletClient, http, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { DOMAIN_SPOKE, domainTransportFor, fetchL1Chain } from "./chain.js";
import { relayPending, type RelayConfig, type RelayState } from "./relay.js";

/**
 * Relays the messages a domain recorded for the L1 (and for other domains) once their
 * checkpoint is attested: proves each one to the hub, which executes or forwards it. The hub
 * verifies the proofs; reading the messages takes an operator of the source domain.
 *
 *   L1_RPC_URL=...            \
 *   HUB_ADDRESS=0x...         \
 *   DOMAIN_CHAIN_ID=...       \  # the source domain
 *   DOMAIN_RPC_URL=...        \  # its RPC
 *   DOMAIN_RPC_KEY=0x...      \  # key of one of its operators: signs the RPC's access token
 *   [SPOKE_ADDRESS=0x...]     \  # its DomainSpoke; default is the genesis spoke
 *   RELAYER_KEY=0x...         \  # L1 account that pays for relayDomainMessage
 *   [SCAN_FROM_BLOCK=0]       \  # L1 block at or before the domain's first attestation
 *   [DELIVERY_GAS=500000]     \  # gas bought for each message forwarded to another domain
 *   [POLL_INTERVAL_MS=...]    \  # keep running, one pass per interval; default is a single pass
 *     npm run relay
 */
function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`relay: ${name} is required`);
  return value;
}

async function main() {
  const l1RpcUrl = required("L1_RPC_URL");
  const domainRpcUrl = required("DOMAIN_RPC_URL");
  const pollIntervalMs = process.env.POLL_INTERVAL_MS ? Number(process.env.POLL_INTERVAL_MS) : undefined;

  const chain = await fetchL1Chain(l1RpcUrl);
  const domainChainId = BigInt(required("DOMAIN_CHAIN_ID"));
  const domainRpcKey = process.env.DOMAIN_RPC_KEY as Hex | undefined;
  const config: RelayConfig = {
    l1: createPublicClient({ chain, transport: http(l1RpcUrl) }),
    // Batching sends each page of `domainMessageIds` reads as one JSON-RPC request.
    domain: createPublicClient({ transport: await domainTransportFor(domainRpcUrl, domainChainId, domainRpcKey, { batch: true }) }),
    relayer: createWalletClient({ account: privateKeyToAccount(required("RELAYER_KEY") as Hex), chain, transport: http(l1RpcUrl) }),
    chain,
    hub: required("HUB_ADDRESS") as Address,
    spoke: (process.env.SPOKE_ADDRESS as Address | undefined) ?? DOMAIN_SPOKE,
    domainChainId,
  };
  if (process.env.SCAN_FROM_BLOCK) config.scanFromBlock = BigInt(process.env.SCAN_FROM_BLOCK);
  if (process.env.DELIVERY_GAS) config.deliveryGas = BigInt(process.env.DELIVERY_GAS);

  const state: RelayState = {};
  const pass = async () => {
    const relayed = await relayPending(config, state);
    for (const { message, transactionHash, delivered } of relayed) {
      console.log(
        `relayed nonce ${message.sourceNonce} to chain ${message.destinationChainId}: ${transactionHash}` +
          (delivered ? "" : " (the L1 callback failed; retry it with hub.retryDomainMessage)"),
      );
    }
    if (relayed.length === 0 && pollIntervalMs === undefined) console.log("nothing to relay");
  };

  if (pollIntervalMs === undefined) return pass();
  for (;;) {
    // A pass fails while the domain's RPC is behind the L1; the next one retries.
    await pass().catch((error) => console.error(error instanceof Error ? error.message.split("\n")[0] : error));
    await new Promise((resolve) => setTimeout(resolve, pollIntervalMs));
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
