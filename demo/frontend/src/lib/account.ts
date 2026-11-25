import {
  createWalletClient,
  custom,
  numberToHex,
  type Address,
  type EIP1193Provider,
  type Hex,
  type WalletClient,
} from "viem";
import { generatePrivateKey, privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { RPC_URL, l1Chain, transport } from "./chain";

/**
 * Who the visitor is. Two roles, because a browser wallet can only sign transactions for
 * the chain it is connected to, while a domain transaction is signed for the domain's own
 * chain id and only *carried* by an L1 transaction:
 *
 *   - the L1 signer pays for and signs L1 transactions (deposits, `sequenceToDomain`) and
 *     holds the L1 funds - either a key generated in this browser or an injected wallet;
 *   - the domain account signs the domain transactions - always a key kept in this browser
 *     (the "session key"); with a browser account it is the same key.
 */
export type L1Signer =
  | { kind: "browser"; address: Address; account: PrivateKeyAccount; wallet: WalletClient }
  | { kind: "injected"; address: Address; wallet: WalletClient; provider: EIP1193Provider };

export interface Identity {
  l1: L1Signer;
  domain: PrivateKeyAccount;
}

const STORAGE_KEY = "psd.demo.sessionKey";

function storage(): Storage | null {
  try {
    return typeof localStorage === "undefined" ? null : localStorage;
  } catch {
    return null;
  }
}

/** The key kept in this browser (created on first use). Scripts pass `SESSION_KEY`. */
export function loadOrCreateSessionKey(): Hex {
  const fromEnv = typeof process !== "undefined" ? (process.env?.SESSION_KEY as Hex | undefined) : undefined;
  if (fromEnv) return fromEnv;
  const store = storage();
  const existing = store?.getItem(STORAGE_KEY) as Hex | null;
  if (existing && /^0x[0-9a-fA-F]{64}$/.test(existing)) return existing;
  const fresh = generatePrivateKey();
  store?.setItem(STORAGE_KEY, fresh);
  return fresh;
}

/** Replaces the browser key with a new one (the demo's "start over"). */
export function resetSessionKey(): Hex {
  const fresh = generatePrivateKey();
  storage()?.setItem(STORAGE_KEY, fresh);
  return fresh;
}

export function exportSessionKey(): Hex | null {
  return (storage()?.getItem(STORAGE_KEY) as Hex | null) ?? null;
}

/** An identity that signs everything with one browser-held key. */
export function browserIdentity(key: Hex = loadOrCreateSessionKey()): Identity {
  const account = privateKeyToAccount(key);
  const wallet = createWalletClient({ account, chain: l1Chain, transport: transport(RPC_URL) });
  return { l1: { kind: "browser", address: account.address, account, wallet }, domain: account };
}

export function hasInjectedWallet(): boolean {
  return typeof window !== "undefined" && !!(window as unknown as { ethereum?: unknown }).ethereum;
}

/**
 * Connects the injected wallet (MetaMask or compatible) for the L1 role and keeps the
 * browser key as the domain account. Asks the wallet to switch to (or add) the L1.
 */
export async function connectInjectedWallet(sessionKey: Hex = loadOrCreateSessionKey()): Promise<Identity> {
  const provider = (window as unknown as { ethereum?: EIP1193Provider }).ethereum;
  if (!provider) throw new Error("no injected wallet found");
  const [address] = (await provider.request({ method: "eth_requestAccounts" })) as Address[];
  if (!address) throw new Error("the wallet returned no account");
  await ensureL1Chain(provider);
  const wallet = createWalletClient({ account: address, chain: l1Chain, transport: custom(provider) });
  return { l1: { kind: "injected", address, wallet, provider }, domain: privateKeyToAccount(sessionKey) };
}

async function ensureL1Chain(provider: EIP1193Provider): Promise<void> {
  const chainId = numberToHex(l1Chain.id);
  const current = (await provider.request({ method: "eth_chainId" })) as Hex;
  if (BigInt(current) === BigInt(chainId)) return;
  try {
    await provider.request({ method: "wallet_switchEthereumChain", params: [{ chainId }] });
  } catch (error) {
    const code = (error as { code?: number }).code;
    if (code !== 4902) throw error;
    await provider.request({
      method: "wallet_addEthereumChain",
      params: [
        {
          chainId,
          chainName: l1Chain.name,
          nativeCurrency: l1Chain.nativeCurrency,
          rpcUrls: l1Chain.rpcUrls.default.http,
          blockExplorerUrls: l1Chain.blockExplorers ? [l1Chain.blockExplorers.default.url] : undefined,
        },
      ],
    });
  }
}

export function short(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}
