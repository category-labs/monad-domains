import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeDeployData,
  getContractAddress,
  http,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { loadArtifact } from "./artifacts.js";
import { encryptTransaction } from "./encryption.js";
import { domainFeeCaps, sponsoredOuterGasLimit } from "./transaction-policy.js";

/**
 * End-to-end setup for a fully L1-sequenced domain.
 *
 * All domain transactions flow through `DomainHub.sequenceToDomain` on the L1, so the
 * domain has no direct transaction path — its system contracts are brought up by *sequencing*
 * their deployment transactions as the seed deployer's first two domain transactions. CREATE
 * addresses are deterministic (`keccak256(rlp(deployer, nonce))`), so the spoke and bridge
 * addresses are known before they execute, which lets the L1 side (`registerDomainBridge`)
 * be wired immediately.
 *
 * Order:
 *   L1:  deploy/reuse DomainHub -> registerDomain (validators, quorum, fee recipient,
 *        viewing key, checkpoint interval)
 *   L1:  deploy L1Bridge(hub, chainId) (admin becomes owner)
 *   -    precompute domain spoke = CREATE(seed, 0), domainBridge = CREATE(seed, 1)
 *   L1:  sequenceToDomain(seed's signed DomainSpoke creation tx)   [nonce 0]
 *   L1:  sequenceToDomain(seed's signed DomainBridge creation tx)  [nonce 1]
 *   L1:  L1Bridge.registerDomainBridge(domainBridge) (one-shot)
 *   L1:  optionally setTokenAllowed(allowedToken) — e.g. wrapped MON for deposits
 */
export interface SetupConfig {
  /** L1 RPC endpoint. */
  l1RpcUrl: string;
  /** Key that deploys the hub + L1Bridge on the L1 and registers the domain; becomes the L1Bridge owner. */
  adminKey: Hex;
  /** Reuse this native-routing hub for another domain. Omit to deploy a new hub. */
  existingHub?: Address;
  /** The domain chain id. */
  domainChainId: bigint;
  /** Validator addresses whose signatures attest domain state transitions. */
  validators: Address[];
  /** Number of distinct validator signatures required to advance the state. */
  quorum: bigint;
  /** Receives the `msg.value` of every `sequenceToDomain` call. Defaults to the admin. */
  feeRecipient?: Address;
  /** Attested L1 heights must be multiples of this many blocks. Default 10. */
  checkpointInterval?: bigint;
  /**
   * Key of the domain account whose first two (sequenced) transactions create the spoke and bridge.
   * Defaults to `adminKey` — the same account works because L1 and domain nonces are independent, so
   * on a fresh domain the admin's domain nonces are 0 and 1. If overridden, the account MUST have
   * no prior domain activity.
   */
  seedDeployerKey?: Hex;
  /** Optional L1 token to allowlist for deposits (e.g. the wrapped-MON ERC20). */
  allowedToken?: Address;
  /** `msg.value` forwarded to the fee recipient per `sequenceToDomain` call. Default 0. */
  sequencingFee?: bigint;
  /** Gas limit for each seeded domain creation transaction. Default 5_000_000. */
  domainGas?: bigint;
  /**
   * Domain viewing public key (65-byte uncompressed P-256 point). Published on the hub at
   * registration so senders can read it, and used here to pass the two seeded creation
   * transactions to `sequenceToDomain` as HPKE ciphertext, which the domain execution client
   * decrypts before executing. Required when the client was started with a receiver key for
   * this domain (`--private-domain <id> <spoke> <key.pem>`).
   */
  viewingKey?: Hex;
}

export interface SetupResult {
  hub: Address;
  l1Bridge: Address;
  /** Deterministic domain addresses the seeded transactions deploy to. */
  spoke: Address;
  domainBridge: Address;
  /** The raw, signed domain creation transactions that were sequenced (for records / replay). */
  seededTransactions: { spoke: Hex; domainBridge: Hex };
}

