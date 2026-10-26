import {
  hashTypedData,
  parseAbi,
  serializeSignature,
  toHex,
  zeroHash,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount, sign } from "viem/accounts";
import { root } from "./merkle.js";
import type { MessageContext } from "./message.js";

/**
 * Validator-side attestation of a domain checkpoint.
 *
 * A checkpoint is an L1 height `H` on the domain's schedule: a multiple of its checkpoint
 * interval and above the hub's last attested height. Every validator derives the same
 * proposal from the hub's state and the domain's state, and signs it independently:
 *
 *   - `H`: the smallest scheduled height above the hub's commitment, attested once the
 *     validator's own node has finalized it (`nextCheckpointHeight`);
 *   - `stateRoot`: the domain's committed state root as of `H` (`monad_getDomainHeader`);
 *   - `anchor`: the Merkle root of the domain-origin messages recorded since the previous
 *     checkpoint `P`, i.e. over the spoke's message ids with nonce in `[count(P), count(H))`,
 *     where `count(x)` is the spoke's `domainMessageCount` in the domain state at height `x`;
 *     zero if that range is empty.
 *
 * The hub tallies signatures per EIP-712 digest and advances once a quorum signed the same
 * `(H, stateRoot, anchor)` for the current state nonce. The nonce pins the previous
 * checkpoint, so a proposal built against a hub state the hub has since moved past is
 * rejected here before it is signed.
 */

export const HUB_CHECKPOINT_ABI = parseAbi([
  "function domainBlockNumbers(uint64 domainChainId) view returns (uint64)",
  "function checkpointIntervals(uint64 domainChainId) view returns (uint64)",
  "function stateNonces(uint64 domainChainId) view returns (uint256)",
  "function readCommitment(uint64 domainChainId) view returns (bytes32)",
  "function domainAnchors(uint64 domainChainId, bytes32 anchor) view returns (bool)",
  "function viewingKeys(uint64 domainChainId) view returns (bytes)",
  "function hasVotedFor(bytes32 digest, address validator) view returns (bool)",
  "function stateTransitionDigest(uint64 domainChainId, uint64 domainBlockNumber, bytes32 newStateRoot, bytes32 domainAnchor) view returns (bytes32)",
  "function submitStateSignature(uint64 domainChainId, uint64 domainBlockNumber, bytes32 newStateRoot, bytes32 domainAnchor, bytes signature)",
  "event StateSignatureSubmitted(uint64 indexed domainChainId, address indexed validator, uint64 domainBlockNumber, bytes32 newStateRoot, bytes32 domainAnchor, uint256 votes)",
  "event DomainStateUpdated(uint64 indexed domainChainId, uint256 stateNonce, uint64 domainBlockNumber, bytes32 newStateRoot, bytes32 domainAnchor)",
]);

export const SPOKE_BATCH_ABI = parseAbi([
  "function domainMessageCount() view returns (uint256)",
  "function domainMessageIds(uint256 sourceNonce) view returns (bytes32)",
  "function domainMessagesRoot(uint256 fromNonce, uint256 toNonce) view returns (bytes32)",
]);

/**
 * `domainMessageIds` reads issued concurrently per page. A client whose HTTP transport batches
 * (`http(url, { batch: true })`) sends each page as one JSON-RPC batch request; the Monad RPC
 * accepts up to 1000 requests per batch by default.
 */
export const DEFAULT_ID_PAGE_SIZE = 256n;

// ---------------------------------------------------------------------------
// EIP-712 digest (mirrors DomainHub.stateTransitionDigest)
// ---------------------------------------------------------------------------

export const STATE_TRANSITION_TYPES = {
  StateTransition: [
    { name: "domainChainId", type: "uint64" },
    { name: "stateNonce", type: "uint256" },
    { name: "domainBlockNumber", type: "uint64" },
    { name: "newStateRoot", type: "bytes32" },
    { name: "domainAnchor", type: "bytes32" },
  ],
} as const;

