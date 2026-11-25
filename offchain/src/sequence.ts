import {
  createPublicClient,
  createWalletClient,
  http,
  keccak256,
  parseAbi,
  parseEventLogs,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { domainTransportFor, fetchL1Chain } from "./chain.js";
import { encryptTransaction } from "./encryption.js";

const HUB_SEQUENCING_ABI = parseAbi([
  "function DOMAIN_GAS_PRICE() view returns (uint256)",
  "function minSequencingFee(uint256 payloadLength) pure returns (uint256)",
  "function sequenceToDomain(uint64 domainChainId, bytes rlpTx) payable",
  "function encryptionPubKeys(uint64 domainChainId) view returns (bytes)",
  "event DomainTransactionSequenced(uint64 indexed domainChainId, bytes rlpTx, uint256 fee)",
]);

/**
 * Fee fields of a domain transaction. Nothing is charged for it on the domain, but the signed
 * transaction must still pass ordinary EIP-1559 validity checks there, and every domain block
 * has the hub's `DOMAIN_GAS_PRICE` (`readDomainGasPrice`) as its base fee: a transaction that
 * offers less is included as failed, without executing.
 */
export function domainFeeCaps(domainGasPrice: bigint): { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint } {
  return { maxFeePerGas: domainGasPrice, maxPriorityFeePerGas: 0n };
}

/**
 * Gas to add to the estimate of an L1 call that records a domain input (a sequenced
 * transaction, a message, a deposit). The first input of an L1 block opens the domain's next
 * block in the hub's input queue, and the first of a checkpoint period opens the period; an
 * estimate against the latest block may cover neither.
 */
export const HUB_INPUT_GAS_HEADROOM = 100_000n;

/**
 * The hub's price of one unit of domain gas, in wei of the L1 native token. A sequencing or
 * message call buys `fee / price` gas: a sequenced transaction executes only if that covers its
 * gas limit, and a message delivery runs with exactly that much.
 */
export async function readDomainGasPrice(l1: PublicClient, hub: Address): Promise<bigint> {
  return l1.readContract({ address: hub, abi: HUB_SEQUENCING_ABI, functionName: "DOMAIN_GAS_PRICE" });
}

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
  /** If set, the sender's current domain nonce is read from this domain RPC, as the sender. */
  domainRpcUrl?: string;
  /**
   * Domain encryption public key (32-byte X25519 public key). The signed transaction is
   * HPKE-encrypted to it before sequencing. When omitted, the key the domain published on the
   * hub is used. A missing key is an error.
   */
  encryptionPubKey?: Hex;
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

/**
 * Submits a domain transaction through the L1. A domain has no mempool: a transaction is a
 * normal signed domain transaction whose (encrypted) raw bytes are handed to
 * `DomainHub.sequenceToDomain` with a fee of `gas * DOMAIN_GAS_PRICE`, which buys exactly the
 * transaction's gas limit; nothing is charged on the domain. The hub forwards the fee to the fee
 * recipient and emits the payload; the domain client decrypts and executes it in the domain block
 * derived from that L1 block.
 */
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
    encryptionPubKey,
  } = config;

  const sender = privateKeyToAccount(senderKey);
  const l1Chain = await fetchL1Chain(l1RpcUrl);
  const l1 = createPublicClient({ chain: l1Chain, transport: http(l1RpcUrl) });
  const wallet = createWalletClient({ account: sender, chain: l1Chain, transport: http(l1RpcUrl) });

  let nonce = config.nonce;
  if (nonce === undefined) {
    if (!domainRpcUrl) throw new Error("sequence: provide `nonce` or `domainRpcUrl` to look it up");
    // The domain RPC serves an account its own nonce, to a token the account signed.
    const domain = createPublicClient({ transport: await domainTransportFor(domainRpcUrl, domainChainId, senderKey) });
    nonce = await domain.getTransactionCount({ address: sender.address });
  }

  const latestBlock = await l1.getBlock({ blockTag: "latest" });
  // The fee never buys more than one L1 block of gas, so a larger limit could never execute.
  if (gas > latestBlock.gasLimit) throw new Error(`sequence: gas ${gas} exceeds the L1 block gas limit ${latestBlock.gasLimit}`);
  const domainGasPrice = await readDomainGasPrice(l1, hub);
  const rawTransaction = await sender.signTransaction({
    type: "eip1559",
    chainId: Number(domainChainId),
    nonce,
    to,
    data,
    value,
    gas,
    ...domainFeeCaps(domainGasPrice),
  });
  const domainTxHash = keccak256(rawTransaction);

  let encryptionKey = encryptionPubKey;
  if (!encryptionKey) {
    let published: Hex;
    try {
      published = await l1.readContract({
        address: hub,
        abi: HUB_SEQUENCING_ABI,
        functionName: "encryptionPubKeys",
        args: [domainChainId],
      });
    } catch (error) {
      throw new Error(
        `sequence: could not read the domain's encryption public key from hub ${hub}; pass encryptionPubKey explicitly ` +
          `(${error instanceof Error ? error.message.split("\n")[0] : String(error)})`,
      );
    }
    if (published !== "0x") encryptionKey = published;
  }
  if (!encryptionKey || encryptionKey === "0x") {
    throw new Error("sequence: domain has no encryption public key; register one before submitting private transactions");
  }
  const rlpTx = await encryptTransaction(encryptionKey, domainChainId, rawTransaction);

  const fee = gas * domainGasPrice;
  // The hub refuses a fee below its minimum for the payload's size.
  const payloadLength = BigInt((rlpTx.length - 2) / 2);
  const minimumFee = await l1.readContract({
    address: hub,
    abi: HUB_SEQUENCING_ABI,
    functionName: "minSequencingFee",
    args: [payloadLength],
  });
  if (fee < minimumFee) {
    throw new Error(
      `sequence: gas ${gas} pays ${fee} wei, below the hub's minimum of ${minimumFee} wei for a ${payloadLength}-byte payload`,
    );
  }
  const request = {
    account: sender,
    address: hub,
    abi: HUB_SEQUENCING_ABI,
    functionName: "sequenceToDomain",
    args: [domainChainId, rlpTx],
    value: fee,
  } as const;
  const l1TxHash = await wallet.writeContract({
    ...request,
    gas: (await l1.estimateContractGas(request)) + HUB_INPUT_GAS_HEADROOM,
  });
  const receipt = await l1.waitForTransactionReceipt({ hash: l1TxHash });
  const [log] = parseEventLogs({ abi: HUB_SEQUENCING_ABI, eventName: "DomainTransactionSequenced", logs: receipt.logs });
  const event = log ? { domainChainId: log.args.domainChainId, fee: log.args.fee } : null;

  return { l1TxHash, domainTxHash, rawTransaction, fee, event };
}
