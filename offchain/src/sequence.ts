import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  keccak256,
  parseEventLogs,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { loadArtifact } from "./artifacts.js";
import { encryptTransaction } from "./encryption.js";
import { domainFeeCaps, domainGasFee, readDomainGasPrice } from "./transaction-policy.js";

/**
 * Submits a domain transaction through the L1.
 *
 * In a fully L1-sequenced domain there is no domain mempool: a transaction is a normal signed domain
 * transaction whose raw bytes are handed to `DomainHub.sequenceToDomain` on the L1. The hub
 * forwards the fee to the fee recipient and emits the transaction; the domain's execution client
 * picks it up (ordered by L1 block + log index), decodes it, and executes it if the fee covers its
 * gas limit at the hub's `DOMAIN_GAS_PRICE`. Nothing is charged on the domain.
 */
export interface SequenceConfig {
  /** L1 RPC endpoint where the hub lives. */
  l1RpcUrl: string;
  /** The DomainHub address on the L1. */
  hub: Address;
  /** Target domain chain id. */
  domainChainId: bigint;
  /** Key that both signs the domain transaction and submits `sequenceToDomain` on the L1. */
  senderKey: Hex;
  /** Domain target address. Omit for a contract creation. */
  to?: Address;
  /** Domain calldata. Default `0x`. */
  data?: Hex;
  /** Domain native value. Default 0 (domains here have no native gas token; use wrapped MON). */
  value?: bigint;
  /** Domain gas limit stamped on the transaction; the L1 fee pays for exactly this much. Default 1_000_000. */
  gas?: bigint;
  /** Domain nonce for the sender. Required unless `domainRpcUrl` is given (then it is fetched). */
  nonce?: number;
  /** If set, the sender's current domain nonce is read from this domain RPC. */
  domainRpcUrl?: string;
  /**
   * Domain viewing public key (65-byte uncompressed P-256 point, as printed by
   * `generateViewingKeyPair`). When set, `sequenceToDomain` is passed the HPKE ciphertext
   * of the signed domain transaction instead of the transaction itself; the domain execution
   * client decrypts it before executing as normal. When omitted, the key the domain
   * published on the hub at registration is used; plaintext only if the hub holds none.
   */
  viewingKey?: Hex;
}

export interface SequenceResult {
  /** The `sequenceToDomain` transaction hash on the L1. */
  l1TxHash: Hex;
  /** `keccak256(rawTransaction)` — how the domain will index this transaction. */
  domainTxHash: Hex;
  /** The signed raw domain transaction that was sequenced. */
  rawTransaction: Hex;
  /** The fee paid on the L1: `gas * DOMAIN_GAS_PRICE`. */
  fee: bigint;
  /** The `DomainTransactionSequenced` event decoded from the receipt, or null if not found. */
  event: { domainChainId: bigint; fee: bigint } | null;
}

export async function sequenceTransaction(config: SequenceConfig): Promise<SequenceResult> {
  const {
    l1RpcUrl,
    hub,
    domainChainId,
    senderKey,
    to,
    data = "0x",
    value = 0n,
    gas = 1_000_000n,
    domainRpcUrl,
    viewingKey,
  } = config;

  const sender = privateKeyToAccount(senderKey);

  // Build L1 clients before signing so the embedded transaction can use
  // fee fields valid for the current L1 execution environment.
  const probe = createPublicClient({ transport: http(l1RpcUrl) });
  const l1ChainId = await probe.getChainId();
  const l1Chain = defineChain({
    id: l1ChainId,
    name: `l1-${l1ChainId}`,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [l1RpcUrl] } },
  });
  const publicClient = createPublicClient({ chain: l1Chain, transport: http(l1RpcUrl) });
  const wallet = createWalletClient({ account: sender, chain: l1Chain, transport: http(l1RpcUrl) });

  // Resolve the domain nonce: explicit, or read from a domain RPC if one is available.
  let nonce = config.nonce;
  if (nonce === undefined) {
    if (!domainRpcUrl) throw new Error("sequence: provide `nonce` or `domainRpcUrl` to look it up");
    const domain = createPublicClient({ transport: http(domainRpcUrl) });
    nonce = await domain.getTransactionCount({ address: sender.address });
  }

  const latestBlock = await publicClient.getBlock({ blockTag: "latest" });
  const feeCaps = domainFeeCaps(latestBlock.baseFeePerGas ?? (await publicClient.getGasPrice()));
  // The fee never buys more than one L1 block of gas, so a larger limit could never execute.
  if (gas > latestBlock.gasLimit) throw new Error(`sequence: gas ${gas} exceeds the L1 block gas limit ${latestBlock.gasLimit}`);

  // Build + sign a standard domain transaction. Its gas is paid for on the L1
  // rather than debited from domain state.
  const rawTransaction = await sender.signTransaction({
    type: "eip1559",
    chainId: Number(domainChainId),
    nonce,
    to,
    data,
    value,
    gas,
    ...feeCaps,
  });
  const domainTxHash = keccak256(rawTransaction);

  // The hub forwards `rlpTx` as opaque bytes: when the domain has a viewing key, what it
  // records is the HPKE ciphertext of the signed transaction. Without an explicit key, use
  // the one the domain published on the hub.
  const hubArt = loadArtifact("DomainHub.sol", "DomainHub");
  let encryptionKey = viewingKey;
  if (!encryptionKey) {
    let published: Hex;
    try {
      published = (await publicClient.readContract({
        address: hub,
        abi: hubArt.abi,
        functionName: "viewingKeys",
        args: [domainChainId],
      })) as Hex;
    } catch (error) {
      // Never downgrade to plaintext silently: if the hub cannot be read, the caller must
      // say explicitly what key (if any) to use.
      throw new Error(
        `sequence: could not read the domain's viewing key from hub ${hub}; pass viewingKey explicitly ` +
          `(${error instanceof Error ? error.message.split("\n")[0] : String(error)})`,
      );
    }
    if (published && published !== "0x") encryptionKey = published;
  }
  const rlpTx = encryptionKey ? await encryptTransaction(encryptionKey, rawTransaction) : rawTransaction;

  // Submit it through the hub on the L1 with the fee that buys its gas limit.
  const fee = domainGasFee(gas, await readDomainGasPrice(publicClient, hub));
  const l1TxHash = await wallet.writeContract({
    address: hub,
    abi: hubArt.abi,
    functionName: "sequenceToDomain",
    args: [domainChainId, rlpTx],
    value: fee,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash: l1TxHash });

  // Decode the DomainTransactionSequenced event from the receipt to confirm it fired.
  const [log] = parseEventLogs({
    abi: hubArt.abi,
    eventName: "DomainTransactionSequenced",
    logs: receipt.logs,
  });
  const args = log?.args as { domainChainId?: bigint; fee?: bigint } | undefined;
  const event =
    args && args.domainChainId !== undefined && args.fee !== undefined
      ? { domainChainId: args.domainChainId, fee: args.fee }
      : null;

  return { l1TxHash, domainTxHash, rawTransaction, fee, event };
}