export interface StateTransition {
  domainChainId: bigint;
  stateNonce: bigint;
  domainBlockNumber: bigint;
  newStateRoot: Hex;
  domainAnchor: Hex;
}

/** The hub's EIP-712 domain: `MonadDomainHub` v1 on the L1 chain at the hub address. */
export function hubTypedDataDomain(context: MessageContext) {
  return { name: "MonadDomainHub", version: "1", chainId: Number(context.l1ChainId), verifyingContract: context.hub } as const;
}

/** Byte-identical to `DomainHub.stateTransitionDigest` for the same state nonce. */
export function stateTransitionDigest(context: MessageContext, transition: StateTransition): Hex {
  return hashTypedData({
    domain: hubTypedDataDomain(context),
    types: STATE_TRANSITION_TYPES,
    primaryType: "StateTransition",
    message: transition,
  });
}

/** Signs a digest the way a validator does: plain secp256k1 over the typed hash. */
export async function signStateTransition(validatorKey: Hex, digest: Hex): Promise<Hex> {
  return serializeSignature(await sign({ hash: digest, privateKey: validatorKey }));
}

// ---------------------------------------------------------------------------
// Reading the domain
// ---------------------------------------------------------------------------

/** Header the domain route returns from `monad_getDomainHeader`. */
export interface DomainHeader {
  /** L1 height the header was committed at (the last block with domain activity). */
  number: bigint;
  stateRoot: Hex;
  parentHash: Hex;
  timestamp: bigint;
}

/**
 * The domain's latest committed header as of `block`. Null while the domain has never
 * executed a transaction. The state root it carries is the domain state at `block`, even
 * when the header's own number is lower (no domain activity since).
 */
export async function getDomainHeader(
  domain: PublicClient,
  block: "latest" | "finalized" | bigint = "latest",
): Promise<DomainHeader | null> {
  const raw = (await domain.request({
    method: "monad_getDomainHeader" as never,
    params: [typeof block === "bigint" ? toHex(block) : block] as never,
  })) as { number: Hex; stateRoot: Hex; parentHash: Hex; timestamp: Hex } | null;
  if (!raw) return null;
  return {
    number: BigInt(raw.number),
    stateRoot: raw.stateRoot,
    parentHash: raw.parentHash,
    timestamp: BigInt(raw.timestamp),
  };
}

/**
 * `spoke.domainMessageCount` in the domain state at `height`. Zero before the spoke had
 * code, which is the only way the call can return no data.
 */
export async function domainMessageCountAt(domain: PublicClient, spoke: Address, height: bigint): Promise<bigint> {
  try {
    return (await domain.readContract({
      address: spoke,
      abi: SPOKE_BATCH_ABI,
      functionName: "domainMessageCount",
      blockNumber: height,
    })) as bigint;
  } catch (error) {
    if (error instanceof Error && error.name === "ContractFunctionExecutionError" && /returned no data/.test(error.message)) {
      return 0n;
    }
    throw error;
  }
}

/**
 * The spoke's message ids with nonce in `[fromNonce, toNonce)` as of `height`, read one nonce
 * at a time from the public mapping, a page of concurrent requests per round, so that a batch
 * of any size can be rebuilt and hashed off-chain.
 */
export async function fetchDomainMessageIds(
  domain: PublicClient,
  spoke: Address,
  fromNonce: bigint,
  toNonce: bigint,
  height: bigint,
  pageSize: bigint = DEFAULT_ID_PAGE_SIZE,
): Promise<Hex[]> {
  if (pageSize <= 0n) throw new Error("checkpoint: page size must be positive");
  const ids: Hex[] = [];
  for (let start = fromNonce; start < toNonce; start += pageSize) {
    const end = start + pageSize < toNonce ? start + pageSize : toNonce;
    const nonces = Array.from({ length: Number(end - start) }, (_, i) => start + BigInt(i));
    const page = await Promise.all(
      nonces.map((nonce) =>
        domain.readContract({
          address: spoke,
          abi: SPOKE_BATCH_ABI,
          functionName: "domainMessageIds",
          args: [nonce],
          blockNumber: height,
        }) as Promise<Hex>,
      ),
    );
    page.forEach((id, i) => {
      // The mapping reads zero for a nonce never recorded; a real id is a keccak hash.
      if (id === zeroHash) throw new Error(`checkpoint: spoke has no message id at nonce ${nonces[i]} as of height ${height}`);
    });
    ids.push(...page);
  }
  return ids;
}

