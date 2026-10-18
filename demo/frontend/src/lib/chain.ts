import { createPublicClient, defineChain, http, type Chain, type PublicClient } from "viem";
import { CHAIN_A, CHAIN_B, L1_CHAIN_ID } from "./deployment";

/**
 * In the browser everything goes through the page's own origin: `/rpc` is the node's L1
 * route and `/rpc/domain/<id>` its domain routes (see vite.config.ts / server.mjs). The
 * node-side scripts hit the RPC directly (`RPC_URL`, optionally `DOMAIN_RPC_URL`).
 */
const inBrowser = typeof window !== "undefined";
/** The operator service's API (same-origin `/api` in the browser). */
export const OPERATOR_URL = inBrowser ? "" : (process.env.OPERATOR_URL ?? "http://127.0.0.1:8787").replace(/\/$/, "");
// Scripts default to the operator's RPC gateway, like the page does through its proxy.
export const RPC_URL = inBrowser ? "/rpc" : (process.env.RPC_URL ?? `${OPERATOR_URL}/rpc`).replace(/\/$/, "");
const DOMAIN_RPC = inBrowser
  ? "/rpc/domain"
  : (process.env.DOMAIN_RPC_URL ?? (process.env.RPC_URL ? `${RPC_URL}/domain` : `${OPERATOR_URL}/rpc/domain`)).replace(/\/$/, "");

export const domainRpcUrl = (chainId: bigint) => `${DOMAIN_RPC}/${chainId}`;

/**
 * Headers the node-side scripts attach: `DEMO_AUTH=user:password` when they go through a
 * password-protected page server. The browser needs none (it holds the Basic credentials).
 */
export function scriptHeaders(): Record<string, string> {
  if (inBrowser) return {};
  const auth = process.env.DEMO_AUTH;
  return auth ? { authorization: `Basic ${Buffer.from(auth).toString("base64")}` } : {};
}

/** The L1 as a viem chain - wallets are asked to switch to it. */
export const l1Chain: Chain = defineChain({
  id: L1_CHAIN_ID,
  name: L1_CHAIN_ID === 10143 ? "Monad Testnet" : `monad-${L1_CHAIN_ID}`,
  nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: [L1_CHAIN_ID === 10143 ? "https://testnet-rpc.monad.xyz" : RPC_URL] } },
  blockExplorers: L1_CHAIN_ID === 10143 ? { default: { name: "Monad Explorer", url: "https://testnet.monadexplorer.com" } } : undefined,
});

const domainChain = (chainId: bigint): Chain =>
  defineChain({
    id: Number(chainId),
    name: `domain-${chainId}`,
    nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
    rpcUrls: { default: { http: [domainRpcUrl(chainId)] } },
  });

/** HTTP transport for every client, with the scripts' credentials when running outside a browser. */
export const transport = (url: string) => http(url, { timeout: 30_000, retryCount: 2, fetchOptions: { headers: scriptHeaders() } });

export const l1: PublicClient = createPublicClient({ chain: l1Chain, transport: transport(RPC_URL), pollingInterval: 500 });
export const domainA: PublicClient = createPublicClient({ chain: domainChain(CHAIN_A), transport: transport(domainRpcUrl(CHAIN_A)), pollingInterval: 500 });
export const domainB: PublicClient = createPublicClient({ chain: domainChain(CHAIN_B), transport: transport(domainRpcUrl(CHAIN_B)), pollingInterval: 500 });

export const domainClient = (chainId: bigint): PublicClient => {
  if (chainId === CHAIN_A) return domainA;
  if (chainId === CHAIN_B) return domainB;
  throw new Error(`no domain client for chain id ${chainId}`);
};

/** Polls `fn` until `predicate` holds. */
export async function until<T>(
  label: string,
  fn: () => Promise<T>,
  predicate: (value: T) => boolean,
  timeoutMs = 120_000,
  intervalMs = 1_000,
): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      const value = await fn();
      if (predicate(value)) return value;
    } catch {
      // transient RPC failure; keep polling
    }
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${label}`);
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
}
