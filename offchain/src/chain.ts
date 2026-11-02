import { createPublicClient, defineChain, http, type Chain } from "viem";

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
