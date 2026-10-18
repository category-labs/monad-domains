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
 * of the plaintext transaction. The L1 transaction's gas limit must cover the embedded gas
 * limit (that is the sponsorship envelope), and the embedded fee caps must stay valid
 * against the L1 base fee.
 */
export interface SequencedTx {
  l1TxHash: Hex;
  domainTxHash: Hex;
  receipt: TransactionReceipt;
}

const SEQUENCE_OVERHEAD = 200_000n;

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

function feeCaps(baseFeePerGas: bigint) {
  return { maxFeePerGas: baseFeePerGas > 0n ? baseFeePerGas * 2n : 1n, maxPriorityFeePerGas: 0n } as const;
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
  const [nonce, block] = await Promise.all([
    domain.getTransactionCount({ address: identity.domain.address }),
    l1.getBlock({ blockTag: "latest" }),
  ]);
  const raw = await identity.domain.signTransaction({
    type: "eip1559",
    chainId: Number(chainId),
    nonce,
    to,
    data,
    value: 0n,
    gas,
    ...feeCaps(block.baseFeePerGas ?? 0n),
  });
  const domainTxHash = keccak256(raw);
  const ciphertext = await encryptTransaction(viewingKey, raw);

  const l1TxHash = await withFundingRetry((attempt) =>
    identity.l1.wallet.writeContract({
      account: identity.l1.kind === "browser" ? identity.l1.account : identity.l1.address,
      chain: l1Chain,
      address: deployment.hub,
      abi: HUB_ABI,
      functionName: "sequenceToDomain",
      args: [chainId, ciphertext],
      gas: gas + SEQUENCE_OVERHEAD + BigInt(attempt),
    }),
  );
  const l1Receipt = await l1.waitForTransactionReceipt({ hash: l1TxHash });
  if (l1Receipt.status !== "success") throw new Error(`sequenceToDomain reverted (${l1TxHash})`);
  const receipt = await waitForDomainReceipt(domain, domainTxHash, params.timeoutMs);
  return { l1TxHash, domainTxHash, receipt };
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
  request: { address: Address; abi: TAbi; functionName: string; args?: readonly unknown[]; gas?: bigint; value?: bigint },
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
        100n;
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
