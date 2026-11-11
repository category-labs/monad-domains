// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDomainAccessControl} from "./IDomainAccessControl.sol";
import {MessageLib} from "../libraries/MessageLib.sol";

/// @notice L1-side hub of the domain messaging layer: the single L1 contract every domain connects
/// through. It registers domains, sequences their transactions, records L1 -> domain messages, and
/// stores the state roots and domain-origin message anchors each domain's validators attest.
interface IDomainHub {
    event DomainRegistered(uint64 indexed domainChainId, address indexed feeRecipient, uint64 checkpointInterval);

    /// @notice The viewing public key senders encrypt domain transactions and messages to, as a
    /// 65-byte uncompressed P-256 point.
    event ViewingKeyRegistered(uint64 indexed domainChainId, bytes viewingKey);

    /// @notice The domain's validator set and quorum were replaced by `updateDomainConfig`.
    /// `stateNonce` is the nonce the update was signed at; the hub's nonce is now one higher.
    event DomainConfigUpdated(uint64 indexed domainChainId, uint256 stateNonce, address[] validators, uint256 quorum);

    /// @notice One L1-sequenced domain transaction. The domain sender is recovered from the
    /// signed transaction inside `rlpTx`. `fee` is the wei paid: the transaction executes only if
    /// its gas limit is within `fee / DOMAIN_GAS_PRICE`.
    event DomainTransactionSequenced(uint64 indexed domainChainId, bytes rlpTx, uint256 fee);

    /// @notice A validator signature accepted toward a proposed transition.
    event StateSignatureSubmitted(
        uint64 indexed domainChainId,
        address indexed validator,
        uint64 domainBlockNumber,
        bytes32 newStateRoot,
        bytes32 domainAnchor,
        uint256 votes
    );

    /// @notice A quorum of validators advanced the domain to `newStateRoot` at `domainBlockNumber`.
    event DomainStateUpdated(
        uint64 indexed domainChainId,
        uint256 stateNonce,
        uint64 domainBlockNumber,
        bytes32 newStateRoot,
        bytes32 domainAnchor
    );

    event DomainMessageRouted(
        bytes32 indexed messageId,
        uint64 indexed sourceChainId,
        uint64 indexed destinationChainId,
        uint256 deliveryNonce
    );

    event DomainMessageRelayed(
        uint64 indexed sourceChainId,
        bytes32 indexed messageHash,
        address indexed from,
        address to,
        uint256 nonce,
        bool success
    );

    /// @notice Emitted for every recorded L1 -> domain message. This event stream is the
    /// protocol's derivation source for system delivery transactions.
    event L1MessageRecorded(
        uint64 indexed domainChainId,
        uint64 sourceChainId,
        address indexed from,
        address indexed to,
        bytes data,
        uint256 nonce,
        uint256 fee,
        bytes32 messageHash
    );

    /// @notice Emitted for every recorded encrypted L1 -> domain message.
    event EncryptedL1MessageRecorded(
        uint64 indexed domainChainId,
        uint64 sourceChainId,
        address indexed from,
        bytes ciphertext,
        uint256 nonce,
        uint256 fee
    );

    // --- Registration ---

    /// @notice Price of one unit of domain gas in wei. The value attached to a sequencing or
    /// message call is a non-refundable fee paid to the domain's fee recipient; it buys
    /// `value / DOMAIN_GAS_PRICE` gas of domain execution. The execution client mirrors it.
    function DOMAIN_GAS_PRICE() external view returns (uint256);

    /// @notice Smallest fee a message with `dataLength` payload bytes is recorded with: enough
    /// gas for the spoke to deliver it or to mark it failed and retryable. A send or a
    /// domain-bound relay attaching less MUST revert.
    function minDeliveryFee(uint256 dataLength) external pure returns (uint256);

