import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  encodeFunctionData,
  http,
  keccak256,
  nonceManager,
  parseEventLogs,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { L2_BANK_ABI, POOL_ABI, REQUEST_STATUS } from "./abi.js";
import { sequenceAndWait } from "./domain-tx.js";

/**
 * The payer bank's back office. Bank A's customers file payment orders on domain A; once
 * the KYC round trip approves an order, somebody holding the bank operator key has to
 * reserve liquidity at the L1 pool and execute the payment on the domain. This agent polls
 * the bank's requests and does exactly that, idempotently: the pool records one lock per
 * request key, so a restart between the lock and the payment resumes with the same lock.
 */
export interface BankAgentConfig {
  l1RpcUrl: string;
  hub: Address;
  domainChainId: bigint;
  domainRpcUrl: string;
  /** Domain viewing public key; encrypts the sequenced payment transaction when set. */
  viewingKey?: Hex;
  /** The bank operator key: `BANK` on the L2Bank and `locker` on the pool. */
  bankKey: Hex;
  bank: Address;
  pool: Address;
  /** Lifetime of a live lock. Default 600 s. */
  lockTtlSeconds?: number;
  /** `msg.value` forwarded to the operator with sequenced transactions. Default 0. */
  sequencingFee?: bigint;
  log?: (line: string) => void;
}

export interface BankAgentStatus {
  bank: Address;
  nextRequestId: bigint | null;
  /** Lowest request id not yet in a final state. */
  cursor: bigint;
  executed: number;
  lastError: string | null;
}

const EXECUTE_GAS = 600_000n;

export class BankAgent {
  private readonly config: BankAgentConfig;
  private readonly log: (line: string) => void;
  private readonly operator;
  private readonly domain: PublicClient;
  private l1!: PublicClient;
  private wallet!: WalletClient;
  private l1Chain!: Chain;
  private cursor = 0n;
  private nextRequestId: bigint | null = null;
  private executed = 0;
  private lastError: string | null = null;

  constructor(config: BankAgentConfig) {
    this.config = config;
    this.log = config.log ?? ((line) => console.log(line));
    this.operator = privateKeyToAccount(config.bankKey, { nonceManager });
    const chain = defineChain({
      id: Number(config.domainChainId),
      name: `domain-${config.domainChainId}`,
      nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
      rpcUrls: { default: { http: [config.domainRpcUrl] } },
    });
    this.domain = createPublicClient({ chain, transport: http(config.domainRpcUrl) });
  }

  get address(): Address {
    return this.operator.address;
  }

  status(): BankAgentStatus {
    return {
      bank: this.config.bank,
      nextRequestId: this.nextRequestId,
      cursor: this.cursor,
      executed: this.executed,
      lastError: this.lastError,
    };
  }

  private async connect(): Promise<void> {
    if (this.l1) return;
    const probe = createPublicClient({ transport: http(this.config.l1RpcUrl) });
    const l1ChainId = await probe.getChainId();
    this.l1Chain = defineChain({
      id: l1ChainId,
      name: `l1-${l1ChainId}`,
      nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
      rpcUrls: { default: { http: [this.config.l1RpcUrl] } },
    });
    this.l1 = createPublicClient({ chain: this.l1Chain, transport: http(this.config.l1RpcUrl) });
    this.wallet = createWalletClient({ account: this.operator, chain: this.l1Chain, transport: http(this.config.l1RpcUrl) });
    const bank = await this.domain.readContract({ address: this.config.bank, abi: L2_BANK_ABI, functionName: "BANK" });
    if (bank.toLowerCase() !== this.operator.address.toLowerCase()) {
      throw new Error(`bank agent: ${this.config.bank} is operated by ${bank}, not ${this.operator.address}`);
    }
    this.log(`bank agent: operating ${this.config.bank} on domain ${this.config.domainChainId} as ${this.operator.address}`);
  }

