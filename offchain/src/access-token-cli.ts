import type { Hex } from "viem";
import { DOMAIN_RPC_AUTH_HEADER, signDomainAccessToken } from "./chain.js";

/**
 * Prints the access token an account presents to a domain's RPC.
 *
 *   DOMAIN_CHAIN_ID=...  \
 *   ACCOUNT_KEY=0x...    \  # the account's key; an operator's key gives access to every method
 *     npm run access-token
 *
 *   curl -H "X-Authorization-Token: $(npm run --silent access-token)" ...
 */
async function main() {
  const domainChainId = process.env.DOMAIN_CHAIN_ID;
  const key = process.env.ACCOUNT_KEY as Hex | undefined;
  if (!domainChainId || !key) throw new Error(`access-token: DOMAIN_CHAIN_ID and ACCOUNT_KEY are required (the token goes in the ${DOMAIN_RPC_AUTH_HEADER} header)`);
  console.log(await signDomainAccessToken(key, BigInt(domainChainId)));
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