    /// @notice Most gas a domain's sequenced transactions and deliveries may buy per L1 block
    /// in total; a call that would sell more MUST revert, so the work a domain block carries
    /// is bounded whatever its senders pay.
    function DOMAIN_BLOCK_GAS_LIMIT() external view returns (uint256);

    /// @notice Registers an L1-sequenced `domainChainId` with its validator set, the quorum of
    /// validator signatures required to advance the state, the recipient of sequencing fees,
    /// the viewing public key senders encrypt to (65-byte uncompressed P-256 point, or empty)
    /// and the checkpoint interval attested block numbers must be multiples of. MUST reject
    /// the L1 chain id, an already registered chain id, a zero quorum, a quorum exceeding the
    /// validator count, zero or duplicate validators, a zero fee recipient, a zero interval
    /// and a viewing key that is neither empty nor a 65-byte `0x04`-prefixed point.
    function registerDomain(
        uint64 domainChainId,
        address[] calldata validators,
        uint256 quorum,
        address feeRecipient,
        bytes calldata viewingKey,
        uint64 checkpointInterval
    ) external;

    /// @notice The EIP-712 digest validators sign to replace a domain's validator set, quorum and
    /// viewing key, bound to this hub, the L1 chain, the domain and the current `stateNonces`
    /// entry.
    function configUpdateDigest(
        uint64 domainChainId,
        address[] calldata validators,
        uint256 quorum,
        bytes calldata viewingKey
    ) external view returns (bytes32);

    /// @notice Replaces a registered domain's validator set, quorum and viewing key. Needs at
    /// least a quorum of signatures over `configUpdateDigest` from the current validators and
    /// from the new ones, each list ordered by ascending signer address. Bumps `stateNonces`, so
    /// votes cast before the update no longer count. The new values are checked as in
    /// `registerDomain`, and a domain with a viewing key cannot remove it.
    function updateDomainConfig(
        uint64 domainChainId,
        address[] calldata validators,
        uint256 quorum,
        bytes calldata viewingKey,
        bytes[] calldata currentSignatures,
        bytes[] calldata newSignatures
    ) external;

    function isDomainRegistered(uint64 domainChainId) external view returns (bool);
    function getValidators(uint64 domainChainId) external view returns (address[] memory);
    function quorums(uint64 domainChainId) external view returns (uint256);
    function feeRecipients(uint64 domainChainId) external view returns (address);
    function checkpointIntervals(uint64 domainChainId) external view returns (uint64);
    /// @notice The registered viewing public key, or empty bytes.
    function viewingKeys(uint64 domainChainId) external view returns (bytes memory);

    // --- State attestation ---

    /// @notice The EIP-712 digest a domain validator signs to approve a state transition, bound
    /// to this hub, the L1 chain, the domain, and the current `stateNonces` entry. Signing it
    /// attests that `newStateRoot` is the domain's state root at block `domainBlockNumber`, and
    /// that `domainAnchor` is the merkle root of the spoke's message IDs with nonce in
    /// `[count(P), count(domainBlockNumber))`, where `P` is the previously attested block and
    /// `count(x)` the spoke's `domainMessageCount` at block `x`; zero if that range is empty.
    function stateTransitionDigest(
        uint64 domainChainId,
        uint64 domainBlockNumber,
        bytes32 newStateRoot,
        bytes32 domainAnchor
    ) external view returns (bytes32);

    /// @notice A validator submits its signature over a proposed state transition. Votes
    /// accumulate on-chain; the state advances (new root written, nonzero `domainAnchor`
    /// recorded) once a distinct quorum of the domain's registered validators has signed the
    /// same transition. `domainBlockNumber` must be above the last attested one, below the
    /// current L1 block, and a multiple of the domain's checkpoint interval. Submission is
    /// permissionless - the recovered signer is the authority.
    function submitStateSignature(
        uint64 domainChainId,
        uint64 domainBlockNumber,
        bytes32 newStateRoot,
        bytes32 domainAnchor,
        bytes calldata signature
    ) external;