/** The anchor of a batch: the Merkle root over its ids, or zero when empty. */
export function batchRoot(ids: readonly Hex[]): Hex {
  return ids.length === 0 ? zeroHash : root(ids);
}

// ---------------------------------------------------------------------------
// Schedule
// ---------------------------------------------------------------------------

/**
 * The height a validator attests next: the smallest multiple of `interval` above the hub's
 * `lastAttested` height, once `finalizedHeight` has reached it; null until then. A function
 * of hub state alone, so validators that run at different moments or with different finality
 * lags still sign the same proposal. A domain that fell behind catches up one slot per round.
 */
export function nextCheckpointHeight(lastAttested: bigint, interval: bigint, finalizedHeight: bigint): bigint | null {
  if (interval <= 0n) throw new Error("checkpoint: interval must be positive");
  const next = (lastAttested / interval + 1n) * interval;
  return next <= finalizedHeight ? next : null;
}

// ---------------------------------------------------------------------------
// Building and submitting a checkpoint
// ---------------------------------------------------------------------------

/** One checkpoint proposal with the batch it anchors. */
export interface Checkpoint {
  domainChainId: bigint;
  domainBlockNumber: bigint;
  stateRoot: Hex;
  /** Root of the ids with nonce in `[fromNonce, toNonce)`; zero when the range is empty. */
  anchor: Hex;
  fromNonce: bigint;
  toNonce: bigint;
  /** Height of the previous checkpoint; the batch covers domain blocks after it. */
  previousBlockNumber: bigint;
  /** The hub's state nonce the proposal was built against; it pins `previousBlockNumber`. */
  stateNonce: bigint;
}

/**
 * Derives the checkpoint proposal for `height` from the hub and the domain. The hub's nonce
 * and previous height are read from one L1 block, so the batch range is consistent with the
 * nonce the signature will carry. Deterministic: every validator reading the same finalized
 * state builds the same proposal.
 */
export async function buildCheckpoint(args: {
  l1: PublicClient;
  domain: PublicClient;
  hub: Address;
  spoke: Address;
  domainChainId: bigint;
  height: bigint;
  idPageSize?: bigint;
}): Promise<Checkpoint> {
  const { l1, domain, hub, spoke, domainChainId, height, idPageSize } = args;
  const hubBlock = await l1.getBlockNumber({ cacheTime: 0 });
  const [stateNonce, previousBlockNumber] = await Promise.all([
    l1.readContract({ address: hub, abi: HUB_CHECKPOINT_ABI, functionName: "stateNonces", args: [domainChainId], blockNumber: hubBlock })
      .then((n) => BigInt(n)),
    l1.readContract({ address: hub, abi: HUB_CHECKPOINT_ABI, functionName: "domainBlockNumbers", args: [domainChainId], blockNumber: hubBlock })
      .then((n) => BigInt(n)),
  ]);
  if (height <= previousBlockNumber) {
    throw new Error(`checkpoint: height ${height} is not above the hub's attested height ${previousBlockNumber}`);
  }
  const header = await getDomainHeader(domain, height);
  if (!header) throw new Error(`checkpoint: the domain has no committed header at height ${height}`);

  // Before the first attestation nothing can have been recorded, and the domain state at
  // L1 height 0 is not necessarily readable on a long-lived chain.
  const fromNonce = stateNonce === 0n ? 0n : await domainMessageCountAt(domain, spoke, previousBlockNumber);
  const toNonce = await domainMessageCountAt(domain, spoke, height);
  if (toNonce < fromNonce) {
    throw new Error(`checkpoint: message count went backwards (${fromNonce} at ${previousBlockNumber}, ${toNonce} at ${height})`);
  }
  const ids = await fetchDomainMessageIds(domain, spoke, fromNonce, toNonce, height, idPageSize);
  return {
    domainChainId,
    domainBlockNumber: height,
    stateRoot: header.stateRoot,
    anchor: batchRoot(ids),
    fromNonce,
    toNonce,
    previousBlockNumber,
    stateNonce,
  };
}

