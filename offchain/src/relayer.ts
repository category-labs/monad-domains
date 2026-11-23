import { createPublicClient, createWalletClient, http, type Address, type Chain, type Hex, type PublicClient, type WalletClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { DOMAIN_SPOKE, domainTransportFor, fetchL1Chain } from "./chain.js";
import { attestCheckpoint, buildCheckpoint, HUB_CHECKPOINT_ABI, nextCheckpointHeight } from "./checkpoint.js";
import { relayPending, type RelayConfig, type RelayState } from "./relay.js";

/**
 * A domain's off-chain duties in one object, for a service that runs them for one or more
 * domains: attest every scheduled checkpoint with the validator keys it holds, then prove the
 * messages of each attested batch to the hub. One `tick` is one pass over every domain; a
 * pass that fails for a domain is retried by the next one. L1 transactions are sent and
 * awaited in turn, so nothing else may send from the same keys at the same time.
 */
export interface DomainRelayerDomain {
  chainId: bigint;
  /** RPC of the domain, serving its own chain. */
  domainRpcUrl: string;
  /** Key of an operator of that RPC: blocks and the spoke's logs are served to operators only. */
  rpcKey: Hex;
  /** Keys of the domain's validators this service signs checkpoints with. */
  validatorKeys: Hex[];
  /** The domain's spoke. Default: the genesis spoke. */
  spoke?: Address;
  /** L1 block at or before the domain's first attestation, e.g. the one that registered it. Default 0. */
  scanFromBlock?: bigint;
}

export interface DomainRelayerConfig {
  l1RpcUrl: string;
  hub: Address;
  /** Pays for `submitStateSignature`. */
  submitterKey: Hex;
  /** Pays for `relayDomainMessage`, and the delivery fee of forwarded messages. Default `submitterKey`. */
  relayerKey?: Hex;
  domains: DomainRelayerDomain[];
  /** Gas bought for the delivery of each message forwarded to another domain. */
  deliveryGas?: bigint;
  log?: (line: string) => void;
}

export interface DomainRelayerStatus {
  chainId: string;
  /** L1 height of the latest checkpoint the hub holds, as of the last pass. */
  attestedHeight: string | null;
  /** Checkpoints this service saw the hub advance to, and messages it relayed, since it started. */
  checkpoints: number;
  relayed: number;
  lastError: string | null;
}

interface DomainState {
  config: DomainRelayerDomain;
  spoke: Address;
  client?: PublicClient;
  relay: RelayState;
  status: DomainRelayerStatus;
}

export class DomainRelayer {
  private readonly log: (line: string) => void;
  private readonly domains: DomainState[];
  private chain?: Chain;
  private l1?: PublicClient;
  private submitter?: WalletClient;
  private relayer?: WalletClient;

  constructor(private readonly config: DomainRelayerConfig) {
    this.log = config.log ?? ((line) => console.log(line));
    this.domains = config.domains.map((domain) => ({
      config: domain,
      spoke: domain.spoke ?? DOMAIN_SPOKE,
      relay: {},
      status: { chainId: domain.chainId.toString(), attestedHeight: null, checkpoints: 0, relayed: 0, lastError: null },
    }));
  }

  private async connect(): Promise<{ chain: Chain; l1: PublicClient; submitter: WalletClient; relayer: WalletClient }> {
    if (!this.chain || !this.l1 || !this.submitter || !this.relayer) {
      const { l1RpcUrl, submitterKey, relayerKey = submitterKey } = this.config;
      this.chain = await fetchL1Chain(l1RpcUrl);
      this.l1 = createPublicClient({ chain: this.chain, transport: http(l1RpcUrl) });
      this.submitter = createWalletClient({ account: privateKeyToAccount(submitterKey), chain: this.chain, transport: http(l1RpcUrl) });
      this.relayer = createWalletClient({ account: privateKeyToAccount(relayerKey), chain: this.chain, transport: http(l1RpcUrl) });
    }
    return { chain: this.chain, l1: this.l1, submitter: this.submitter, relayer: this.relayer };
  }

  /** One pass over every domain: attest the checkpoints that are due, then relay what they anchored. */
  async tick(): Promise<void> {
    const { chain, l1, submitter, relayer } = await this.connect();
    const { hub } = this.config;
    for (const domain of this.domains) {
      const { chainId, domainRpcUrl, rpcKey, validatorKeys } = domain.config;
      try {
        // Batching sends each page of `domainMessageIds` reads as one JSON-RPC request.
        domain.client ??= createPublicClient({ transport: await domainTransportFor(domainRpcUrl, chainId, rpcKey, { batch: true }) });
        const client = domain.client;

        // A domain that fell behind catches up one checkpoint after the other.
        for (;;) {
          const [lastAttested, interval] = await Promise.all([
            l1.readContract({ address: hub, abi: HUB_CHECKPOINT_ABI, functionName: "domainBlockNumbers", args: [chainId] }),
            l1.readContract({ address: hub, abi: HUB_CHECKPOINT_ABI, functionName: "checkpointIntervals", args: [chainId] }),
          ]);
          if (interval === 0n) throw new Error(`domain ${chainId} is not registered on ${hub}`);
          domain.status.attestedHeight = lastAttested.toString();
          const finalized = await l1.getBlock({ blockTag: "finalized" });
          const height = nextCheckpointHeight(BigInt(lastAttested), BigInt(interval), finalized.number);
          if (height === null || validatorKeys.length === 0) break;
          const checkpoint = await buildCheckpoint({ l1, domain: client, hub, spoke: domain.spoke, domainChainId: chainId, height });
          const result = await attestCheckpoint({ l1, submitter, chain, hub, checkpoint, validatorKeys });
          if (!result.advanced) break; // other validators have yet to sign
          domain.status.checkpoints++;
          domain.status.attestedHeight = height.toString();
          if (checkpoint.toNonce > checkpoint.fromNonce) {
            this.log(`relayer: domain ${chainId} checkpoint ${height} anchors messages [${checkpoint.fromNonce}, ${checkpoint.toNonce})`);
          }
        }

        const relayConfig: RelayConfig = {
          l1, domain: client, relayer, chain, hub, spoke: domain.spoke, domainChainId: chainId,
          scanFromBlock: domain.config.scanFromBlock, deliveryGas: this.config.deliveryGas,
        };
        for (const { message, transactionHash, delivered } of await relayPending(relayConfig, domain.relay)) {
          domain.status.relayed++;
          this.log(
            `relayer: domain ${chainId} message ${message.sourceNonce} to chain ${message.destinationChainId}: ${transactionHash}` +
              (delivered ? "" : " (the L1 callback failed)"),
          );
        }
        domain.status.lastError = null;
      } catch (error) {
        const message = error instanceof Error ? error.message.split("\n")[0]! : String(error);
        if (message !== domain.status.lastError) this.log(`relayer: domain ${chainId}: ${message}`);
        domain.status.lastError = message;
      }
    }
  }

  status(): DomainRelayerStatus[] {
    return this.domains.map((domain) => ({ ...domain.status }));
  }
}
