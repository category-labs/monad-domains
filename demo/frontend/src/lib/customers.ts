import { getAddress, zeroAddress, type Address } from "viem";
import { OPERATOR_URL, domainA, domainB, scriptHeaders } from "./chain";
import { DEMO_DOMAIN_BRIDGE_ABI, ERC20_ABI, L2_BANK_ABI } from "./demo-abi";
import { deployment } from "./deployment";

/** Every account a bank's books know: ledger holders and KYC'd customers. */
export interface BankBook {
  /** Every account on the bank's wrapped ledger (also at 0.00), bank custody excluded, most recently active first. */
  holders: { address: Address; balance: bigint }[];
  /** Accounts in the bank's KYC registry, with their tier and what is left of their daily limit,
   *  most recently active first. */
  customers: { address: Address; tier: number; limit: bigint }[];
}

type Accounts = Record<"A" | "B", { customers: Address[]; holders: Address[] }>;

/**
 * The addresses on both banks' books, most recently active first, from the operator's account
 * index (`GET /api/accounts`).
 * Scanning a domain's logs from its start block takes thousands of log windows - the operator
 * does that once; the page only asks for the result.
 */
export async function fetchAccounts(): Promise<Accounts> {
  const response = await fetch(`${OPERATOR_URL}/api/accounts`, { headers: scriptHeaders() });
  if (!response.ok) throw new Error(`accounts: ${response.status}`);
  return (await response.json()) as Accounts;
}

/**
 * Reads one bank's books for the given addresses: balances on the wrapped ledger (`known`,
 * else looked up; zero before the first deposit created it), and each customer's tier and
 * remaining limit.
 */
export async function fetchBankBook(zone: "A" | "B", known: Address, addresses: Accounts["A"]): Promise<BankBook> {
  const client = zone === "A" ? domainA : domainB;
  const d = deployment.domains[zone];
  const bank = d.bank;
  const ledger =
    known !== zeroAddress
      ? known
      : await client.readContract({ address: d.domainBridge, abi: DEMO_DOMAIN_BRIDGE_ABI, functionName: "bridgedTokens", args: [d.token] });
  const holders = ledger === zeroAddress ? [] : addresses.holders.map((a) => getAddress(a));
  const [balances, customers] = await Promise.all([
    Promise.all(holders.map((a) => client.readContract({ address: ledger, abi: ERC20_ABI, functionName: "balanceOf", args: [a] }))),
    Promise.all(
      addresses.customers.map(async (raw) => {
        const address = getAddress(raw);
        const [tier, limit] = await Promise.all([
          // Contracts from before the KYC tiers have no kycTier: shown without a tier.
          client.readContract({ address: bank, abi: L2_BANK_ABI, functionName: "kycTier", args: [address] }).catch(() => 0),
          client.readContract({ address: bank, abi: L2_BANK_ABI, functionName: "receiveAllowance", args: [address] }),
        ]);
        return { address, tier, limit };
      }),
    ),
  ]);
  return {
    // In the index's order: most recently active first.
    // Every account, also at 0.00: a customer who spent everything (or never deposited) still has one.
    holders: holders.map((address, i) => ({ address, balance: balances[i] ?? 0n })),
    customers,
  };
}
