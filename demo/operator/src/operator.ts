import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeFunctionData,
  getAddress,
  http,
  isAddress,
  nonceManager,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { BankAgent, type BankAgentStatus } from "./bank-agent.js";
import { ERC20_ABI, L2_BANK_ABI } from "./abi.js";
import { domainRpcUrl, type DemoDeployment, type DemoDomain } from "./config.js";
import { sequenceAndWait } from "./domain-tx.js";
import { DomainRelayer, type DomainRelayerStatus } from "@domain-bridging/prover";

/**
 * Everything the demo's operators run, in one process:
 *
 *   - the relayer for both domains (finalize, attest, relay);
 *   - Bank A's back office (lock pool liquidity, execute approved payments);
 *   - the onboarding faucet: drips gas, mints demo EUR on the L1 and registers the visitor
 *     in both banks' know-your-depositor registries, so any address can run the flow;
 *   - a small HTTP API the frontend talks to (`/api/config`, `/api/status`, `/api/onboard`),
 *     plus an RPC gateway (`/rpc`, `/rpc/domain/<id>`) forwarding JSON-RPC to the node, so the
 *     page needs nothing but this service and the node's URL never leaves the operators' side.
 *
 * The relayer, the bank agent and the registry transactions all sequence domain
 * transactions from the operator keys, so they run one after the other in a single loop:
 * HTTP handlers only enqueue the domain-side work and the loop drains it between passes.
 * L1 transactions from one key are ordered by viem's in-process nonce manager.
 */
export interface OperatorConfig {
  l1RpcUrl: string;
  deployment: DemoDeployment;
  /** Spoke operator (sequences finalize) for both domains; default for every other role. */
  operatorKey: Hex;
  /** Registered validators whose signatures advance the hub. Default `[operatorKey]`. */
  validatorKeys?: Hex[];
  /** Pays for submitStateSignature / relayDomainMessage. Default `operatorKey`. */
  submitterKey?: Hex;
  /** `BANK` on both L2Banks and `locker` on the pool. Default `operatorKey`. */
  bankKey?: Hex;
  /** Funds the faucet drips and mints demo EUR. Default `operatorKey`. */
  faucetKey?: Hex;
  /** Overrides for the domain RPC routes (default `${l1RpcUrl}/domain/<id>`). */
  domainRpcUrls?: { A?: string; B?: string };
  faucet?: Partial<FaucetConfig>;
  /** HTTP port. Default 8787. */
  port?: number;
  /** `Access-Control-Allow-Origin` for the API. Default `*`. */
  corsOrigin?: string;
  /**
   * Serve `/rpc` and `/rpc/domain/<id>` as a gateway to the node, so the frontend only has
   * to reach this service and the node's URL (with its access token) stays here. Default true.
   */
  rpcGateway?: boolean;
  /** Delay between passes of the loop (relayer, bank agent, queued jobs). Default 500 ms. */
  pollIntervalMs?: number;
  attestIntervalMs?: number;
  /** In-pass wait for a finalize block to be finalized before attesting. Default 5000 ms. */
  finalityWaitMs?: number;
  lockTtlSeconds?: number;
  sequencingFee?: bigint;
  log?: (line: string) => void;
}

export interface FaucetConfig {
  /** Native drip per onboarding (wei). */
  dripWei: bigint;
  /** Native balance below which an address gets a drip (wei). */
  dripBelowWei: bigint;
  /** Demo EUR minted per onboarding (wei). */
  mintEur: bigint;
  /** Receive limit registered at Bank B (USD) and Bank A (EUR). */
  receiveLimit: bigint;
  /** Minimum time between two onboardings of the same address. */
  cooldownMs: number;
  /** Onboardings allowed per client IP per `cooldownMs`. */
  perIpLimit: number;
}

const DEFAULT_FAUCET: FaucetConfig = {
  dripWei: 500_000_000_000_000_000n, // 0.5 MON
  dripBelowWei: 300_000_000_000_000_000n,
  mintEur: 1_000n * 10n ** 18n,
  receiveLimit: 100_000n * 10n ** 18n,
  cooldownMs: 10 * 60_000,
  perIpLimit: 10,
};

interface Job {
  id: string;
  label: string;
  run: () => Promise<void>;
  status: "queued" | "running" | "done" | "failed";
  error?: string;
  createdAt: number;
}

