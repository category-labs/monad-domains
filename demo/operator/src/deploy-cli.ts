import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeDeployData,
  encodeFunctionData,
  formatEther,
  getContractAddress,
  http,
  parseEther,
  zeroAddress,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { HUB_INPUT_GAS_HEADROOM, loadArtifact, signDomainAccessToken } from "@domain-bridging/prover";
import { DEMO_L1_BRIDGE_ABI, ERC20_ABI, HUB_ABI, L2_BANK_ABI, POOL_ABI, SPOKE_ABI } from "./abi.js";
import {
  domainRpcUrl,
  loadDeployment,
  saveDeployment,
  type BaseDeployment,
  type DemoDeployment,
  type DemoDomain,
} from "./config.js";
import { domainHttp, sequenceAndWait } from "./domain-tx.js";

/**
 * Layers the bank demo on top of two registered domains (run `forge build` first):
 *
 *   L1:       DemoLedger EUR + USD, one DemoL1Bridge per domain (EUR allowed on A's, USD on
 *             B's), the LockingLiquidityPool (1 EUR = 1.2 USD) seeded with USD liquidity and
 *             with MON, from which it pays the delivery fees of the messages it sends;
 *   domain A: DemoDomainBridge + L2Bank (EUR) - created by sequencing their creation
 *             transactions through the hub from the admin account;
 *   domain B: DemoDomainBridge + L2Bank (USD);
 *   wiring:   registerDomainBridge on both L1 bridges, registerPeer on both banks, Bank A
 *             as the pool's payer bank (the only contract that may request locks), the
 *             KYC tier limits on both banks, and each domain's viewing key sent to the
 *             other domain's spoke, which seals the banks' messages to it.
 *
 * Reads the protocol addresses from deployments/<DEPLOYMENT>.json (hub, spokes, viewing
 * keys, start blocks) and writes the demo addresses back into the same file. The admin must
 * be an operator of both domain RPCs: the script reads the contracts it creates.
 *
 *   L1_RPC_URL=... DOMAIN_A_RPC_URL=... DOMAIN_B_RPC_URL=... ADMIN_KEY=0x... [BANK_KEY=0x...] [DEPLOYMENT=testnet] \
 *   [POOL_USD_LIQUIDITY=1000000] [POOL_MON=50] [LOCK_TTL_SECONDS=600] [TIER_LIMITS=2000,25000] npm run deploy
 */
const RATE_NUM = 12n;
const RATE_DEN = 10n;

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`deploy: ${name} is required`);
  return value;
}

