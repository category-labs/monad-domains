import { createPublicClient, createWalletClient, encodeDeployData, encodeFunctionData, getContractAddress, http, isAddress, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { loadArtifact } from "./artifacts.js";
import { DOMAIN_SPOKE, fetchL1Chain } from "./chain.js";
import { encryptTransaction } from "./encryption.js";
import { domainFeeCaps, HUB_INPUT_GAS_HEADROOM, readDomainGasPrice } from "./sequence.js";

export interface SetupConfig {
  /** L1 RPC endpoint. */
  l1RpcUrl: string;
  /** Key that deploys the hub + L1Bridge on the L1 and registers the domain; becomes the L1Bridge owner. */
  adminKey: Hex;
  /** Register on this existing hub instead of deploying one; domains must share a hub to message each other. */
  existingHub?: Address;
  /** Account that may upgrade the hub deployed here. Defaults to the admin. Unused with `existingHub`. */
  hubOwner?: Address;
  /** The domain chain id: 64 bits whose low 16 bits are the L1 chain id. */
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
   * Key of the domain account whose first sequenced transactions create the optional policy and the bridge.
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
   * Domain encryption public key (32-byte X25519 public key). Published on the hub at
   * registration so senders can read it, and used here to pass the seeded creation
   * transactions to `sequenceToDomain` as HPKE ciphertext, which the domain execution client
   * decrypts before executing. Required by the execution client, which is started with the
   * domain's receiver key (`monad-domain --domain <id> <key.pem>`) and drops plaintext.
   */
  encryptionPubKey?: Hex;
}

export interface SetupResult {
  hub: Address;
  l1Bridge: Address;
  /** The domain's spoke: in the domain's genesis state, at the same address on every domain. */
  spoke: Address;
  /** Deterministic domain address the seeded transaction deploys to. */
  domainBridge: Address;
  tokenPolicyOwner: Address;
  initialTokenPolicy: Address;
  /** The raw, signed domain creation transactions that were sequenced (for records / replay). */
  seededTransactions: { initialTokenPolicy?: Hex; domainBridge: Hex };
}

/**
 * End-to-end setup for a fully L1-sequenced domain.
 *
 * The execution client puts the DomainSpoke in the domain's genesis state, at `DOMAIN_SPOKE`.
 * Every other domain transaction flows through `DomainHub.sequenceToDomain` on the L1, so the
 * bridge is brought up by *sequencing* its deployment transaction as one of the seed deployer's
 * first domain transactions. CREATE addresses are deterministic, so the bridge address is known
 * before it executes, which lets the L1 side (`registerDomainBridge`) be wired immediately.
 *
 * Order:
 *   L1:  deploy/reuse DomainHub (its implementation, then the proxy that is the hub) ->
 *        registerDomain (validators, quorum, fee recipient, encryption public key, checkpoint interval)
 *   L1:  deploy L1Bridge(hub, chainId) (admin becomes owner)
 *   -    precompute default policy = CREATE(seed, 0), bridge = CREATE(seed, 1)
 *   L1:  sequenceToDomain(seed's signed DomainAccessRules creation tx) [nonce 0, unless a policy was supplied]
 *   L1:  sequenceToDomain(seed's signed DomainBridge creation tx)  [nonce 1, or 0 with a supplied policy]
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
    encryptionPubKey,
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
  const hubOwner = config.hubOwner ?? admin.address;
  if (!isAddress(hubOwner) || hubOwner === zeroAddress) {
    throw new Error("setup: hubOwner must be a nonzero L1 address");
  }
  const tokenPolicyOwner = config.tokenPolicyOwner ?? admin.address;
  if (!isAddress(tokenPolicyOwner) || tokenPolicyOwner === zeroAddress) {
    throw new Error("setup: tokenPolicyOwner must be a nonzero domain address");
  }
  if (config.initialTokenPolicy !== undefined &&
      (!isAddress(config.initialTokenPolicy) || config.initialTokenPolicy === zeroAddress)) {
    throw new Error("setup: initialTokenPolicy must be a nonzero domain contract address");
  }

  const l1Chain = await fetchL1Chain(l1RpcUrl);
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
  const proxyArt = loadArtifact("ERC1967Proxy.sol", "ERC1967Proxy");
  const l1BridgeArt = loadArtifact("L1Bridge.sol", "L1Bridge");
  const domainBridgeArt = loadArtifact("DomainBridge.sol", "DomainBridge");

  // 1. Deploy/reuse the hub and register the domain: validator set + quorum, the fee
  // recipient, the encryption public key senders read back from the hub, and the checkpoint
  // interval attested heights must follow.
  // The hub is an ERC-1967 proxy in front of the DomainHub implementation. The proxy's
  // constructor initializes it with the owner who may upgrade it.
  const deployHub = async (): Promise<Address> => {
    const implementation = await deployedAddress(
      await wallet.deployContract({ abi: hubArt.abi, bytecode: hubArt.bytecode }),
    );
    console.log("DomainHub implementation:", implementation, `(owner ${hubOwner})`);
    const initialization = encodeFunctionData({ abi: hubArt.abi, functionName: "initialize", args: [hubOwner] });
    return deployedAddress(
      await wallet.deployContract({ abi: proxyArt.abi, bytecode: proxyArt.bytecode, args: [implementation, initialization] }),
    );
  };
  const hub = config.existingHub ?? await deployHub();
  if (config.existingHub) {
    // Fail before sending setup transactions if the address is not a hub or already serves
    // this chain id.
    const registered = (await publicClient.readContract({ address: hub, abi: hubArt.abi,
      functionName: "isDomainRegistered", args: [domainChainId] })) as boolean;
    if (registered) throw new Error(`setup: domain ${domainChainId} is already registered on ${hub}`);
  }
  console.log("DomainHub:", hub);
  const registration = {
    account: admin,
    address: hub,
    abi: hubArt.abi,
    functionName: "registerDomain",
    args: [
      domainChainId, validators, quorum, feeRecipient, encryptionPubKey ?? "0x", checkpointInterval, maxUnattestedPeriods,
    ],
  } as const;
  // The estimate depends on the L1 block the call lands in, as for every call that records an input.
  await confirm(
    await wallet.writeContract({
      ...registration,
      gas: (await publicClient.estimateContractGas(registration)) + HUB_INPUT_GAS_HEADROOM,
    }),
  );
  console.log(
    `  registered chain ${domainChainId} (quorum ${quorum} of ${validators.length}, fee recipient ${feeRecipient}, ` +
      `checkpoint interval ${checkpointInterval}, at most ${maxUnattestedPeriods} unattested periods, encryption public key ${encryptionPubKey ? "published" : "none"})`,
  );

  // 2. Deploy the L1 bridge (admin becomes owner).
  const l1Bridge = await deployedAddress(
    await wallet.deployContract({ abi: l1BridgeArt.abi, bytecode: l1BridgeArt.bytecode, args: [hub, domainChainId] }),
  );
  console.log("L1Bridge:", l1Bridge);

  // 3. The spoke is in the domain's genesis state. Deploy the default policy before any bridge
  // that uses it.
  const spoke = DOMAIN_SPOKE;
  const bridgeNonce = config.initialTokenPolicy ? 0 : 1;
  const initialTokenPolicy = config.initialTokenPolicy ?? getContractAddress({ from: seed.address, nonce: 0n });
  const domainBridge = getContractAddress({ from: seed.address, nonce: BigInt(bridgeNonce) });
  console.log("DomainSpoke (genesis):", spoke);
  console.log("Initial token policy:", initialTokenPolicy);
  console.log("Token policy owner:", tokenPolicyOwner);
  console.log("DomainBridge (seeded):", domainBridge);

  // 4. Sign the domain creation transactions; their gas is paid for by the fee attached to the
  // L1 call that sequences them.
  const domainGasPrice = await readDomainGasPrice(publicClient, hub);
  const feeCaps = domainFeeCaps(domainGasPrice);
  const domainTxDefaults = {
    type: "eip1559",
    chainId: Number(domainChainId),
    gas: domainGas,
    ...feeCaps,
  } as const;
  let rawPolicyTx: Hex | undefined;
  if (!config.initialTokenPolicy) {
    const policyArt = loadArtifact("DomainAccessRules.sol", "DomainAccessRules");
    rawPolicyTx = await seed.signTransaction({
      ...domainTxDefaults,
      nonce: 0,
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

  // 5. Sequence them through the hub (policy before bridge). With an encryption public key
  // the hub records the HPKE ciphertext of each creation; the execution client decrypts it.
  const sequencingFee = domainGas * domainGasPrice;
  const sequenceSeedTransaction = async (rawTransaction: Hex): Promise<Hex> => {
    const rlpTx = encryptionPubKey ? await encryptTransaction(encryptionPubKey, domainChainId, rawTransaction) : rawTransaction;
    const request = {
      account: admin,
      address: hub,
      abi: hubArt.abi,
      functionName: "sequenceToDomain",
      args: [domainChainId, rlpTx],
      value: sequencingFee,
    } as const;
    return wallet.writeContract({
      ...request,
      gas: (await publicClient.estimateContractGas(request)) + HUB_INPUT_GAS_HEADROOM,
    });
  };
  if (rawPolicyTx) await confirm(await sequenceSeedTransaction(rawPolicyTx));
  await confirm(await sequenceSeedTransaction(rawBridgeTx));
  console.log(`  sequenced ${rawPolicyTx ? "policy + " : ""}bridge creation transactions`);

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
    seededTransactions: { initialTokenPolicy: rawPolicyTx, domainBridge: rawBridgeTx },
  };
}