export interface OnboardResult {
  address: Address;
  domainAddress: Address;
  drip: Hex | null;
  mint: Hex;
  registration: { id: string; status: Job["status"] };
}

export class OperatorService {
  private readonly config: OperatorConfig;
  private readonly faucet: FaucetConfig;
  private readonly log: (line: string) => void;
  private readonly relayer: DomainRelayer;
  private readonly bankAgent: BankAgent;
  private readonly bankKey: Hex;
  private readonly faucetAccount;
  private readonly domainA: PublicClient;
  private readonly domainB: PublicClient;
  private l1!: PublicClient;
  private faucetWallet!: WalletClient;
  private l1Chain!: Chain;
  private readonly jobs: Job[] = [];
  private readonly recentJobs = new Map<string, Job>();
  private readonly lastOnboarding = new Map<string, number>();
  private readonly ipWindows = new Map<string, number[]>();
  private running = false;
  private stopped: Promise<void> = Promise.resolve();
  private server: ReturnType<typeof createServer> | null = null;
  private startedAt = Date.now();

  constructor(config: OperatorConfig) {
    this.config = config;
    this.faucet = { ...DEFAULT_FAUCET, ...config.faucet };
    this.log = config.log ?? ((line) => console.log(line));
    const d = config.deployment;
    const validatorKeys = config.validatorKeys?.length ? config.validatorKeys : [config.operatorKey];
    this.bankKey = config.bankKey ?? config.operatorKey;
    this.faucetAccount = privateKeyToAccount(config.faucetKey ?? config.operatorKey, { nonceManager });
    const rpcA = domainRpcUrl(config.l1RpcUrl, d.domains.A.chainId, config.domainRpcUrls?.A);
    const rpcB = domainRpcUrl(config.l1RpcUrl, d.domains.B.chainId, config.domainRpcUrls?.B);
    this.domainA = this.domainClient(d.domains.A, rpcA);
    this.domainB = this.domainClient(d.domains.B, rpcB);

    this.relayer = new DomainRelayer({
      l1RpcUrl: config.l1RpcUrl,
      hub: d.hub,
      submitterKey: config.submitterKey ?? config.operatorKey,
      domains: [
        { ...this.relayerDomain(d.domains.A, rpcA, config.operatorKey, validatorKeys) },
        { ...this.relayerDomain(d.domains.B, rpcB, config.operatorKey, validatorKeys) },
      ],
      pollIntervalMs: config.pollIntervalMs,
      attestIntervalMs: config.attestIntervalMs,
      finalityWaitMs: config.finalityWaitMs,
      sequencingFee: config.sequencingFee,
      // One nonce manager for every L1 send from the operator keys, across both packages.
      nonceManager,
      log: this.log,
    });
    this.bankAgent = new BankAgent({
      l1RpcUrl: config.l1RpcUrl,
      hub: d.hub,
      domainChainId: BigInt(d.domains.A.chainId),
      domainRpcUrl: rpcA,
      viewingKey: d.domains.A.viewingKey,
      bankKey: this.bankKey,
      bank: d.domains.A.bank,
      pool: d.pool,
      lockTtlSeconds: config.lockTtlSeconds,
      sequencingFee: config.sequencingFee,
      log: this.log,
    });
  }

  private domainClient(domain: DemoDomain, rpc: string): PublicClient {
    const chain = defineChain({
      id: domain.chainId,
      name: `domain-${domain.chainId}`,
      nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
      rpcUrls: { default: { http: [rpc] } },
    });
    return createPublicClient({ chain, transport: http(rpc) });
  }

  private relayerDomain(domain: DemoDomain, rpc: string, operatorKey: Hex, validatorKeys: Hex[]) {
    return {
      chainId: BigInt(domain.chainId),
      spoke: domain.spoke,
      domainRpcUrl: rpc,
      operatorKey,
      validatorKeys,
      viewingKey: domain.viewingKey,
      startBlock: BigInt(domain.startBlock),
    };
  }

  // ---------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------

  async start(): Promise<void> {
    if (this.running) throw new Error("operator: already running");
    this.running = true;
    this.startedAt = Date.now();
    await this.connect();
    this.server = createServer((req, res) => void this.handle(req, res));
    const port = this.config.port ?? 8787;
    // No host: Node binds dual-stack (`::`), reachable over IPv4 and IPv6 (Railway private networking).
    await new Promise<void>((resolve) => this.server!.listen(port, resolve));
    this.log(`operator: API listening on :${port}`);
    this.stopped = this.loop();
    return this.stopped;
  }

