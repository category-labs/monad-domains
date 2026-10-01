/** Fee fields for an L1-prepaid domain transaction. */
export interface DomainFeeCaps {
  maxFeePerGas: bigint;
  maxPriorityFeePerGas: bigint;
}

/**
 * Domain transactions still pass ordinary EIP-1559 validity checks even
 * though their execution is sponsored by the enclosing L1 transaction.
 */
export function domainFeeCaps(baseFeePerGas: bigint): DomainFeeCaps {
  return {
    maxFeePerGas: baseFeePerGas > 0n ? baseFeePerGas * 2n : 1n,
    maxPriorityFeePerGas: 0n,
  };
}

/** Ensure the enclosing L1 transaction sponsors the declared domain work. */
export function sponsoredOuterGasLimit(estimatedOuterGas: bigint, innerGasLimit: bigint): bigint {
  return estimatedOuterGas > innerGasLimit ? estimatedOuterGas : innerGasLimit;
}
