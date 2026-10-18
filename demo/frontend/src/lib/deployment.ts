import type { Address, Hex } from "viem";
import testnet from "../../../../deployments/testnet.json";

/** Mirrors `demo/operator/src/config.ts`: the addresses one demo deployment consists of. */
export interface DemoDomain {
  chainId: number;
  spoke: Address;
  viewingKey: Hex;
  startBlock: number;
  l1Bridge: Address;
  domainBridge: Address;
  bank: Address;
  token: Address;
}

export interface DemoDeployment {
  name: string;
  l1ChainId: number;
  hub: Address;
  rate: { num: string; den: string };
  tokens: { eur: Address; usd: Address };
  pool: Address;
  bankOperator: Address;
  domains: { A: DemoDomain; B: DemoDomain };
}

/**
 * The deployment the page is built for. `VITE_DEPLOYMENT_JSON` (the file's contents) overrides
 * it: at build time for the page, from the environment for the scripts.
 */
export const deployment: DemoDeployment = (() => {
  const override =
    (import.meta.env?.VITE_DEPLOYMENT_JSON as string | undefined) ??
    (typeof process !== "undefined" ? process.env.VITE_DEPLOYMENT_JSON : undefined);
  return (override ? JSON.parse(override) : testnet) as DemoDeployment;
})();

export const CHAIN_A = BigInt(deployment.domains.A.chainId);
export const CHAIN_B = BigInt(deployment.domains.B.chainId);
export const L1_CHAIN_ID = deployment.l1ChainId;
export const RATE_NUM = BigInt(deployment.rate.num);
export const RATE_DEN = BigInt(deployment.rate.den);

/** The pool's TOKEN_IN quote for `amountOut`, rounded up - mirrors `quoteIn`. */
export function quoteEurIn(amountOut: bigint): bigint {
  return (amountOut * RATE_DEN + RATE_NUM - 1n) / RATE_NUM;
}

/** Block explorer for the L1 (Monad testnet). Domains have none. */
export const EXPLORER = L1_CHAIN_ID === 10143 ? "https://testnet.monadexplorer.com" : null;