  async stop(): Promise<void> {
    this.running = false;
    await this.stopped;
    await new Promise<void>((resolve) => (this.server ? this.server.close(() => resolve()) : resolve()));
  }

  private async connect(): Promise<void> {
    if (this.l1) return;
    const probe = createPublicClient({ transport: http(this.config.l1RpcUrl) });
    const l1ChainId = await probe.getChainId();
    if (l1ChainId !== this.config.deployment.l1ChainId) {
      throw new Error(`operator: RPC serves chain ${l1ChainId}, deployment is for ${this.config.deployment.l1ChainId}`);
    }
    this.l1Chain = defineChain({
      id: l1ChainId,
      name: `l1-${l1ChainId}`,
      nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
      rpcUrls: { default: { http: [this.config.l1RpcUrl] } },
    });
    this.l1 = createPublicClient({ chain: this.l1Chain, transport: http(this.config.l1RpcUrl) });
    this.faucetWallet = createWalletClient({ account: this.faucetAccount, chain: this.l1Chain, transport: http(this.config.l1RpcUrl) });
    this.log(`operator: faucet ${this.faucetAccount.address}, bank operator ${this.bankAgent.address}`);
  }

  private async loop(): Promise<void> {
    const interval = this.config.pollIntervalMs ?? 500;
    while (this.running) {
      await this.relayer.tick();
      await this.bankAgent.tick();
      await this.drainJobs();
      const deadline = Date.now() + interval;
      while (this.running && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, Math.min(250, Math.max(0, deadline - Date.now()))));
      }
    }
  }

  /** Runs one pass of everything; exposed for tests and scripts. */
  async tick(): Promise<void> {
    await this.connect();
    await this.relayer.tick();
    await this.bankAgent.tick();
    await this.drainJobs();
  }

  private async drainJobs(): Promise<void> {
    while (this.jobs.length > 0 && this.running) {
      const job = this.jobs.shift()!;
      job.status = "running";
      try {
        await job.run();
        job.status = "done";
      } catch (error) {
        job.status = "failed";
        job.error = error instanceof Error ? error.message : String(error);
        this.log(`operator: job ${job.label} failed: ${job.error}`);
      }
    }
    // Forget finished jobs after a while so the map stays bounded.
    const cutoff = Date.now() - 60 * 60_000;
    for (const [id, job] of this.recentJobs) if (job.createdAt < cutoff) this.recentJobs.delete(id);
  }

  private enqueue(label: string, run: () => Promise<void>): Job {
    const job: Job = { id: `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`, label, run, status: "queued", createdAt: Date.now() };
    this.jobs.push(job);
    this.recentJobs.set(job.id, job);
    return job;
  }

  // ---------------------------------------------------------------------
  // Onboarding faucet
  // ---------------------------------------------------------------------

  /**
   * Prepares `address` (the visitor's L1 account) and `domainAddress` (the key that signs
   * their domain transactions; the same address for a browser account) for the demo.
   */
  async onboard(address: Address, domainAddress: Address, ip: string): Promise<OnboardResult> {
    await this.connect();
    const now = Date.now();
    const key = address.toLowerCase();
    const last = this.lastOnboarding.get(key);
    if (last !== undefined && now - last < this.faucet.cooldownMs) {
      const wait = Math.ceil((this.faucet.cooldownMs - (now - last)) / 60_000);
      throw new HttpError(429, `address was onboarded recently, try again in ${wait} min`);
    }
    const window = (this.ipWindows.get(ip) ?? []).filter((t) => now - t < this.faucet.cooldownMs);
    if (window.length >= this.faucet.perIpLimit) throw new HttpError(429, "too many onboardings from this network, try again later");
    window.push(now);
    this.ipWindows.set(ip, window);
    this.lastOnboarding.set(key, now);

    const d = this.config.deployment;
    let drip: Hex | null = null;
    const targets = new Set<Address>([address, domainAddress]);
    for (const target of targets) {
      const balance = await this.l1.getBalance({ address: target });
      if (balance >= this.faucet.dripBelowWei) continue;
      drip = await withTransientRetry(() =>
        this.faucetWallet.sendTransaction({ account: this.faucetAccount, chain: this.l1Chain, to: target, value: this.faucet.dripWei }),
      );
    }
    const mint = await withTransientRetry(() =>
      this.faucetWallet.writeContract({
        account: this.faucetAccount,
        chain: this.l1Chain,
        address: d.tokens.eur,
        abi: ERC20_ABI,
        functionName: "mint",
        args: [address, this.faucet.mintEur],
      }),
    );
    this.log(`operator: onboarded ${address} (domain account ${domainAddress}, drip ${drip ?? "none"}, mint ${mint})`);

    const job = this.enqueue(`register ${domainAddress}`, async () => {
      await this.registerAt(d.domains.B, this.domainB, domainAddress);
      await this.registerAt(d.domains.A, this.domainA, domainAddress);
    });
    return { address, domainAddress, drip, mint, registration: { id: job.id, status: job.status } };
  }

  /** Registers `user` in a bank's know-your-depositor registry unless already registered. */
  private async registerAt(domain: DemoDomain, client: PublicClient, user: Address): Promise<void> {
    const current = await client.readContract({ address: domain.bank, abi: L2_BANK_ABI, functionName: "receiveAllowance", args: [user] });
    if (current >= this.faucet.receiveLimit) return;
    await sequenceAndWait(
      client,
      {
        l1RpcUrl: this.config.l1RpcUrl,
        hub: this.config.deployment.hub,
        domainChainId: BigInt(domain.chainId),
        senderKey: this.bankKey,
        to: domain.bank,
        data: encodeFunctionData({ abi: L2_BANK_ABI, functionName: "setReceiveAllowance", args: [user, this.faucet.receiveLimit] }),
        gas: 150_000n,
        domainRpcUrl: domainRpcUrl(this.config.l1RpcUrl, domain.chainId, domain.chainId === this.config.deployment.domains.A.chainId ? this.config.domainRpcUrls?.A : this.config.domainRpcUrls?.B),
        sequencingFee: this.config.sequencingFee,
        viewingKey: domain.viewingKey,
        nonceManager,
      },
      { label: `setReceiveAllowance(${user}) on ${domain.chainId}` },
    );
    this.log(`operator: registered ${user} at bank ${domain.bank} on domain ${domain.chainId}`);
  }

  // ---------------------------------------------------------------------
  // HTTP API
  // ---------------------------------------------------------------------

  status(): {
    uptimeMs: number;
    relayer: DomainRelayerStatus[];
    bankAgent: BankAgentStatus;
    queue: number;
    faucet: Address;
  } {
    return {
      uptimeMs: Date.now() - this.startedAt,
      relayer: this.relayer.status(),
      bankAgent: this.bankAgent.status(),
      queue: this.jobs.length,
      faucet: this.faucetAccount.address,
    };
  }

  /** Forwards one JSON-RPC request body to the node and relays the answer. */
  private async gateway(req: IncomingMessage, res: ServerResponse, url: URL): Promise<void> {
    const d = this.config.deployment;
    const upstream = gatewayUpstream(url.pathname, this.config.l1RpcUrl, [
      { chainId: d.domains.A.chainId, rpc: domainRpcUrl(this.config.l1RpcUrl, d.domains.A.chainId, this.config.domainRpcUrls?.A) },
      { chainId: d.domains.B.chainId, rpc: domainRpcUrl(this.config.l1RpcUrl, d.domains.B.chainId, this.config.domainRpcUrls?.B) },
    ]);
    if (!upstream) throw new HttpError(404, "unknown rpc route");
    const chunks: Buffer[] = [];
    let size = 0;
    for await (const chunk of req) {
      size += (chunk as Buffer).length;
      if (size > 1_048_576) throw new HttpError(413, "request body too large");
      chunks.push(chunk as Buffer);
    }
    let answer: Response;
    try {
      answer = await fetch(upstream, {
        method: "POST",
        headers: { "content-type": "application/json", accept: "application/json" },
        body: Buffer.concat(chunks),
        signal: AbortSignal.timeout(60_000),
      });
    } catch (error) {
      throw new HttpError(502, `node unreachable: ${error instanceof Error ? error.message : String(error)}`);
    }
    const body = Buffer.from(await answer.arrayBuffer());
    res.writeHead(answer.status, { "Content-Type": answer.headers.get("content-type") ?? "application/json", "Cache-Control": "no-store" });
    res.end(body);
  }

  private async handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const origin = this.config.corsOrigin ?? "*";
    res.setHeader("Access-Control-Allow-Origin", origin);
    res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Content-Type");
    if (req.method === "OPTIONS") {
      res.writeHead(204).end();
      return;
    }
    const url = new URL(req.url ?? "/", "http://localhost");
    try {
      if (url.pathname === "/rpc" || url.pathname.startsWith("/rpc/")) {
        if (this.config.rpcGateway === false) throw new HttpError(404, "rpc gateway disabled");
        if (req.method !== "POST") throw new HttpError(405, "JSON-RPC is POST only");
        return await this.gateway(req, res, url);
      }
      if (req.method === "GET" && url.pathname === "/api/health") return json(res, 200, { ok: true });
      if (req.method === "GET" && url.pathname === "/api/config") {
        return json(res, 200, {
          deployment: this.config.deployment,
          faucet: {
            address: this.faucetAccount.address,
            dripWei: this.faucet.dripWei.toString(),
            mintEur: this.faucet.mintEur.toString(),
            receiveLimit: this.faucet.receiveLimit.toString(),
            cooldownMs: this.faucet.cooldownMs,
          },
          bankOperator: this.bankAgent.address,
        });
      }
      if (req.method === "GET" && url.pathname === "/api/status") return json(res, 200, this.status());
      if (req.method === "GET" && url.pathname.startsWith("/api/jobs/")) {
        const job = this.recentJobs.get(url.pathname.slice("/api/jobs/".length));
        if (!job) throw new HttpError(404, "unknown job");
        return json(res, 200, { id: job.id, label: job.label, status: job.status, error: job.error ?? null });
      }
      if (req.method === "POST" && url.pathname === "/api/onboard") {
        const body = (await readJson(req)) as { address?: unknown; domainAddress?: unknown };
        if (typeof body.address !== "string" || !isAddress(body.address)) throw new HttpError(400, "address must be an EVM address");
        const address = getAddress(body.address);
        const domainAddress =
          body.domainAddress === undefined || body.domainAddress === null
            ? address
            : typeof body.domainAddress === "string" && isAddress(body.domainAddress)
              ? getAddress(body.domainAddress)
              : (() => {
                  throw new HttpError(400, "domainAddress must be an EVM address");
                })();
        const ip = (req.headers["x-forwarded-for"] as string | undefined)?.split(",")[0]?.trim() || req.socket.remoteAddress || "?";
        return json(res, 200, await this.onboard(address, domainAddress, ip));
      }
      throw new HttpError(404, "not found");
    } catch (error) {
      const status = error instanceof HttpError ? error.status : 500;
      const message = error instanceof Error ? error.message : String(error);
      if (status === 500) this.log(`operator: ${req.method} ${url.pathname} failed: ${message}`);
      json(res, status, { error: message });
    }
  }
}