  /** One pass: executes every approved payment order. Failures are retried next pass. */
  async tick(): Promise<void> {
    try {
      await this.connect();
      const next = await this.domain.readContract({ address: this.config.bank, abi: L2_BANK_ABI, functionName: "nextRequestId" });
      this.nextRequestId = next;
      let cursorSettled = true;
      for (let id = this.cursor; id < next; id++) {
        const [user, recipient, amountOut, amountIn, expireLock, status] = await this.domain.readContract({
          address: this.config.bank,
          abi: L2_BANK_ABI,
          functionName: "requests",
          args: [id],
        });
        const state = REQUEST_STATUS[status] ?? "none";
        if (state === "approved") {
          await this.execute(id, { user, recipient, amountOut, amountIn, expireLock });
          if (cursorSettled) this.cursor = id + 1n;
          continue;
        }
        const final = state === "denied" || state === "paid";
        if (final && cursorSettled) this.cursor = id + 1n;
        if (!final) cursorSettled = false;
      }
      this.lastError = null;
    } catch (error) {
      this.lastError = error instanceof Error ? error.message : String(error);
      this.log(`bank agent: pass failed: ${this.lastError}`);
    }
  }

  /** The key the pool records a request's lock under. */
  static requestKey(bank: Address, requestId: bigint): Hex {
    return keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [bank, requestId]));
  }

  private async execute(
    requestId: bigint,
    request: { user: Address; recipient: Address; amountOut: bigint; amountIn: bigint; expireLock: boolean },
  ): Promise<void> {
    const requestKey = BankAgent.requestKey(this.config.bank, requestId);
    let lockId = await this.l1.readContract({ address: this.config.pool, abi: POOL_ABI, functionName: "lockIdByRequest", args: [requestKey] });
    if (lockId === 0n) {
      const ttl = request.expireLock ? 0 : (this.config.lockTtlSeconds ?? 600);
      const txHash = await this.wallet.writeContract({
        account: this.operator,
        chain: this.l1Chain,
        address: this.config.pool,
        abi: POOL_ABI,
        functionName: "lockLiquidity",
        args: [request.amountOut, request.recipient, request.user, BigInt(ttl), requestKey],
      });
      const receipt = await this.l1.waitForTransactionReceipt({ hash: txHash });
      if (receipt.status !== "success") throw new Error(`lockLiquidity for request ${requestId} reverted (${txHash})`);
      const [locked] = parseEventLogs({ abi: POOL_ABI, eventName: "LiquidityLocked", logs: receipt.logs });
      if (!locked) throw new Error(`lockLiquidity for request ${requestId} emitted no LiquidityLocked (${txHash})`);
      lockId = locked.args.lockId + 1n;
      this.log(
        `bank agent: request ${requestId} locked ${request.amountOut} out for ${request.recipient} as lock #${locked.args.lockId}` +
          ` (quote ${locked.args.amountIn}${request.expireLock ? ", born expired" : ""}, L1 tx ${txHash})`,
      );
    } else {
      this.log(`bank agent: request ${requestId} already holds lock #${lockId - 1n}, executing the payment`);
    }
    const { sequenced, receipt } = await sequenceAndWait(
      this.domain,
      {
        l1RpcUrl: this.config.l1RpcUrl,
        hub: this.config.hub,
        domainChainId: this.config.domainChainId,
        senderKey: this.config.bankKey,
        to: this.config.bank,
        data: encodeFunctionData({ abi: L2_BANK_ABI, functionName: "executePayment", args: [requestId, lockId - 1n] }),
        gas: EXECUTE_GAS,
        domainRpcUrl: this.config.domainRpcUrl,
        sequencingFee: this.config.sequencingFee,
        viewingKey: this.config.viewingKey,
        nonceManager,
      },
      { label: `executePayment(${requestId})` },
    );
    this.executed++;
    this.log(
      `bank agent: request ${requestId} paid ${request.amountIn} to the pool with memo #${lockId - 1n} ` +
        `at domain block ${receipt.blockNumber} (domain tx ${sequenced.domainTxHash}, L1 tx ${sequenced.l1TxHash})`,
    );
  }
}
