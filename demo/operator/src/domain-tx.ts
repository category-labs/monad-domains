import type { Hex, PublicClient, TransactionReceipt } from "viem";
import { sequenceTransaction, type SequenceConfig, type SequenceResult } from "@domain-bridging/prover";

/** Polls the domain route for the receipt of a sequenced transaction. */
export async function waitForDomainReceipt(
  domain: PublicClient,
  hash: Hex,
  timeoutMs = 120_000,
  label = "domain transaction",
): Promise<TransactionReceipt> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const receipt = await domain.getTransactionReceipt({ hash }).catch(() => null);
    if (receipt) return receipt;
    if (Date.now() > deadline) throw new Error(`${label} ${hash} was not executed in time`);
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
}

/**
 * Sequences one domain transaction through the hub and waits until the domain executed it.
 * Throws if it reverted on the domain. Callers that share a sender key must serialize their
 * calls: the domain nonce is read from the domain route at signing time.
 */
export async function sequenceAndWait(
  domain: PublicClient,
  config: SequenceConfig,
  options: { timeoutMs?: number; label?: string } = {},
): Promise<{ sequenced: SequenceResult; receipt: TransactionReceipt }> {
  const sequenced = await sequenceTransaction(config);
  const receipt = await waitForDomainReceipt(domain, sequenced.domainTxHash, options.timeoutMs, options.label);
  if (receipt.status !== "success") {
    throw new Error(`${options.label ?? "domain transaction"} ${sequenced.domainTxHash} reverted on the domain`);
  }
  return { sequenced, receipt };
}
