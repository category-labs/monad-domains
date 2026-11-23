import { createPublicClient, defineChain, http, type Address, type Chain, type Hex, type HttpTransport } from "viem";
import { privateKeyToAccount } from "viem/accounts";

/** A viem chain for the L1 behind `rpcUrl`, with its chain id read from the endpoint. */
export async function fetchL1Chain(rpcUrl: string): Promise<Chain> {
  const id = await createPublicClient({ transport: http(rpcUrl) }).getChainId();
  return defineChain({
    id,
    name: `l1-${id}`,
    nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  });
}

/** The DomainSpoke of every domain: the execution client puts it in the domain's genesis state at this address. */
export const DOMAIN_SPOKE: Address = "0x000000000000000000446f6d61696E53706f6B65";

/** HTTP header the domain RPC reads the access token from. */
export const DOMAIN_RPC_AUTH_HEADER = "X-Authorization-Token";

/**
 * The access token `key`'s account presents to the RPC of domain `domainChainId`: an EIP-712
 * signature over the domain chain id, which does not expire.
 */
export async function signDomainAccessToken(key: Hex, domainChainId: bigint): Promise<string> {
  const signature = await privateKeyToAccount(key).signTypedData({
    domain: { name: "Monad Domain RPC", version: "1", chainId: Number(domainChainId) },
    types: { DomainAccessToken: [{ name: "chainId", type: "uint64" }] },
    primaryType: "DomainAccessToken",
    message: { chainId: domainChainId },
  });
  return `${domainChainId}.${signature}`;
}

/** Transport of a domain RPC. It serves no request without a token, and most methods to operators only. */
export function domainTransport(rpcUrl: string, token?: string, options: { batch?: boolean } = {}): HttpTransport {
  return http(rpcUrl, {
    ...options,
    ...(token ? { fetchOptions: { headers: { [DOMAIN_RPC_AUTH_HEADER]: token } } } : {}),
  });
}

/** Transport of the RPC of domain `domainChainId`, authenticated as `key`'s account if one is given. */
export async function domainTransportFor(
  rpcUrl: string,
  domainChainId: bigint,
  key?: Hex,
  options: { batch?: boolean } = {},
): Promise<HttpTransport> {
  return domainTransport(rpcUrl, key ? await signDomainAccessToken(key, domainChainId) : undefined, options);
}
