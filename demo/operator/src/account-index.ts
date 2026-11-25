import { parseEventLogs, zeroAddress, type Address, type PublicClient } from "viem";
import { DEMO_DOMAIN_BRIDGE_ABI, ERC20_ABI, L2_BANK_ABI } from "./abi.js";
import type { DemoDomain } from "./config.js";

/**
 * Every account on the two banks' books, so the page can list them without scanning a
 * domain's logs itself: the domain's RPC serves a contract's logs to operators only.
 *
 * Per bank it collects the KYC'd customers (the bank's `ReceiveAllowanceSet` / `KycTierSet`
 * events) and the ledger holders (the wrapped ledger token's `Transfer` events), scanning from
 * the domain's start block and then only new blocks. It also remembers each account's latest
 * activity at the bank - those events, plus the payment orders a customer files and the KYC
 * inquiries about a recipient - and lists accounts most recently active first. The page reads
 * balances, tiers and limits itself; this index only knows addresses.
 */
export interface BankAccounts {
  customers: Address[];
  /** Every account on the bank's ledger: whoever ever held its token, and every KYC'd
   *  customer (a customer who never deposited has an account at 0). */
  holders: Address[];
}

export interface AccountIndexStatus {
  /** Next block to scan per bank and contract; equal to the head once caught up. */
  progress: Record<"A" | "B", { customers: string; holders: string | null; head: string | null }>;
  lastError: string | null;
}

const LOG_WINDOW = 1000n;
/** Log windows read per contract per pass, so a long catch-up still reports progress. */
const WINDOWS_PER_PASS = 200;

type Logs = Awaited<ReturnType<PublicClient["getLogs"]>>;

interface Scanner {
  contract: Address;
  next: bigint;
  seen: Set<Address>;
  /** Adds what the logs reveal: new accounts to `seen`, latest activity to the bank's map. */
  read: (logs: Logs) => void;
}

interface BankState {
  domain: DemoDomain;
  client: PublicClient;
  customers: Scanner;
  holders: Scanner | null;
  head: bigint | null;
  /** Position (block, log index) of each account's latest activity at this bank. */
  activity: Map<Address, bigint>;
}

/** A log's position on the domain, comparable across blocks. */
const position = (log: { blockNumber: bigint | null; logIndex: number | null }) =>
  (log.blockNumber ?? 0n) * 1_000_000n + BigInt(log.logIndex ?? 0);

export class AccountIndex {
  private readonly banks: Record<"A" | "B", BankState>;
  private lastError: string | null = null;

  constructor(
    domains: Record<"A" | "B", { domain: DemoDomain; client: PublicClient }>,
    private readonly log: (line: string) => void,
  ) {
    const bank = (zone: "A" | "B"): BankState => {
      const { domain, client } = domains[zone];
      const state: BankState = { domain, client, head: null, holders: null, activity: new Map(), customers: null! };
      const seen = new Set<Address>();
      state.customers = {
        contract: domain.bank,
        next: BigInt(domain.startBlock),
        seen,
        read: (logs) => {
          for (const ev of parseEventLogs({ abi: L2_BANK_ABI, logs })) {
            if (ev.eventName === "ReceiveAllowanceSet" || ev.eventName === "KycTierSet") {
              seen.add(ev.args.user);
              this.touch(state, ev.args.user, ev);
            } else if (ev.eventName === "TransferRequested") {
              this.touch(state, ev.args.user, ev); // a payer files an order
            } else if (ev.eventName === "InquiryAnswered") {
              this.touch(state, ev.args.recipient, ev); // a recipient is asked about
            }
          }
        },
      };
      return state;
    };
    this.banks = { A: bank("A"), B: bank("B") };
  }

  /** One pass: finds each bank's ledger token once it exists, then scans new log windows. */
  async tick(): Promise<void> {
    try {
      for (const zone of ["A", "B"] as const) {
        const b = this.banks[zone];
        if (!b.holders) {
          const ledger = await b.client.readContract({
            address: b.domain.domainBridge,
            abi: DEMO_DOMAIN_BRIDGE_ABI,
            functionName: "bridgedTokens",
            args: [b.domain.token],
          });
          if (ledger !== zeroAddress) {
            const seen = new Set<Address>();
            b.holders = {
              contract: ledger,
              next: BigInt(b.domain.startBlock),
              seen,
              read: (logs) => {
                for (const ev of parseEventLogs({ abi: ERC20_ABI, eventName: "Transfer", logs })) {
                  for (const a of [ev.args.from, ev.args.to]) {
                    if (a === zeroAddress || a.toLowerCase() === b.domain.bank.toLowerCase()) continue;
                    seen.add(a);
                    this.touch(b, a, ev);
                  }
                }
              },
            };
          }
        }
        b.head = await b.client.getBlockNumber({ cacheTime: 0 });
        await this.scan(b.client, b.customers, b.head);
        if (b.holders) await this.scan(b.client, b.holders, b.head);
      }
      this.lastError = null;
    } catch (error) {
      this.lastError = error instanceof Error ? error.message : String(error);
      this.log(`accounts: pass failed: ${this.lastError}`);
    }
  }

  private async scan(client: PublicClient, s: Scanner, head: bigint): Promise<void> {
    for (let i = 0; i < WINDOWS_PER_PASS && s.next <= head; i++) {
      const to = s.next + LOG_WINDOW - 1n < head ? s.next + LOG_WINDOW - 1n : head;
      s.read(await client.getLogs({ address: s.contract, fromBlock: s.next, toBlock: to }));
      s.next = to + 1n;
    }
  }

  private touch(b: BankState, account: Address, log: { blockNumber: bigint | null; logIndex: number | null }): void {
    const at = position(log);
    if ((b.activity.get(account) ?? -1n) < at) b.activity.set(account, at);
  }

  /** Each bank's customers and ledger holders, most recently active first. */
  accounts(): Record<"A" | "B", BankAccounts> {
    const of = (b: BankState): BankAccounts => {
      const recent = (set: Set<Address>) =>
        [...set].sort((x, y) => {
          const ax = b.activity.get(x) ?? 0n;
          const ay = b.activity.get(y) ?? 0n;
          return ay > ax ? 1 : ay < ax ? -1 : 0;
        });
      return {
        customers: recent(b.customers.seen),
        holders: recent(new Set([...(b.holders?.seen ?? []), ...b.customers.seen])),
      };
    };
    return { A: of(this.banks.A), B: of(this.banks.B) };
  }

  status(): AccountIndexStatus {
    const of = (b: BankState) => ({
      customers: b.customers.next.toString(),
      holders: b.holders?.next.toString() ?? null,
      head: b.head?.toString() ?? null,
    });
    return { progress: { A: of(this.banks.A), B: of(this.banks.B) }, lastError: this.lastError };
  }
}