export async function setupDomain(config: SetupConfig): Promise<SetupResult> {
  const {
    l1RpcUrl,
    adminKey,
    domainChainId,
    validators,
    quorum,
    allowedToken,
    sequencingFee = 0n,
    domainGas = 5_000_000n,
    checkpointInterval = 5n,
    viewingKey,
  } = config;

  if (validators.length === 0) throw new Error("setup: validators must not be empty");
  if (quorum === 0n || quorum > BigInt(validators.length)) {
    throw new Error("setup: quorum must be in [1, validators.length]");
  }
  if (checkpointInterval <= 0n) throw new Error("setup: checkpointInterval must be positive");

  const admin = privateKeyToAccount(adminKey);
  const seed = privateKeyToAccount(config.seedDeployerKey ?? adminKey);
  const feeRecipient = config.feeRecipient ?? admin.address;

  // --- L1 clients ---
  const probe = createPublicClient({ transport: http(l1RpcUrl) });
  const l1ChainId = await probe.getChainId();
  const l1Chain = defineChain({
    id: l1ChainId,
    name: `l1-${l1ChainId}`,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [l1RpcUrl] } },
  });
  const publicClient = createPublicClient({ chain: l1Chain, transport: http(l1RpcUrl) });
  const wallet = createWalletClient({ account: admin, chain: l1Chain, transport: http(l1RpcUrl) });

  const deployedAddress = async (hash: Hex): Promise<Address> => {
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success" || !receipt.contractAddress) throw new Error("setup: deployment failed");
    return receipt.contractAddress;
  };
  const confirm = async (hash: Hex) => {
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`setup: transaction reverted: ${hash}`);
    return receipt;
  };

  const hubArt = loadArtifact("DomainHub.sol", "DomainHub");
  const l1BridgeArt = loadArtifact("L1Bridge.sol", "L1Bridge");
  const spokeArt = loadArtifact("DomainSpoke.sol", "DomainSpoke");
  const domainBridgeArt = loadArtifact("DomainBridge.sol", "DomainBridge");

  // 1. Deploy/reuse the hub and register the domain: validator set + quorum, the fee
  // recipient, the viewing public key senders read back from the hub, and the checkpoint
  // interval attested heights must follow.
  const hub = config.existingHub ?? await deployedAddress(
    await wallet.deployContract({ abi: hubArt.abi, bytecode: hubArt.bytecode }),
  );
  if (config.existingHub) {
    // Fail before sending setup transactions if the address is not a hub or already serves
    // this chain id.
    const registered = (await publicClient.readContract({ address: hub, abi: hubArt.abi,
      functionName: "isDomainRegistered", args: [domainChainId] })) as boolean;
    if (registered) throw new Error(`setup: domain ${domainChainId} is already registered on ${hub}`);
  }
  console.log("DomainHub:", hub);
  await confirm(
    await wallet.writeContract({
      address: hub,
      abi: hubArt.abi,
      functionName: "registerDomain",
      args: [domainChainId, validators, quorum, feeRecipient, viewingKey ?? "0x", checkpointInterval],
    }),
  );
  console.log(
    `  registered chain ${domainChainId} (quorum ${quorum} of ${validators.length}, fee recipient ${feeRecipient}, ` +
      `checkpoint interval ${checkpointInterval}, viewing key ${viewingKey ? "published" : "none"})`,
  );

  // 2. Deploy the L1 bridge (admin becomes owner).
  const l1Bridge = await deployedAddress(
    await wallet.deployContract({ abi: l1BridgeArt.abi, bytecode: l1BridgeArt.bytecode, args: [hub, domainChainId] }),
  );
  console.log("L1Bridge:", l1Bridge);

  // 3. Precompute the domain system-contract addresses from the seed deployer's first two nonces.
  const spoke = getContractAddress({ from: seed.address, nonce: 0n });
  const domainBridge = getContractAddress({ from: seed.address, nonce: 1n });
  console.log("DomainSpoke (seeded):", spoke);
  console.log("DomainBridge (seeded):", domainBridge);

  // 4. Build + sign standard domain creation transactions whose execution is
  // sponsored by their enclosing L1 transactions.
  const latestBlock = await publicClient.getBlock({ blockTag: "latest" });
  const feeCaps = domainFeeCaps(latestBlock.baseFeePerGas ?? (await publicClient.getGasPrice()));
  const domainTxDefaults = {
    type: "eip1559",
    chainId: Number(domainChainId),
    gas: domainGas,
    ...feeCaps,
  } as const;
  const rawSpokeTx = await seed.signTransaction({
    ...domainTxDefaults,
    nonce: 0,
    data: encodeDeployData({ abi: spokeArt.abi, bytecode: spokeArt.bytecode, args: [domainChainId, BigInt(l1ChainId), hub] }),
  });
  const rawBridgeTx = await seed.signTransaction({
    ...domainTxDefaults,
    nonce: 1,
    data: encodeDeployData({ abi: domainBridgeArt.abi, bytecode: domainBridgeArt.bytecode, args: [spoke, l1Bridge] }),
  });

  // 5. Sequence them through the hub (order matters: spoke before bridge). With a viewing key
  // the hub records the HPKE ciphertext of each creation; the execution client decrypts it.
  const sequenceSeedTransaction = async (rawTransaction: Hex): Promise<Hex> => {
    const rlpTx = viewingKey ? await encryptTransaction(viewingKey, rawTransaction) : rawTransaction;
    const request = {
      address: hub,
      abi: hubArt.abi,
      functionName: "sequenceToDomain",
      args: [domainChainId, rlpTx],
      value: sequencingFee,
    } as const;
    const estimatedOuterGas = await publicClient.estimateContractGas({ ...request, account: admin.address });
    return wallet.writeContract({
      ...request,
      gas: sponsoredOuterGasLimit(estimatedOuterGas, domainGas),
    });
  };
  await confirm(await sequenceSeedTransaction(rawSpokeTx));
  await confirm(await sequenceSeedTransaction(rawBridgeTx));
  console.log("  sequenced spoke + bridge creation transactions");

  // 6. Wire the counterpart on the L1 (one-shot) using the precomputed bridge address.
  await confirm(
    await wallet.writeContract({
      address: l1Bridge,
      abi: l1BridgeArt.abi,
      functionName: "registerDomainBridge",
      args: [domainBridge],
    }),
  );
  console.log("  L1Bridge.registerDomainBridge ->", domainBridge);

  // 7. Optionally allowlist a deposit token (e.g. wrapped MON).
  if (allowedToken) {
    await confirm(
      await wallet.writeContract({
        address: l1Bridge,
        abi: l1BridgeArt.abi,
        functionName: "setTokenAllowed",
        args: [allowedToken, true],
      }),
    );
    console.log("  allowed token:", allowedToken);
  }

  return { hub, l1Bridge, spoke, domainBridge, seededTransactions: { spoke: rawSpokeTx, domainBridge: rawBridgeTx } };
}
