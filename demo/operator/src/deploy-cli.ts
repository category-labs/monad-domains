import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeDeployData,
  encodeFunctionData,
  getContractAddress,
  http,
  nonceManager,
  parseEther,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { loadArtifact } from "@domain-bridging/prover";
import { DEMO_L1_BRIDGE_ABI, ERC20_ABI, L2_BANK_ABI } from "./abi.js";
import {
  domainRpcUrl,
  loadDeployment,
  saveDeployment,
  type BaseDeployment,
  type DemoDeployment,
  type DemoDomain,
} from "./config.js";
import { sequenceAndWait } from "./domain-tx.js";

/**
 * Layers the bank demo on top of two registered domains (run `forge build` first):
 *
 *   L1:       DemoLedger EUR + USD, one DemoL1Bridge per domain (EUR allowed on A's, USD on
 *             B's), the LockingLiquidityPool (1 EUR = 1.2 USD) seeded with USD liquidity;
 *   domain A: DemoDomainBridge + L2Bank (EUR) - created by sequencing their creation
 *             transactions through the hub from the admin account;
 *   domain B: DemoDomainBridge + L2Bank (USD);
 *   wiring:   registerDomainBridge on both L1 bridges, registerPeer on both banks.
 *
 * Reads the protocol addresses from deployments/<DEPLOYMENT>.json (hub, spokes, viewing
 * keys, start blocks) and writes the demo addresses back into the same file.
 *
 *   L1_RPC_URL=... ADMIN_KEY=0x... [BANK_KEY=0x...] [DEPLOYMENT=testnet] \
 *   [POOL_USD_LIQUIDITY=1000000] [DOMAIN_A_RPC_URL=...] [DOMAIN_B_RPC_URL=...] npm run deploy
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

  const admin = privateKeyToAccount(adminKey, { nonceManager });
  const bank = privateKeyToAccount(bankKey, { nonceManager });
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
      args: [eur, usd, RATE_NUM, RATE_DEN, l1BridgeA, l1BridgeB, bank.address],
    }),
    "LockingLiquidityPool",
  );
  await confirm(await wallet.writeContract({ address: usd, abi: ERC20_ABI, functionName: "mint", args: [pool, poolUsd] }), "pool USD liquidity");
  await confirm(await wallet.writeContract({ address: l1BridgeA, abi: DEMO_L1_BRIDGE_ABI, functionName: "setTokenAllowed", args: [eur, true] }), "allow EUR on A");
  await confirm(await wallet.writeContract({ address: l1BridgeB, abi: DEMO_L1_BRIDGE_ABI, functionName: "setTokenAllowed", args: [usd, true] }), "allow USD on B");

  // --- Domain contracts, created by sequencing their creation transactions.
  const domainContracts = async (domain: BaseDeployment["domains"]["A"], l1Bridge: Address, token: Address, label: string) => {
    const rpc = domainRpcUrl(l1RpcUrl, domain.chainId, process.env[`DOMAIN_${label}_RPC_URL`]);
    const client: PublicClient = createPublicClient({ transport: http(rpc) });
    const create = async (data: Hex, what: string): Promise<Address> => {
      const nonce = await client.getTransactionCount({ address: admin.address });
      const address = getContractAddress({ from: admin.address, nonce: BigInt(nonce) });
      const { sequenced, receipt } = await sequenceAndWait(
        client,
        { l1RpcUrl, hub: base.hub, domainChainId: BigInt(domain.chainId), senderKey: adminKey, data, gas: 5_000_000n, nonce, viewingKey: domain.viewingKey, nonceManager },
        { label: what },
      );
      if (receipt.contractAddress?.toLowerCase() !== address.toLowerCase()) {
        throw new Error(`${what} landed at ${receipt.contractAddress}, expected ${address}`);
      }
      console.log(`${what} on domain ${domain.chainId}: ${address} (domain tx ${sequenced.domainTxHash})`);
      return address;
    };
    const domainBridge = await create(
      encodeDeployData({ abi: domainBridgeArt.abi, bytecode: domainBridgeArt.bytecode, args: [domain.spoke, l1Bridge] }),
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
  const registerPeer = async (domain: BaseDeployment["domains"]["A"], client: PublicClient, bankAddress: Address, peerChainId: number, peer: Address, label: string) => {
    const { sequenced } = await sequenceAndWait(
      client,
      {
        l1RpcUrl,
        hub: base.hub,
        domainChainId: BigInt(domain.chainId),
        senderKey: bankKey,
        to: bankAddress,
        data: encodeFunctionData({ abi: L2_BANK_ABI, functionName: "registerPeer", args: [BigInt(peerChainId), peer] }),
        gas: 150_000n,
        domainRpcUrl: domainRpcUrl(l1RpcUrl, domain.chainId, process.env[`DOMAIN_${label}_RPC_URL`]),
        viewingKey: domain.viewingKey,
        nonceManager,
      },
      { label: `registerPeer ${label}` },
    );
    console.log(`bank ${label} peer registered (domain tx ${sequenced.domainTxHash})`);
  };
  await registerPeer(base.domains.A, a.client, a.bank, base.domains.B.chainId, b.bank, "A");
  await registerPeer(base.domains.B, b.client, b.bank, base.domains.A.chainId, a.bank, "B");

  const demoDomain = (domain: BaseDeployment["domains"]["A"], l1Bridge: Address, created: { domainBridge: Address; bank: Address }, token: Address): DemoDomain => ({
    chainId: domain.chainId,
    spoke: domain.spoke,
    viewingKey: domain.viewingKey,
    startBlock: domain.startBlock,
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
