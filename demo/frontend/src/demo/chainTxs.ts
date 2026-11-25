import { decodeFunctionData, formatEther, type Address, type Hex } from "viem";
import { l1 } from "../lib/chain";
import { DEMO_L1_BRIDGE_ABI, ERC20_ABI, HUB_ABI, POOL_ABI } from "../lib/demo-abi";
import { CHAIN_A, CHAIN_B, deployment } from "../lib/deployment";

/** One transaction on the Monad public network, as anyone reading the chain sees it. */
export interface ChainTx {
  hash: Hex;
  block: bigint;
  /** Unix seconds. */
  time: number;
  from: Address;
  to: Address | null;
  input: Hex;
  /** What the call does, in plain words, from its public calldata. */
  action: string;
  /** Extra public detail (amounts, ciphertext size). */
  detail?: string;
  /** The content is encrypted: the public sees only that something went to a domain. */
  encrypted: boolean;
}

const d = deployment;
const lower = (a: string) => a.toLowerCase();

/** The demo's contracts on Monad: every demo action emits an event on one of them. */
export const WATCHED: Address[] = [d.hub, d.tokens.eur, d.tokens.usd, d.pool, d.domains.A.l1Bridge, d.domains.B.l1Bridge];

const CONTRACT_NAMES: Record<string, string> = {
  [lower(d.hub)]: "Hub",
  [lower(d.tokens.eur)]: "€ token",
  [lower(d.tokens.usd)]: "$ token",
  [lower(d.pool)]: "Liquidity pool",
  [lower(d.domains.A.l1Bridge)]: "Bridge A",
  [lower(d.domains.B.l1Bridge)]: "Bridge B",
  [lower(d.bankOperator)]: "Bank operator",
};

const ABIS = [HUB_ABI, ERC20_ABI, DEMO_L1_BRIDGE_ABI, POOL_ABI] as const;

function decode(input: Hex) {
  for (const abi of ABIS) {
    try {
      return decodeFunctionData({ abi, data: input }) as { functionName: string; args?: readonly unknown[] };
    } catch {
      // not this contract's function
    }
  }
  return null;
}

const amount = (wei: bigint) => {
  const [whole, frac = ""] = formatEther(wei).split(".");
  return `${Number(whole).toLocaleString("en-US")}${frac ? `.${frac.slice(0, 2).padEnd(2, "0")}` : ".00"}`;
};

const domainName = (chainId: bigint) => (chainId === CHAIN_A ? "domain A (Bank A)" : chainId === CHAIN_B ? "domain B (Bank B)" : `domain ${chainId}`);