async function main() {
  const l1RpcUrl = required("L1_RPC_URL");
  const adminKey = required("ADMIN_KEY") as Hex;
  const bankKey = (process.env.BANK_KEY ?? adminKey) as Hex;
  const name = process.env.DEPLOYMENT ?? "testnet";
  const base = loadDeployment<BaseDeployment & Partial<DemoDeployment>>(name);
  const poolUsd = parseEther(process.env.POOL_USD_LIQUIDITY ?? "1000000");
  const poolMon = parseEther(process.env.POOL_MON ?? "50");
  const lockTtl = BigInt(process.env.LOCK_TTL_SECONDS ?? "600");
  /** Daily limit of KYC tiers 1, 2, ... at both banks (whole € / $). */
  const tierLimits = (process.env.TIER_LIMITS ?? "2000,25000").split(",").map((v) => parseEther(v.trim()));

  // Every transaction below is confirmed before the next one is sent.
  const admin = privateKeyToAccount(adminKey);
  const bank = privateKeyToAccount(bankKey);
  const probe = createPublicClient({ transport: http(l1RpcUrl) });
  const l1ChainId = await probe.getChainId();
  if (l1ChainId !== base.l1ChainId) throw new Error(`RPC serves chain ${l1ChainId}, deployment is for ${base.l1ChainId}`);
  const l1Chain = defineChain({
    id: l1ChainId,
    name: `l1-${l1ChainId}`,
    nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
    rpcUrls: { default: { http: [l1RpcUrl] } },
  });
  const l1 = createPublicClient({ chain: l1Chain, transport: http(l1RpcUrl) });
  const wallet = createWalletClient({ account: admin, chain: l1Chain, transport: http(l1RpcUrl) });

  const ledgerArt = loadArtifact("DemoLedger.sol", "DemoLedger");
  const l1BridgeArt = loadArtifact("DemoL1Bridge.sol", "DemoL1Bridge");
  const domainBridgeArt = loadArtifact("DemoDomainBridge.sol", "DemoDomainBridge");
  const poolArt = loadArtifact("LockingLiquidityPool.sol", "LockingLiquidityPool");
  const bankArt = loadArtifact("L2Bank.sol", "L2Bank");

  const deployed = async (hash: Hex, label: string): Promise<Address> => {
    const receipt = await l1.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success" || !receipt.contractAddress) throw new Error(`${label} deployment failed (${hash})`);
    console.log(`${label}: ${receipt.contractAddress}`);
    return receipt.contractAddress;
  };
  const confirm = async (hash: Hex, label: string) => {
    const receipt = await l1.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`${label} reverted (${hash})`);
    console.log(`${label}: ${hash}`);
  };

  console.log(`admin ${admin.address}, bank operator ${bank.address}, hub ${base.hub}`);

  // --- L1 ledgers, bridges, pool.
  const eur = await deployed(
    await wallet.deployContract({ abi: ledgerArt.abi, bytecode: ledgerArt.bytecode, args: ["Demo Euro", "EUR"] }),
    "EUR ledger",
  );
  const usd = await deployed(
    await wallet.deployContract({ abi: ledgerArt.abi, bytecode: ledgerArt.bytecode, args: ["Demo Dollar", "USD"] }),
    "USD ledger",
  );
  const l1BridgeA = await deployed(
    await wallet.deployContract({ abi: l1BridgeArt.abi, bytecode: l1BridgeArt.bytecode, args: [base.hub, BigInt(base.domains.A.chainId)] }),
    "DemoL1Bridge A",
  );
  const l1BridgeB = await deployed(
    await wallet.deployContract({ abi: l1BridgeArt.abi, bytecode: l1BridgeArt.bytecode, args: [base.hub, BigInt(base.domains.B.chainId)] }),
    "DemoL1Bridge B",
  );
  const pool = await deployed(
    await wallet.deployContract({
      abi: poolArt.abi,
      bytecode: poolArt.bytecode,
      args: [eur, usd, RATE_NUM, RATE_DEN, l1BridgeA, l1BridgeB, lockTtl],
    }),
    "LockingLiquidityPool",
  );
  await confirm(await wallet.writeContract({ address: usd, abi: ERC20_ABI, functionName: "mint", args: [pool, poolUsd] }), "pool USD liquidity");
  await confirm(await wallet.sendTransaction({ to: pool, value: poolMon }), `pool delivery fees (${formatEther(poolMon)} MON)`);
  await confirm(await wallet.writeContract({ address: l1BridgeA, abi: DEMO_L1_BRIDGE_ABI, functionName: "setTokenAllowed", args: [eur, true] }), "allow EUR on A");
  await confirm(await wallet.writeContract({ address: l1BridgeB, abi: DEMO_L1_BRIDGE_ABI, functionName: "setTokenAllowed", args: [usd, true] }), "allow USD on B");

  // --- Domain contracts, created by sequencing their creation transactions.
  const domainContracts = async (domain: BaseDeployment["domains"]["A"], l1Bridge: Address, token: Address, label: string) => {
    const rpc = domainRpcUrl(domain.chainId, process.env[`DOMAIN_${label}_RPC_URL`]);
    const client: PublicClient = createPublicClient({ transport: domainHttp(rpc, await signDomainAccessToken(adminKey, BigInt(domain.chainId))) });
    const create = async (data: Hex, what: string): Promise<Address> => {
      const nonce = await client.getTransactionCount({ address: admin.address });
      const address = getContractAddress({ from: admin.address, nonce: BigInt(nonce) });
      const { sequenced, receipt } = await sequenceAndWait(
        client,
        { l1RpcUrl, hub: base.hub, domainChainId: BigInt(domain.chainId), senderKey: adminKey, data, gas: 5_000_000n, nonce, viewingKey: domain.viewingKey },
        { label: what },
      );
      if (receipt.contractAddress?.toLowerCase() !== address.toLowerCase()) {
        throw new Error(`${what} landed at ${receipt.contractAddress}, expected ${address}`);
      }
      console.log(`${what} on domain ${domain.chainId}: ${address} (domain tx ${sequenced.domainTxHash})`);
      return address;
    };
    const domainBridge = await create(
      // The admin may name an access policy for the wrapped ledger later; it starts without one.
      encodeDeployData({ abi: domainBridgeArt.abi, bytecode: domainBridgeArt.bytecode, args: [domain.spoke, l1Bridge, admin.address, zeroAddress] }),
      `DemoDomainBridge ${label}`,
    );
    const bankAddress = await create(
      encodeDeployData({
        abi: bankArt.abi,
        bytecode: bankArt.bytecode,
        args: [domain.spoke, domainBridge, token, pool, RATE_NUM, RATE_DEN, bank.address],
      }),
      `L2Bank ${label}`,
    );
    return { rpc, client, domainBridge, bank: bankAddress };
  };
  const a = await domainContracts(base.domains.A, l1BridgeA, eur, "A");
  const b = await domainContracts(base.domains.B, l1BridgeB, usd, "B");

  // --- Wiring.
  await confirm(await wallet.writeContract({ address: l1BridgeA, abi: DEMO_L1_BRIDGE_ABI, functionName: "registerDomainBridge", args: [a.domainBridge] }), "register domain bridge A");
  await confirm(await wallet.writeContract({ address: l1BridgeB, abi: DEMO_L1_BRIDGE_ABI, functionName: "registerDomainBridge", args: [b.domainBridge] }), "register domain bridge B");
  /** Sequences one call from the bank operator to a bank. */
  const bankCall = async (domain: BaseDeployment["domains"]["A"], client: PublicClient, bankAddress: Address, data: Hex, label: string, what: string) => {
    const { sequenced } = await sequenceAndWait(
      client,
      {
        l1RpcUrl,
        hub: base.hub,
        domainChainId: BigInt(domain.chainId),
        senderKey: bankKey,
        to: bankAddress,
        data,
        gas: 150_000n,
        domainRpcUrl: domainRpcUrl(domain.chainId, process.env[`DOMAIN_${label}_RPC_URL`]),
        viewingKey: domain.viewingKey,
      },
      { label: `${what} ${label}` },
    );
    console.log(`bank ${label}: ${what} (domain tx ${sequenced.domainTxHash})`);
  };
  const registerPeer = (domain: BaseDeployment["domains"]["A"], client: PublicClient, bankAddress: Address, peerChainId: number, peer: Address, label: string) =>
    bankCall(domain, client, bankAddress, encodeFunctionData({ abi: L2_BANK_ABI, functionName: "registerPeer", args: [BigInt(peerChainId), peer] }), label, "peer registered");
  await registerPeer(base.domains.A, a.client, a.bank, base.domains.B.chainId, b.bank, "A");
  await registerPeer(base.domains.B, b.client, b.bank, base.domains.A.chainId, a.bank, "B");
  for (const [i, limit] of tierLimits.entries()) {
    const data = encodeFunctionData({ abi: L2_BANK_ABI, functionName: "setTierLimit", args: [i + 1, limit] });
    await bankCall(base.domains.A, a.client, a.bank, data, "A", `tier ${i + 1} limit ${formatEther(limit)} €`);
    await bankCall(base.domains.B, b.client, b.bank, data, "B", `tier ${i + 1} limit ${formatEther(limit)} $`);
  }
  await confirm(await wallet.writeContract({ address: pool, abi: POOL_ABI, functionName: "setPayerBank", args: [a.bank] }), "pool payer bank A");

  // --- Viewing keys: a spoke seals a message to another domain with that domain's key, which
  // the hub sends it as an L1 message.
  const gasPrice = await l1.readContract({ address: base.hub, abi: HUB_ABI, functionName: "DOMAIN_GAS_PRICE" });
  const keyFee = (await l1.readContract({ address: base.hub, abi: HUB_ABI, functionName: "minDeliveryFee", args: [64n] })) + 200_000n * gasPrice;
  const sendKey = async (to: BaseDeployment["domains"]["A"], client: PublicClient, of: BaseDeployment["domains"]["A"], label: string) => {
    const request = {
      account: admin, address: base.hub, abi: HUB_ABI, functionName: "sendViewingKey",
      args: [BigInt(to.chainId), to.spoke, BigInt(of.chainId)], value: keyFee,
    } as const;
    await confirm(
      await wallet.writeContract({ ...request, gas: (await l1.estimateContractGas(request)) + HUB_INPUT_GAS_HEADROOM }),
      `viewing key of domain ${of.chainId} sent to spoke ${label}`,
    );
    const deadline = Date.now() + 120_000;
    for (;;) {
      const stored = await client.readContract({ address: to.spoke, abi: SPOKE_ABI, functionName: "viewingKeys", args: [BigInt(of.chainId)] });
      if (BigInt(stored) !== 0n) break;
      if (Date.now() > deadline) throw new Error(`spoke ${label} did not store the viewing key of domain ${of.chainId} in time`);
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  };
  await sendKey(base.domains.A, a.client, base.domains.B, "A");
  await sendKey(base.domains.B, b.client, base.domains.A, "B");

  const demoDomain = (domain: BaseDeployment["domains"]["A"], l1Bridge: Address, created: { domainBridge: Address; bank: Address }, token: Address): DemoDomain => ({
    chainId: domain.chainId,
    spoke: domain.spoke,
    viewingKey: domain.viewingKey,
    startBlock: domain.startBlock,
    l1StartBlock: domain.l1StartBlock,
    l1Bridge,
    domainBridge: created.domainBridge,
    bank: created.bank,
    token,
  });
  const deployment: DemoDeployment = {
    name: base.name ?? name,
    l1ChainId: base.l1ChainId,
    hub: base.hub,
    rate: { num: RATE_NUM.toString(), den: RATE_DEN.toString() },
    tokens: { eur, usd },
    pool,
    bankOperator: bank.address,
    domains: { A: demoDomain(base.domains.A, l1BridgeA, a, eur), B: demoDomain(base.domains.B, l1BridgeB, b, usd) },
  };
  const path = saveDeployment(name, deployment);
  console.log(`wrote ${path}`);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.stack ?? error.message : error);
  process.exit(1);
});
