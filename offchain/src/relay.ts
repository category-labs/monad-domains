import { parseAbi, type Account, type Address, type Chain, type Hex, type PublicClient, type WalletClient } from "viem";
import type { DomainMessage, MessageContext } from "./message.js";
import { fetchBatches, fetchDomainBatch, proveMessage, type DomainBatch } from "./prover.js";
import { HUB_INPUT_GAS_HEADROOM } from "./sequence.js";

/**
 * Relaying of domain-origin messages. A message becomes provable once a quorum of validators
 * attested the checkpoint whose batch contains it. `relayDomainMessage` then executes an
 * L1-bound message as a callback on its target, and queues a domain-bound one for its
 * destination for the delivery fee the caller attaches. The hub verifies every proof; the
 * envelopes come from the source domain's RPC, which serves them to the domain's operators.
 */

export const HUB_RELAY_ABI = parseAbi([
  "struct DomainMessage { uint64 sourceChainId; uint64 destinationChainId; address from; address to; uint256 sourceNonce; bytes32 salt; bytes data; }",
  "function relayDomainMessage(DomainMessage message, bytes32 anchor, bytes32[] proof) payable returns (bool success)",
  "function relayedDomainMessages(uint64 sourceChainId, bytes32 messageHash) view returns (bool)",
  "function failedDomainMessages(uint64 sourceChainId, bytes32 messageHash) view returns (bool)",
  "function minDeliveryFee(uint256 dataLength) pure returns (uint256)",
  "function DOMAIN_GAS_PRICE() view returns (uint256)",
]);

export interface RelayConfig {
  l1: PublicClient;
  /** RPC of the source domain, serving its own chain. */
  domain: PublicClient;
  /** Pays for the relay transactions on the L1. */
  relayer: WalletClient;
  chain: Chain;
  hub: Address;
  /** The source domain's spoke. */
  spoke: Address;
  domainChainId: bigint;
  /** L1 block at or before the domain's first attestation, e.g. the one that registered it. Default 0. */
  scanFromBlock?: bigint;
  /**
   * Gas bought for the delivery of each message forwarded to another domain, on top of the
   * hub's minimum for its size. Default 500_000.
   */
  deliveryGas?: bigint;
  /** Largest block range one `eth_getLogs` call is sent for. */
  maxLogRange?: bigint;
}

/** Where a relayer stands; pass the same object to every `relayPending` call. */
export interface RelayState {
  /** The last batch every message of which the hub has seen. */
  lastBatch?: DomainBatch;
}

export interface RelayedMessage {
  message: DomainMessage;
  messageHash: Hex;
  /** The `relayDomainMessage` transaction. */
  transactionHash: Hex;
  /** For an L1 destination: whether the target's callback succeeded. A failed one is retryable on the hub. */
  delivered: boolean;
}

/**
 * Relays every message of every batch attested since the last pass that the hub has not seen
 * yet, oldest batch first, and advances `state` past each batch once all its messages are
 * relayed. A pass that fails midway is retried from the failing batch by the next one.
 */
export async function relayPending(config: RelayConfig, state: RelayState): Promise<RelayedMessage[]> {
  const { l1, domain, relayer, chain, hub, spoke, domainChainId, deliveryGas = 500_000n, maxLogRange } = config;
  const account = relayer.account;
  if (!account) throw new Error("relay: relayer wallet has no account");
  const context: MessageContext = { l1ChainId: BigInt(chain.id), hub };

  const toBlock = await l1.getBlockNumber({ cacheTime: 0 });
  const fromBlock = state.lastBatch?.attestedInBlock ?? config.scanFromBlock ?? 0n;
  const batches = await fetchBatches(l1, domain, hub, spoke, domainChainId, { fromBlock, toBlock }, {
    maxLogRange,
    after: state.lastBatch,
  });

  const relayed: RelayedMessage[] = [];
  for (const batch of batches) {
    const messages = await fetchDomainBatch(domain, spoke, batch, context, { maxLogRange });
    for (const recorded of messages) {
      const { message, messageHash } = recorded;
      const alreadyRelayed = await l1.readContract({
        address: hub,
        abi: HUB_RELAY_ABI,
        functionName: "relayedDomainMessages",
        args: [domainChainId, messageHash],
      });
      if (alreadyRelayed) continue;
      const { anchor, proof } = proveMessage(messages, messageHash);
      const transactionHash = await submitRelay({ l1, relayer, account, chain, hub, message, anchor, proof, deliveryGas });
      const failed = await l1.readContract({
        address: hub,
        abi: HUB_RELAY_ABI,
        functionName: "failedDomainMessages",
        args: [domainChainId, messageHash],
      });
      relayed.push({ message, messageHash, transactionHash, delivered: !failed });
    }
    state.lastBatch = batch;
  }
  return relayed;
}

async function submitRelay(args: {
  l1: PublicClient;
  relayer: WalletClient;
  account: Account;
  chain: Chain;
  hub: Address;
  message: DomainMessage;
  anchor: Hex;
  proof: Hex[];
  deliveryGas: bigint;
}): Promise<Hex> {
  const { l1, relayer, account, chain, hub, message, anchor, proof, deliveryGas } = args;
  // An L1 callback takes no fee. A forwarded message pays for its delivery on the destination.
  let value = 0n;
  if (message.destinationChainId !== BigInt(chain.id)) {
    const [minimumFee, gasPrice] = await Promise.all([
      l1.readContract({
        address: hub,
        abi: HUB_RELAY_ABI,
        functionName: "minDeliveryFee",
        args: [BigInt((message.data.length - 2) / 2)],
      }),
      l1.readContract({ address: hub, abi: HUB_RELAY_ABI, functionName: "DOMAIN_GAS_PRICE" }),
    ]);
    value = minimumFee + deliveryGas * gasPrice;
  }
  const request = {
    account,
    chain,
    address: hub,
    abi: HUB_RELAY_ABI,
    functionName: "relayDomainMessage",
    args: [message, anchor, proof],
    value,
  } as const;
  // A callback that runs out of gas is recorded as failed, not reverted, so the estimate can
  // be too low for it. A forwarded message is an input of the destination domain.
  const gas = ((await l1.estimateContractGas(request)) * 3n) / 2n + (value === 0n ? 0n : HUB_INPUT_GAS_HEADROOM);
  const transactionHash = await relayer.writeContract({ ...request, gas });
  const receipt = await l1.waitForTransactionReceipt({ hash: transactionHash });
  if (receipt.status !== "success") {
    throw new Error(`relay: relayDomainMessage reverted for nonce ${message.sourceNonce} (${transactionHash})`);
  }
  return transactionHash;
}