    /// @notice The latest attested state root of the domain.
    function stateRoots(uint64 domainChainId) external view returns (bytes32);

    /// @notice The domain block number of the latest attested state root; transitions must
    /// attest strictly increasing block numbers.
    function domainBlockNumbers(uint64 domainChainId) external view returns (uint64);

    /// @notice Number of state transitions and config updates the domain has gone through.
    /// Bound into every digest, so signatures cannot be replayed against a later transition or
    /// update.
    function stateNonces(uint64 domainChainId) external view returns (uint256);

    /// @notice Votes accumulated for a proposal, keyed by its `stateTransitionDigest`.
    function stateVotes(bytes32 digest) external view returns (uint256);

    function hasVotedFor(bytes32 digest, address validator) external view returns (bool);

    /// @notice True if `anchor` was attested as the root of a batch of messages sent from
    /// `domainChainId` (both L1 callbacks and messages to other domains).
    function domainAnchors(uint64 domainChainId, bytes32 anchor) external view returns (bool);

    // --- Delivery of domain messages ---

    /// @notice Proves any domain-origin message against its source anchor. If its destination
    /// is L1, invokes onDomainMessage and returns callback success (failure is retryable here);
    /// no value may be attached. Otherwise atomically queues it through the same path as
    /// sendL1Message, with `msg.value` as the destination delivery fee (at least the minimum
    /// for the envelope's data), and returns true; destination execution/retry happens on that
    /// domain. Messages can arrive in any order.
    function relayDomainMessage(MessageLib.DomainMessage calldata message, bytes32 anchor, bytes32[] calldata proof)
        external
        payable
        returns (bool success);

    /// @notice Permissionlessly retries an authenticated failed L1 callback with the caller's
    /// gas. A failed retry reverts, preserving the failed mark. Forwarded messages retry on
    /// their destination spoke using retryL1Message with the shared delivery envelope.
    function retryDomainMessage(MessageLib.DomainMessage calldata message) external;

    /// @notice True once an authenticated message has been attempted on L1 or queued to a domain.
    function relayedDomainMessages(uint64 sourceChainId, bytes32 messageHash) external view returns (bool);

    /// @notice True if an authenticated message is awaiting a successful retry.
    function failedDomainMessages(uint64 sourceChainId, bytes32 messageHash) external view returns (bool);

    // --- Domain transactions: sequenced on the L1 ---

    /// @notice Sequences a domain transaction through the L1. Forwards `msg.value` to the
    /// domain's fee recipient as a prepaid, non-refundable execution fee and emits `rlpTx` (a
    /// signed domain transaction, HPKE-encrypted to the domain's viewing key when it has one)
    /// for the domain clients to execute. The fee bounds the transaction's gas limit.
    function sequenceToDomain(uint64 domainChainId, bytes calldata rlpTx) external payable;

    // --- Messaging: L1 -> domain ---

    /// @notice Records a message to the target domain; the domain client delivers it to the
    /// spoke as a system transaction. Nonces are per-domain and gapless (`nonce ==
    /// l1MessageCounts[domainChainId]` at recording time), so the spoke can enforce in-order,
    /// at-most-once delivery. `msg.value` is paid to the domain's fee recipient and sets the
    /// delivery's gas limit (see `DOMAIN_GAS_PRICE`); it must be at least
    /// `minDeliveryFee(data.length)`.
    function sendL1Message(uint64 domainChainId, address to, bytes calldata data) external payable;

    /// @notice Records an encrypted message to the target domain, drawing from the same nonce
    /// sequence as `sendL1Message`. The client decrypts `abi.encodePacked(to, data)` out of
    /// `ciphertext`; a ciphertext it cannot decrypt still consumes its nonce. `msg.value` is the
    /// delivery fee, at least `minDeliveryFee(ciphertext.length)`.
    function sendEncryptedL1Message(uint64 domainChainId, bytes calldata ciphertext) external payable;

