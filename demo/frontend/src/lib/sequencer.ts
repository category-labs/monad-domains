import { keccak256, type Abi, type Address, type Hex, type PublicClient, type TransactionReceipt } from "viem";
import type { Identity } from "./account";
import { domainClient, l1, l1Chain } from "./chain";
import { HUB_ABI } from "./demo-abi";
import { deployment } from "./deployment";
import { encryptTransaction } from "./encryption";

/**
 * Submitting domain transactions from the browser, mirroring `offchain/src/sequence.ts`.
 *
 * A domain has no mempool: a domain transaction is a normal signed EIP-1559 transaction
 * (chain id = domain id, no value) signed by the visitor's domain account, HPKE-encrypted
 * to the domain's viewing key and handed to `DomainHub.sequenceToDomain` on the L1 by the
 * visitor's L1 signer. The node derives the domain block from the hub's events, decrypts
 * and executes the transaction; its receipt is served by the domain route under the hash
 * of the plaintext transaction. The L1 call pays a fee of `gas * DOMAIN_GAS_PRICE`, which
 * buys the embedded transaction's gas limit; nothing is charged on the domain, whose base
 * fee is that same price, so the embedded fee cap offers exactly it.
 */
export interface SequencedTx {
  l1TxHash: Hex;
  domainTxHash: Hex;
  /** What the courier transaction carried: the signed domain transaction, encrypted. */
  ciphertext: Hex;
  receipt: TransactionReceipt;
}

/**
 * Gas added to the estimate of an L1 call that records a domain input (a sequenced
 * transaction, a deposit): the first input a domain gets in an L1 block opens the domain's
 * next block in the hub's queue, which an estimate against the previous block does not pay for.
 */
export const HUB_INPUT_GAS_HEADROOM = 100_000n;

let domainGasPrice: Promise<bigint> | undefined;
/** The hub's price of one unit of domain gas: a constant, read once. */
export function readDomainGasPrice(): Promise<bigint> {
  domainGasPrice ??= l1.readContract({ address: deployment.hub, abi: HUB_ABI, functionName: "DOMAIN_GAS_PRICE" });
  return domainGasPrice;
}

/** The fee to attach to an L1 call that sends a message of `dataLength` bytes to a domain and buys `gas` for its delivery. */
export async function deliveryFee(dataLength: number, gas: bigint): Promise<bigint> {
  const [minimum, price] = await Promise.all([
    l1.readContract({ address: deployment.hub, abi: HUB_ABI, functionName: "minDeliveryFee", args: [BigInt(dataLength)] }),
    readDomainGasPrice(),
  ]);
  return minimum + gas * price;
}

/**
 * Monad's transaction pool checks the sender's balance against state that can lag the
 * receipts a visitor already saw by a couple of seconds, so a transaction sent right after
 * a faucet drip can be rejected with "insufficient balance" although the drip is final.
 * The pool also remembers a rejected transaction by hash, so re-sending the identical
 * bytes is rejected again without re-evaluation: every retry must differ. Callers get the
 * attempt number and add it to the gas limit, which changes the signed transaction.
 */
async function withFundingRetry<T>(send: (attempt: number) => Promise<T>, timeoutMs = 15_000): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (let attempt = 0; ; attempt++) {
    try {
      return await send(attempt);
    } catch (error) {
      const text = `${(error as { details?: string }).details ?? ""} ${error instanceof Error ? error.message : ""}`;
      if (!/insufficient (balance|funds)/i.test(text) || Date.now() > deadline) throw error;
      await new Promise((resolve) => setTimeout(resolve, 1_000));
    }
  }
}


export async function sequenceDomainTx(params: {
  identity: Identity;
  chainId: bigint;
  to: Address;
  data: Hex;
  gas: bigint;
  viewingKey: Hex;
  timeoutMs?: number;
}): Promise<SequencedTx> {
  const { identity, chainId, to, data, gas, viewingKey } = params;
  const domain = domainClient(chainId);
  const [nonce, gasPrice] = await Promise.all([
    domain.getTransactionCount({ address: identity.domain.address }),
    readDomainGasPrice(),
  ]);
  const raw = await identity.domain.signTransaction({
    type: "eip1559",
    chainId: Number(chainId),
    nonce,
    to,
    data,
    value: 0n,
    gas,
    maxFeePerGas: gasPrice,
    maxPriorityFeePerGas: 0n,
  });
  const domainTxHash = keccak256(raw);
  const ciphertext = await encryptTransaction(viewingKey, chainId, raw);
  const account = identity.l1.kind === "browser" ? identity.l1.account : identity.l1.address;
  const call = {
    account,
    address: deployment.hub,
    abi: HUB_ABI,
    functionName: "sequenceToDomain",
    args: [chainId, ciphertext],
    value: gas * gasPrice,
  } as const;

  const l1TxHash = await withFundingRetry(async (attempt) =>
    identity.l1.wallet.writeContract({
      ...call,
      chain: l1Chain,
      gas: (await l1.estimateContractGas(call)) + HUB_INPUT_GAS_HEADROOM + BigInt(attempt),
    }),
  );
  const l1Receipt = await l1.waitForTransactionReceipt({ hash: l1TxHash });
  if (l1Receipt.status !== "success") throw new Error(`sequenceToDomain reverted (${l1TxHash})`);
  const receipt = await waitForDomainReceipt(domain, domainTxHash, params.timeoutMs);
  return { l1TxHash, domainTxHash, ciphertext, receipt };
}

/** Polls the domain route for the embedded transaction's receipt; throws if it reverted. */
export async function waitForDomainReceipt(domain: PublicClient, hash: Hex, timeoutMs = 120_000): Promise<TransactionReceipt> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const receipt = await domain.getTransactionReceipt({ hash }).catch(() => null);
    if (receipt) {
      if (receipt.status !== "success") throw new Error(`domain transaction reverted (${hash})`);
      return receipt;
    }
    if (Date.now() > deadline) throw new Error(`timed out waiting for the domain receipt of ${hash}`);
    await new Promise((resolve) => setTimeout(resolve, 700));
  }
}

/** Sends one L1 contract call from the visitor's L1 signer and waits for its receipt. */
export async function sendL1<TAbi extends Abi>(
  identity: Identity,
  request: { address: Address; abi: TAbi; functionName: string; args?: readonly unknown[]; gas?: bigint; value?: bigint; gasHeadroom?: bigint },
): Promise<{ hash: Hex; receipt: TransactionReceipt }> {
  const account = identity.l1.kind === "browser" ? identity.l1.account : identity.l1.address;
  const hash = await withFundingRetry(async (attempt) => {
    const gas =
      request.gas ??
      ((await l1.estimateContractGas({
        account,
        address: request.address,
        abi: request.abi as Abi,
        functionName: request.functionName,
        args: request.args as never,
        value: request.value,
      } as never)) *
        120n) /
        100n + (request.gasHeadroom ?? 0n);
    return identity.l1.wallet.writeContract({
      account,
      chain: l1Chain,
      address: request.address,
      abi: request.abi as Abi,
      functionName: request.functionName,
      args: request.args as never,
      gas: gas + BigInt(attempt),
      value: request.value,
    } as never);
  });
  const receipt = await l1.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${request.functionName} reverted (${hash})`);
  return { hash, receipt };
}
