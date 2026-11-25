import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { Address, Hex } from "viem";

/**
 * The addresses one demo deployment consists of, shared by the operator service, the deploy
 * script and the frontend (`deployments/<name>.json` at the repository root).
 */
export interface DemoDomain {
  /** Domain chain id, `(n << 16) | l1ChainId`. */
  chainId: number;
  /** The protocol spoke on this domain: the one in the domain's genesis state. */
  spoke: Address;
  /** Domain viewing public key (32-byte X25519 key); every sequenced transaction is encrypted to it. */
  viewingKey: Hex;
  /** First domain block worth scanning for the banks' logs. A domain numbers its own blocks, from 0. */
  startBlock: number;
  /** L1 block that registered the domain: where the relayer starts scanning the hub. */
  l1StartBlock?: number;
  /** The demo bridge pair this domain's bank ledger travels through. */
  l1Bridge: Address;
  domainBridge: Address;
  /** The L2Bank on this domain. */
  bank: Address;
  /** The L1 ledger the bank's domain ledger wraps (EUR on A, USD on B). */
  token: Address;
}

export interface DemoDeployment {
  name: string;
  l1ChainId: number;
  hub: Address;
  /** Pool rate: 1 EUR = num/den USD. */
  rate: { num: string; den: string };
  tokens: { eur: Address; usd: Address };
  pool: Address;
  /** Account that operates both banks and may lock pool liquidity. */
  bankOperator: Address;
  domains: { A: DemoDomain; B: DemoDomain };
}

/** The protocol-level part a demo deployment is layered on (what `npm run setup` produced). */
export interface BaseDeployment {
  name: string;
  l1ChainId: number;
  hub: Address;
  domains: {
    A: Pick<DemoDomain, "chainId" | "spoke" | "viewingKey" | "startBlock" | "l1StartBlock">;
    B: Pick<DemoDomain, "chainId" | "spoke" | "viewingKey" | "startBlock" | "l1StartBlock">;
  };
}

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

export function deploymentPath(nameOrPath: string): string {
  return nameOrPath.endsWith(".json") ? resolve(nameOrPath) : resolve(REPO_ROOT, "deployments", `${nameOrPath}.json`);
}

export function loadDeployment<T = DemoDeployment>(nameOrPath: string): T {
  return JSON.parse(readFileSync(deploymentPath(nameOrPath), "utf8")) as T;
}

export function saveDeployment(nameOrPath: string, deployment: DemoDeployment): string {
  const path = deploymentPath(nameOrPath);
  writeFileSync(path, JSON.stringify(deployment, null, 2) + "\n");
  return path;
}

/**
 * JSON-RPC endpoint of a domain. Every domain is served by an RPC of its own, so the endpoint
 * is configured (`DOMAIN_A_RPC_URL`, `DOMAIN_B_RPC_URL`); it requires an access token.
 */
export function domainRpcUrl(chainId: number | bigint, configured?: string): string {
  if (!configured) throw new Error(`no RPC endpoint configured for domain ${chainId} (DOMAIN_A_RPC_URL / DOMAIN_B_RPC_URL)`);
  return configured;
}
