/**
 * Where the same-origin proxies point, from the environment:
 *   OPERATOR_URL    the operator service (its /api routes and, by default, its /rpc gateway)
 *   RPC_URL         optional: the node's L1 JSON-RPC URL, to bypass the operator's gateway
 *   DOMAIN_RPC_URL  optional: prefix of the domain routes; default `${RPC_URL}/domain`
 * With only OPERATOR_URL set, every RPC call goes through the operator, which is the one
 * component that has to reach the node (and the only place its access token lives).
 */
export function proxyTargets(env) {
  const operator = (env.OPERATOR_URL ?? "http://127.0.0.1:8787").replace(/\/$/, "");
  const rpc = (env.RPC_URL ?? `${operator}/rpc`).replace(/\/$/, "");
  const domainRpc = (env.DOMAIN_RPC_URL ?? (env.RPC_URL ? `${rpc}/domain` : `${operator}/rpc/domain`)).replace(/\/$/, "");
  return { rpc, domainRpc, operator };
}