    /// @notice Number of L1 -> domain messages recorded for `domainChainId`, plaintext,
    /// encrypted and forwarded alike; equals the nonce the next message will be assigned.
    function l1MessageCounts(uint64 domainChainId) external view returns (uint256);
}

/// @notice Domain-side spoke, deployed in each domain's state. Mirror image of the hub: it
/// records domain-origin messages by nonce and receives the L1 -> domain messages the domain
/// client delivers as system transactions. It also holds the access-control configuration the
/// domain client and RPC enforce.
interface IDomainSpoke is IDomainAccessControl {
    /// @notice Full encoded domain-origin envelope, whether addressed to L1 or another domain.
    event DomainMessageRecorded(bytes32 indexed messageId, bytes message);

    /// @notice Emitted for every protocol-delivered L1 -> domain message. `success` is the
    /// outcome of the target call; a failed delivery is retryable via `retryL1Message`.
    event L1MessageRelayed(
        bytes32 indexed messageHash,
        uint64 sourceChainId,
        address indexed from,
        address indexed to,
        uint256 nonce,
        bool success
    );

    // --- Deployment binding ---

    /// @notice Chain id of the domain this spoke serves.
    function DOMAIN_CHAIN_ID() external view returns (uint64);

    /// @notice L1 chain id and hub address, bound into every outbound message ID.
    function L1_CHAIN_ID() external view returns (uint64);
    function HUB() external view returns (address);

    // --- Delivery of L1 messages (protocol system transactions) ---

    /// @notice Delivers one L1 -> domain message. Callable ONLY from the protocol's system
    /// transactions, which the client derives from the hub's `L1MessageRecorded` and
    /// `EncryptedL1MessageRecorded` events with the gas limit the recorded fee bought. Nonces
    /// must arrive strictly increasing; a gap is a message the client never delivers (an
    /// undecryptable ciphertext or an unpaid delivery), consumed for good by the delivery that
    /// jumps it. The client must derive sourceChainId/from from authenticated hub events. The
    /// spoke calls to.onDomainMessage(sourceChainId, from, data) with all gas but
    /// `DELIVERY_GAS_RESERVE`, copying no return data; a failing target, or one without code, is
    /// marked failed instead of reverting.
    function relayL1Message(uint64 sourceChainId, address from, address to, bytes calldata data, uint256 nonce) external;

    /// @notice Permissionlessly re-executes a failed delivery with the caller's gas.
    function retryL1Message(MessageLib.Message calldata message) external;

    /// @notice Minimum nonce the next delivered L1 -> domain message may carry.
    function nextL1Nonce() external view returns (uint256);

    /// @notice True if the message hash was delivered but its target call failed.
    function failedL1Messages(bytes32 messageHash) external view returns (bool);

    // --- Messaging: domain -> L1 or another domain ---

    /// @notice Sends a message to L1 or another domain through the same authenticated
    /// envelope. Source identity and nonce are assigned by this spoke. An L1 destination
    /// executes a callback there; a domain destination is forwarded without an L1 callback.
    function sendDomainMessage(uint64 destinationChainId, address to, bytes calldata data)
        external
        returns (bytes32 messageId);

    /// @notice Number of domain-origin messages recorded; the nonce the next one gets.
    function domainMessageCount() external view returns (uint256);

    /// @notice Recorded message ID by source nonce. Never cleared, so an attested batch can
    /// always be rebuilt from state.
    function domainMessageIds(uint256 sourceNonce) external view returns (bytes32);
}

/// @notice Shared hook for L1-origin and domain-origin messages. Authenticate msg.sender
/// (the hub on L1, local spoke on a domain), sourceChainId and from together.
interface IDomainMessageReceiver {
    function onDomainMessage(uint64 sourceChainId, address from, bytes calldata data) external;
}