export interface AttestResult {
  digest: Hex;
  /** Submission transaction hash per validator key this call submitted for. */
  submitted: Hex[];
  /** True once the hub's attested height equals the checkpoint's. */
  advanced: boolean;
}

/**
 * Signs `checkpoint` with every key in `validatorKeys` and submits each signature from
 * `submitter`, skipping keys the hub already counted. Refuses to sign if the hub advanced
 * since the checkpoint was built, because its batch range would then be stale; rebuild it.
 */
export async function attestCheckpoint(args: {
  l1: PublicClient;
  submitter: WalletClient;
  chain: Chain;
  hub: Address;
  checkpoint: Checkpoint;
  validatorKeys: Hex[];
}): Promise<AttestResult> {
  const { l1, submitter, chain, hub, checkpoint, validatorKeys } = args;
  const context: MessageContext = { l1ChainId: BigInt(chain.id), hub };
  const digest = stateTransitionDigest(context, {
    domainChainId: checkpoint.domainChainId,
    stateNonce: checkpoint.stateNonce,
    domainBlockNumber: checkpoint.domainBlockNumber,
    newStateRoot: checkpoint.stateRoot,
    domainAnchor: checkpoint.anchor,
  });
  const hubNonce = BigInt(
    await l1.readContract({ address: hub, abi: HUB_CHECKPOINT_ABI, functionName: "stateNonces", args: [checkpoint.domainChainId] }),
  );
  if (hubNonce !== checkpoint.stateNonce) {
    throw new Error(
      `checkpoint: the hub advanced to state nonce ${hubNonce} since the checkpoint was built at nonce ${checkpoint.stateNonce}; rebuild it`,
    );
  }
  const hubDigest = await l1.readContract({
    address: hub,
    abi: HUB_CHECKPOINT_ABI,
    functionName: "stateTransitionDigest",
    args: [checkpoint.domainChainId, checkpoint.domainBlockNumber, checkpoint.stateRoot, checkpoint.anchor],
  });
  if (hubDigest.toLowerCase() !== digest.toLowerCase()) {
    throw new Error(`checkpoint: local digest ${digest} differs from the hub's ${hubDigest}`);
  }

  const attestedHeight = async () =>
    BigInt(await l1.readContract({ address: hub, abi: HUB_CHECKPOINT_ABI, functionName: "domainBlockNumbers", args: [checkpoint.domainChainId] }));
  const hasVoted = (validator: Address) =>
    l1.readContract({ address: hub, abi: HUB_CHECKPOINT_ABI, functionName: "hasVotedFor", args: [digest, validator] });

  const submitted: Hex[] = [];
  for (const key of validatorKeys) {
    const validator = privateKeyToAccount(key).address;
    if (await hasVoted(validator)) continue;
    const signature = await signStateTransition(key, digest);
    const account = submitter.account;
    if (!account) throw new Error("checkpoint: submitter wallet has no account");
    const hash = await submitter.writeContract({
      account,
      chain,
      address: hub,
      abi: HUB_CHECKPOINT_ABI,
      functionName: "submitStateSignature",
      args: [checkpoint.domainChainId, checkpoint.domainBlockNumber, checkpoint.stateRoot, checkpoint.anchor, signature],
    });
    const receipt = await l1.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") {
      // Another submitter may have landed the same vote first; that is not a failure.
      if (await hasVoted(validator)) continue;
      throw new Error(`checkpoint: submitStateSignature by ${validator} reverted (${hash})`);
    }
    submitted.push(hash);
    if ((await attestedHeight()) === checkpoint.domainBlockNumber) break;
  }
  return { digest, submitted, advanced: (await attestedHeight()) === checkpoint.domainBlockNumber };
}
