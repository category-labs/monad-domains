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
import { nonceManager as defaultNonceManager, parseAbi, type NonceManager } from "viem";

/**
 * The shape of viem's `NonceManager`, typed loosely so a manager created by another copy
 * of viem (for example in a package that depends on this one) can be shared: concurrent L1
 * sends from one key only stay ordered when every sender consumes from the same manager.
 */
export interface NonceManagerLike {
  consume(parameters: never): Promise<number>;
  increment(parameters: never): void;
  get(parameters: never): Promise<number>;
  reset(parameters: never): void;
}
import { privateKeyToAccount } from "viem/accounts";
import { encryptTransaction } from "./encryption.js";
import { domainFeeCaps, sponsoredOuterGasLimit } from "./transaction-policy.js";

/**
 * Submits a domain transaction through the L1.
 *
 * In a fully L1-sequenced domain there is no domain mempool: a transaction is a normal signed domain
 * transaction whose raw bytes are handed to `DomainHub.sequenceToDomain` on the L1. The hub
 * forwards the fee to the operator and emits the transaction; the domain's execution client
 * picks it up (ordered by L1 block + log index), decodes it, and executes it. Its execution is
 * sponsored by the enclosing L1 transaction while the signed transaction remains EIP-1559-valid.
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
  /** Domain gas limit stamped on the transaction. Default 1_000_000. */
  gas?: bigint;
  /** Domain nonce for the sender. Required unless `domainRpcUrl` is given (then it is fetched). */
  nonce?: number;
  /** If set, the sender's current domain nonce is read from this domain RPC. */
  domainRpcUrl?: string;
  /** `msg.value` forwarded to the operator on the L1 (the prepaid fee). Default 0. */
  sequencingFee?: bigint;
  /**
   * Domain viewing public key (65-byte uncompressed P-256 point, as printed by
   * `generateViewingKeyPair`). When set, `sequenceToDomain` is passed the HPKE ciphertext
   * of the signed domain transaction instead of the transaction itself; the domain execution
   * client decrypts it before executing as normal.
   */
  viewingKey?: Hex;
  /** Nonce manager for the L1 sender; defaults to viem's shared one. See `NonceManagerLike`. */
  nonceManager?: NonceManagerLike;
}

/** The slice of the DomainHub ABI sequencing needs, so no Foundry artifacts are required at runtime. */
export const SEQUENCE_ABI = parseAbi([
  "function sequenceToDomain(uint64 domainChainId, bytes rlpTx) payable",
  "event DomainTransactionSequenced(uint64 indexed domainChainId, bytes rlpTx, uint256 fee)",
]);

export interface SequenceResult {
  /** The `sequenceToDomain` transaction hash on the L1. */
  l1TxHash: Hex;
  /** `keccak256(rawTransaction)` — how the domain will index this transaction. */
  domainTxHash: Hex;
  /** The signed raw domain transaction that was sequenced. */
  rawTransaction: Hex;
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
    sequencingFee = 0n,
    viewingKey,
    nonceManager = defaultNonceManager,
  } = config;

  // The nonce manager keeps concurrent L1 sends from one key in this process ordered.
  const sender = privateKeyToAccount(senderKey, { nonceManager: nonceManager as NonceManager });

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

  // Build + sign a standard domain transaction. Its gas is sponsored by
  // the enclosing L1 transaction rather than debited from domain state.
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
  // records is the HPKE ciphertext of the signed transaction.
  const rlpTx = viewingKey ? await encryptTransaction(viewingKey, rawTransaction) : rawTransaction;

  // Submit it through the hub on the L1. The outer gas limit is also the
  // consensus-verifiable sponsorship envelope for the embedded transaction.
  const request = {
    address: hub,
    abi: SEQUENCE_ABI,
    functionName: "sequenceToDomain",
    args: [domainChainId, rlpTx],
    value: sequencingFee,
  } as const;
  const estimatedOuterGas = await publicClient.estimateContractGas({ ...request, account: sender.address });
  const l1TxHash = await wallet.writeContract({
    ...request,
    gas: sponsoredOuterGasLimit(estimatedOuterGas, gas),
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash: l1TxHash });

  // Decode the DomainTransactionSequenced event from the receipt to confirm it fired.
  const [log] = parseEventLogs({
    abi: SEQUENCE_ABI,
    eventName: "DomainTransactionSequenced",
    logs: receipt.logs,
  });
  const event = log ? { domainChainId: log.args.domainChainId, fee: log.args.fee } : null;

  return { l1TxHash, domainTxHash, rawTransaction, event };
}
