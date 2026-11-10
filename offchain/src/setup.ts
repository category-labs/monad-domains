import { createPublicClient, createWalletClient, encodeDeployData, getContractAddress, http, isAddress, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { loadArtifact } from "./artifacts.js";
import { fetchL1Chain } from "./chain.js";
import { encryptTransaction } from "./encryption.js";
import { domainFeeCaps, readDomainGasPrice } from "./sequence.js";

export interface SetupConfig {
  /** L1 RPC endpoint. */
  l1RpcUrl: string;
  /** Key that deploys the hub + L1Bridge on the L1 and registers the domain; becomes the L1Bridge owner. */
  adminKey: Hex;
  /** Register on this existing hub instead of deploying one; domains must share a hub to message each other. */
  existingHub?: Address;
  /** The domain chain id. */
  domainChainId: bigint;
  /** Validator addresses whose signatures attest domain state transitions. */
  validators: Address[];
  /** Number of distinct validator signatures required to advance the state. */
  quorum: bigint;
  /** Receives the fee of every sequencing and message call. Defaults to the admin. */
  feeRecipient?: Address;
  /** Attested L1 heights must be multiples of this many blocks. Default 5. */
  checkpointInterval?: bigint;
  /** Domain account that administers all bridged-token policies. Defaults to the admin. */
  tokenPolicyOwner?: Address;
  /** Existing policy on the domain. When omitted, seed DomainAccessRules; owners must configure each token's rules. */
  initialTokenPolicy?: Address;
  /**
   * Checkpoint periods that may be unattested before the hub stops accepting the domain's
   * inputs, 1 to 50. Default 50.
   */
  maxUnattestedPeriods?: number;
  /**
   * Key of the domain account whose first sequenced transactions create the spoke, optional policy and bridge.
   * Defaults to `adminKey` — the same account works because L1 and domain nonces are independent, so
   * on a fresh domain the admin's domain nonce starts at 0. If overridden, the account MUST have
   * no prior domain activity.
   */
  seedDeployerKey?: Hex;
  /** Optional L1 token to allowlist for deposits (e.g. the wrapped-MON ERC20). */
  allowedToken?: Address;
  /** Gas limit for each seeded domain creation transaction, paid for on the L1. Default 5_000_000. */
  domainGas?: bigint;
  /**
   * Domain viewing public key (32-byte X25519 public key). Published on the hub at
   * registration so senders can read it, and used here to pass the seeded creation
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
  tokenPolicyOwner: Address;
  initialTokenPolicy: Address;
  /** The raw, signed domain creation transactions that were sequenced (for records / replay). */
  seededTransactions: { spoke: Hex; initialTokenPolicy?: Hex; domainBridge: Hex };
}

/**
 * End-to-end setup for a fully L1-sequenced domain.
 *
 * All domain transactions flow through `DomainHub.sequenceToDomain` on the L1, so the domain's
 * system contracts are brought up by *sequencing* their deployment transactions as the seed
 * deployer's first domain transactions. CREATE addresses are deterministic, so the spoke
 * and bridge addresses are known before they execute, which lets the L1 side
 * (`registerDomainBridge`) be wired immediately.
 *
 * Order:
 *   L1:  deploy/reuse DomainHub -> registerDomain (validators, quorum, fee recipient,
 *        viewing key, checkpoint interval)
 *   L1:  deploy L1Bridge(hub, chainId) (admin becomes owner)
 *   -    precompute domain spoke = CREATE(seed, 0), default policy = CREATE(seed, 1), bridge = CREATE(seed, 2)
 *   L1:  sequenceToDomain(seed's signed DomainSpoke creation tx)   [nonce 0]
 *   L1:  sequenceToDomain(seed's signed DomainAccessRules creation tx) [nonce 1, unless a policy was supplied]
 *   L1:  sequenceToDomain(seed's signed DomainBridge creation tx)  [nonce 2, or 1 with a supplied policy]
 *   L1:  L1Bridge.registerDomainBridge(domainBridge) (one-shot)
 *   L1:  optionally setTokenAllowed(allowedToken) — e.g. wrapped MON for deposits
 */
export async function setupDomain(config: SetupConfig): Promise<SetupResult> {
  const {
    l1RpcUrl,
    adminKey,
    domainChainId,
    validators,
    quorum,
    allowedToken,
    domainGas = 5_000_000n,
    checkpointInterval = 5n,
    maxUnattestedPeriods = 50,
    viewingKey,
  } = config;

  if (validators.length === 0) throw new Error("setup: validators must not be empty");
  if (quorum === 0n || quorum > BigInt(validators.length)) {
    throw new Error("setup: quorum must be in [1, validators.length]");
  }
  if (checkpointInterval <= 0n) throw new Error("setup: checkpointInterval must be positive");
  if (!Number.isInteger(maxUnattestedPeriods) || maxUnattestedPeriods < 1 || maxUnattestedPeriods > 50) {
    throw new Error("setup: maxUnattestedPeriods must be in [1, 50]");
  }

  const admin = privateKeyToAccount(adminKey);
  const seed = privateKeyToAccount(config.seedDeployerKey ?? adminKey);
  const feeRecipient = config.feeRecipient ?? admin.address;
  const tokenPolicyOwner = config.tokenPolicyOwner ?? admin.address;
  if (!isAddress(tokenPolicyOwner) || tokenPolicyOwner === zeroAddress) {
    throw new Error("setup: tokenPolicyOwner must be a nonzero domain address");
  }
  if (config.initialTokenPolicy !== undefined &&
      (!isAddress(config.initialTokenPolicy) || config.initialTokenPolicy === zeroAddress)) {
    throw new Error("setup: initialTokenPolicy must be a nonzero domain contract address");
  }

  const l1Chain = await fetchL1Chain(l1RpcUrl);
  const l1ChainId = l1Chain.id;
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
      args: [
        domainChainId, validators, quorum, feeRecipient, viewingKey ?? "0x", checkpointInterval, maxUnattestedPeriods,
      ],
    }),
  );
  console.log(
    `  registered chain ${domainChainId} (quorum ${quorum} of ${validators.length}, fee recipient ${feeRecipient}, ` +
      `checkpoint interval ${checkpointInterval}, at most ${maxUnattestedPeriods} unattested periods, viewing key ${viewingKey ? "published" : "none"})`,
  );

  // 2. Deploy the L1 bridge (admin becomes owner).
  const l1Bridge = await deployedAddress(
    await wallet.deployContract({ abi: l1BridgeArt.abi, bytecode: l1BridgeArt.bytecode, args: [hub, domainChainId] }),
  );
  console.log("L1Bridge:", l1Bridge);

  // 3. Keep the spoke at nonce 0; deploy the default policy before any bridge that uses it.
  const spoke = getContractAddress({ from: seed.address, nonce: 0n });
  const bridgeNonce = config.initialTokenPolicy ? 1 : 2;
  const initialTokenPolicy = config.initialTokenPolicy ?? getContractAddress({ from: seed.address, nonce: 1n });
  const domainBridge = getContractAddress({ from: seed.address, nonce: BigInt(bridgeNonce) });
  console.log("DomainSpoke (seeded):", spoke);
  console.log("Initial token policy:", initialTokenPolicy);
  console.log("Token policy owner:", tokenPolicyOwner);
  console.log("DomainBridge (seeded):", domainBridge);

  // 4. Sign the domain creation transactions; their gas is paid for by the fee attached to the
  // L1 call that sequences them.
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
  let rawPolicyTx: Hex | undefined;
  if (!config.initialTokenPolicy) {
    const policyArt = loadArtifact("DomainAccessRules.sol", "DomainAccessRules");
    rawPolicyTx = await seed.signTransaction({
      ...domainTxDefaults,
      nonce: 1,
      data: encodeDeployData({ abi: policyArt.abi, bytecode: policyArt.bytecode, args: [spoke] }),
    });
  }
  const rawBridgeTx = await seed.signTransaction({
    ...domainTxDefaults,
    nonce: bridgeNonce,
    data: encodeDeployData({
      abi: domainBridgeArt.abi, bytecode: domainBridgeArt.bytecode,
      args: [spoke, l1Bridge, tokenPolicyOwner, initialTokenPolicy],
    }),
  });

  // 5. Sequence them through the hub (spoke and policy before bridge). With a viewing key
  // the hub records the HPKE ciphertext of each creation; the execution client decrypts it.
  const sequencingFee = domainGas * (await readDomainGasPrice(publicClient, hub));
  const sequenceSeedTransaction = async (rawTransaction: Hex): Promise<Hex> => {
    const rlpTx = viewingKey ? await encryptTransaction(viewingKey, domainChainId, rawTransaction) : rawTransaction;
    return wallet.writeContract({
      address: hub,
      abi: hubArt.abi,
      functionName: "sequenceToDomain",
      args: [domainChainId, rlpTx],
      value: sequencingFee,
    });
  };
  await confirm(await sequenceSeedTransaction(rawSpokeTx));
  if (rawPolicyTx) await confirm(await sequenceSeedTransaction(rawPolicyTx));
  await confirm(await sequenceSeedTransaction(rawBridgeTx));
  console.log(`  sequenced spoke + ${rawPolicyTx ? "policy + " : ""}bridge creation transactions`);

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

  return {
    hub, l1Bridge, spoke, domainBridge, tokenPolicyOwner, initialTokenPolicy,
    seededTransactions: { spoke: rawSpokeTx, initialTokenPolicy: rawPolicyTx, domainBridge: rawBridgeTx },
  };
}