/** Describes a transaction from its public calldata; `name` labels known addresses. */
export function describe(tx: { to: Address | null; input: Hex; value: bigint }, name: (a: Address) => string): Pick<ChainTx, "action" | "detail" | "encrypted"> {
  const call = tx.input && tx.input !== "0x" ? decode(tx.input) : null;
  const token = tx.to && lower(tx.to) === lower(d.tokens.usd) ? "$" : "€";
  const args = (call?.args ?? []) as readonly unknown[];
  switch (call?.functionName) {
    case "sequenceToDomain": {
      const [chainId, rlpTx] = args as [bigint, Hex];
      return {
        action: `Encrypted transaction for ${domainName(chainId)}`,
        detail: `${(rlpTx.length - 2) / 2} bytes of ciphertext · ${rlpTx.slice(0, 18)}…`,
        encrypted: true,
      };
    }
    case "transfer": {
      const [to, value] = args as [Address, bigint];
      return { action: `Transfer ${amount(value)} ${token} to ${name(to)}`, encrypted: false };
    }
    case "approve": {
      const [spender, value] = args as [Address, bigint];
      return { action: `Approve ${name(spender)} to take ${amount(value)} ${token}`, encrypted: false };
    }
    case "mint": {
      const [to, value] = args as [Address, bigint];
      return { action: `Faucet mints ${amount(value)} ${token} to ${name(to)}`, encrypted: false };
    }
    case "bridgeToDomain": {
      const [recipient, depositToken, value] = args as [Address, Address, bigint];
      const bank = tx.to && lower(tx.to) === lower(d.domains.B.l1Bridge) ? "Bank B" : "Bank A";
      const unit = lower(depositToken) === lower(d.tokens.usd) ? "$" : "€";
      return { action: `Deposit ${amount(value)} ${unit} into ${bank}`, detail: `for domain account ${name(recipient)}`, encrypted: false };
    }
    case "swap": {
      const [amountOut, recipient] = args as [bigint, Address];
      return { action: `Swap at the liquidity pool: ${amount(amountOut)} $ to ${name(recipient)}`, encrypted: false };
    }
    case "cancelExpiredLock":
      return { action: `Cancel expired liquidity lock #${args[0] as bigint}`, encrypted: false };
    case undefined:
      if (tx.value > 0n) return { action: `Send ${amount(tx.value)} MON to ${tx.to ? name(tx.to) : "?"}`, encrypted: false };
      return { action: tx.input === "0x" ? "Empty transaction" : `Call ${tx.input.slice(0, 10)} on ${tx.to ? name(tx.to) : "?"}`, encrypted: false };
    default:
      // the operator's relaying: state roots, message proofs - routine protocol traffic
      return { action: `${call?.functionName} on ${tx.to ? name(tx.to) : "?"}`, encrypted: false };
  }
}

export function contractName(address: Address): string | null {
  return CONTRACT_NAMES[lower(address)] ?? null;
}

/** Monad's RPC caps eth_getLogs ranges; stay under it. */
const LOG_RANGE = 100n;

/** Hashes of transactions that touched the demo's contracts in [from, to]. */
async function demoTxHashes(from: bigint, to: bigint): Promise<{ hash: Hex; block: bigint }[]> {
  const ranges: [bigint, bigint][] = [];
  for (let start = from; start <= to; start += LOG_RANGE) ranges.push([start, start + LOG_RANGE - 1n < to ? start + LOG_RANGE - 1n : to]);
  const logs = (await Promise.all(ranges.map(([fromBlock, toBlock]) => l1.getLogs({ address: WATCHED, fromBlock, toBlock })))).flat();
  const seen = new Map<Hex, bigint>();
  for (const log of logs) if (log.transactionHash && log.blockNumber != null) seen.set(log.transactionHash, log.blockNumber);
  return [...seen].map(([hash, block]) => ({ hash, block }));
}

/**
 * Loads the demo's transactions in [from, to]: finds them by their events, then reads each
 * transaction (sender, calldata) and its block's time.
 */
export async function loadChainTxs(from: bigint, to: bigint, name: (a: Address) => string, limit = 150): Promise<ChainTx[]> {
  if (to < from) return [];
  // The newest first, at most `limit`: each one is a read of its own.
  const found = (await demoTxHashes(from, to)).sort((x, y) => (x.block > y.block ? -1 : x.block < y.block ? 1 : 0)).slice(0, limit);
  const blocks = [...new Set(found.map((f) => f.block))];
  const [txs, times] = await Promise.all([
    Promise.all(found.map((f) => l1.getTransaction({ hash: f.hash }))),
    Promise.all(blocks.map((n) => l1.getBlock({ blockNumber: n }).then((b) => [n, Number(b.timestamp)] as const))),
  ]);
  const timeOf = new Map(times);
  return txs.map((tx) => ({
    hash: tx.hash,
    block: tx.blockNumber ?? 0n,
    time: timeOf.get(tx.blockNumber ?? 0n) ?? 0,
    from: tx.from,
    to: tx.to ?? null,
    input: tx.input,
    ...describe({ to: tx.to ?? null, input: tx.input, value: tx.value }, name),
  }));
}