/** Upstream for one gateway path: the L1 route, or a domain route of a configured domain. */
export function gatewayUpstream(
  pathname: string,
  l1RpcUrl: string,
  domains: { chainId: number; rpc: string }[],
): string | null {
  if (pathname === "/rpc" || pathname === "/rpc/") return l1RpcUrl;
  const match = /^\/rpc\/domain\/(\d+)\/?$/.exec(pathname);
  if (!match) return null;
  const domain = domains.find((d) => d.chainId === Number(match[1]));
  return domain ? domain.rpc : null;
}

/**
 * The node's RPC answers a burst of submissions with "overloaded, try again later"; the
 * faucet's sends are user-facing, so retry them for a few seconds instead of failing the
 * onboarding.
 */
async function withTransientRetry<T>(send: () => Promise<T>, timeoutMs = 15_000): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      return await send();
    } catch (error) {
      const text = `${(error as { details?: string }).details ?? ""} ${error instanceof Error ? error.message : ""}`;
      if (!/overloaded|try again/i.test(text) || Date.now() > deadline) throw error;
      await new Promise((resolve) => setTimeout(resolve, 1_000));
    }
  }
}

class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

function json(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body, (_, v) => (typeof v === "bigint" ? v.toString() : v)));
}

async function readJson(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > 16_384) throw new HttpError(413, "request body too large");
    chunks.push(chunk as Buffer);
  }
  const text = Buffer.concat(chunks).toString("utf8");
  if (!text) return {};
  try {
    return JSON.parse(text);
  } catch {
    throw new HttpError(400, "body must be JSON");
  }
}
