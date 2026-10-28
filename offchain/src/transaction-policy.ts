import { parseAbiItem, type Address, type PublicClient } from "viem";

/** Fee fields for an L1-prepaid domain transaction. */
export interface DomainFeeCaps {
  maxFeePerGas: bigint;
  maxPriorityFeePerGas: bigint;
}

/**
 * Domain transactions still pass ordinary EIP-1559 validity checks even
 * though nothing is charged for them on the domain.
 */
export function domainFeeCaps(baseFeePerGas: bigint): DomainFeeCaps {
  return {
    maxFeePerGas: baseFeePerGas > 0n ? baseFeePerGas * 2n : 1n,
    maxPriorityFeePerGas: 0n,
  };
}

const HUB_FEE_ABI = [
  parseAbiItem("function DOMAIN_GAS_PRICE() view returns (uint256)"),
  parseAbiItem("function minDeliveryFee(uint256 dataLength) pure returns (uint256)"),
] as const;

/** The hub's price of one unit of domain gas, in wei of the L1 native token. */
export async function readDomainGasPrice(client: PublicClient, hub: Address): Promise<bigint> {
  return (await client.readContract({ address: hub, abi: HUB_FEE_ABI, functionName: "DOMAIN_GAS_PRICE" })) as bigint;
}

/**
 * The smallest fee the hub records a message of `dataLength` payload bytes with: it buys the
 * spoke enough gas to deliver or to mark the message failed and retryable. A target that needs
 * more gas than that must be paid for with `domainGasFee`.
 */
export async function readMinDeliveryFee(client: PublicClient, hub: Address, dataLength: number): Promise<bigint> {
  return (await client.readContract({
    address: hub, abi: HUB_FEE_ABI, functionName: "minDeliveryFee", args: [BigInt(dataLength)],
  })) as bigint;
}

/**
 * The fee that buys `gas` units of domain gas. A sequenced transaction executes only if the
 * fee covers its gas limit; a message delivery runs with exactly the gas its fee bought.
 */
export function domainGasFee(gas: bigint, gasPrice: bigint): bigint {
  return gas * gasPrice;
}
