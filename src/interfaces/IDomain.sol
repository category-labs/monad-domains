// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDomainAccessControl} from "./IDomainAccessControl.sol";
import {MessageLib} from "../libraries/MessageLib.sol";

/// @notice L1-side hub interface of the domain messaging layer. The hub is the single L1
/// contract every domain (spoke) connects through. It records outbound L1 -> domain
/// messages and stores merkle anchors of domain -> L1 messages, which domain validators
/// attest alongside a new state commitment.
interface IDomainHub {
    event DomainMessageRelayed(
        uint64 indexed domainChainId,
        bytes32 indexed messageHash,
        address indexed from,
        address to,
        uint256 nonce,
        bool success
    );

    /// @notice Emitted for every recorded L1 -> domain message. This event stream is the
    /// protocol's derivation source for system delivery transactions; it carries the full
    /// preimage so the client needs no extra state reads.
    event L1MessageRecorded(
        uint64 indexed domainChainId,
        address indexed from,
        address indexed to,
        bytes data,
        uint256 nonce,
        bytes32 messageHash
    );

    /// @notice Emitted for every recorded encrypted L1 -> domain message.
    event EncryptedL1MessageRecorded(
        uint64 indexed domainChainId, address indexed from, bytes ciphertext, uint256 nonce
    );

    // --- Registration ---

    /// @notice Registers an L1-sequenced `domainChainId` with the selected state
    /// verification mode, its validator set and the quorum of validator signatures required to
    /// advance the state, recording the caller as the domain operator. MUST reject the L1
    /// chain id, an already registered chain id, an unknown `stateVerificationMode`, a zero
    /// quorum, a quorum exceeding the validator count, and zero or duplicate validators.
    function registerDomain(
        uint64 domainChainId,
        uint8 stateVerificationMode,
        address[] calldata validators,
        uint256 quorum
    ) external;

    // --- State commitments & domain -> L1 anchors ---

    /// @notice Returns the state commitment of the domain as of its latest posted update.
    function readCommitment(uint64 domainChainId) external view returns (bytes32 stateCommitment);

    /// @notice The digest a domain validator signs to approve a state transition, bound to
    /// this hub, the L1 chain, the domain, and the current `stateNonce`. Signing it attests
    /// that `newStateRoot` is the domain's state root at block `domainBlockNumber`.
    function stateTransitionDigest(
        uint64 domainChainId,
        uint64 domainBlockNumber,
        bytes32 newStateRoot,
        bytes32 domainAnchor
    ) external view returns (bytes32);

    /// @notice A validator submits its signature over a proposed state transition. Votes
    /// accumulate on-chain; the state advances (new commitment written, `domainAnchor`
    /// recorded) only once a distinct quorum of the domain's registered validators has signed
    /// the same transition. Submission is permissionless - the recovered signer is the authority.
    function submitStateSignature(
        uint64 domainChainId,
        uint64 domainBlockNumber,
        bytes32 newStateRoot,
        bytes32 domainAnchor,
        bytes calldata signature
    ) external;

    /// @notice The domain block number of the latest committed state root.
    function domainBlockNumbers(uint64 domainChainId) external view returns (uint64);

    /// @notice True if `anchor` is a recorded merkle root of messages sent from
    /// `domainChainId` to the L1.
    function domainAnchors(uint64 domainChainId, bytes32 anchor) external view returns (bool);

    // --- Delivery of domain messages ---

    /// @notice Proves a message against an accepted anchor for its source domain and
    /// invokes `onDomainMessage` on its destination. Messages can arrive in any order.
    /// A failed target call is recorded for retry instead of reverting. Returns delivery
    /// success so callers composing atomic operations can require successful execution.
    function relayDomainMessage(
        uint64 domainChainId,
        MessageLib.Message calldata message,
        bytes32 anchor,
        bytes32[] calldata proof
    ) external returns (bool success);

    /// @notice Permissionlessly retries an authenticated failed message with the caller's
    /// gas. A failed retry reverts, preserving the failed mark.
    function retryDomainMessage(uint64 domainChainId, MessageLib.Message calldata message) external;

    /// @notice True once an authenticated message has had its initial delivery attempted.
    function relayedDomainMessages(uint64 domainChainId, bytes32 messageHash) external view returns (bool);

    /// @notice True if an authenticated message is awaiting a successful retry.
    function failedDomainMessages(uint64 domainChainId, bytes32 messageHash) external view returns (bool);

    // --- Messaging: L1 -> domain ---

    /// @notice Records a message to the target domain. Nonces are per-domain and gapless
    /// (`nonce == l1MessageCounts[domainChainId]` at recording time), so the spoke can
    /// enforce exactly-once, in-order delivery.
    function sendL1Message(uint64 domainChainId, address to, bytes calldata data) external;

    /// @notice Records an encrypted message to the target domain. A ciphertext the client
    /// cannot decrypt still consumes its nonce.
    function sendEncryptedL1Message(uint64 domainChainId, bytes calldata ciphertext) external;

    /// @notice Number of L1 -> domain messages recorded for `domainChainId`; equals the
    /// nonce the next message will be assigned.
    function l1MessageCounts(uint64 domainChainId) external view returns (uint256);
}

/// @notice Domain-side spoke interface, deployed on a domain. Mirror image of the
/// hub: records outbound domain -> L1 messages, and receives the L1 -> domain messages
/// that the domain protocol delivers as system transactions.
interface IDomainSpoke is IDomainAccessControl {
    /// @notice Emitted for every recorded domain -> L1 message. Carries the full preimage so
    /// provers can reconstruct the merkle leaf without extra state reads.
    event DomainMessageRecorded(
        address indexed from, address indexed to, bytes data, uint256 nonce, bytes32 messageHash
    );

    /// @notice Emitted for every protocol-delivered L1 -> domain message. `success` is the
    /// outcome of the target call; a failed delivery is retryable via `retryL1Message`.
    event L1MessageRelayed(
        bytes32 indexed messageHash, address indexed from, address indexed to, uint256 nonce, bool success
    );

    // --- Delivery of L1 messages (protocol system transactions) ---

    /// @notice Delivers one L1 -> domain message. Callable ONLY from the protocol's system
    /// transactions, which the client derives from the hub's `L1MessageRecorded` and
    /// `EncryptedL1MessageRecorded` events. Nonces must arrive strictly increasing; a gap is
    /// an undecryptable encrypted message the client never delivers, consumed for good by the
    /// delivery that jumps it.
    function relayL1Message(address from, address to, bytes calldata data, uint256 nonce) external;

    /// @notice Permissionlessly re-executes a failed delivery with the caller's gas.
    function retryL1Message(MessageLib.Message calldata message) external;

    /// @notice Minimum nonce the next delivered L1 -> domain message may carry.
    function nextL1Nonce() external view returns (uint256);

    /// @notice True if the message hash was delivered but its target call failed.
    function failedL1Messages(bytes32 messageHash) external view returns (bool);

    // --- Messaging: domain -> L1 ---

    /// @notice Records a message to the L1. The message hash
    /// `keccak256(abi.encodePacked(msg.sender, to, keccak256(data), nonce))` is appended to the
    /// pending message array.
    function sendDomainMessage(address to, bytes calldata data) external;

    /// @notice Operator-only. Merkleizes the pending domain -> L1 messages into an anchor and
    /// clears them. The operator relays the returned anchor onto the hub via
    /// `submitStateSignature`.
    function finalizeDomainMessages() external returns (bytes32 anchor);

    /// @notice Pending domain -> L1 message hash at `index`.
    function pendingDomainMessages(uint256 index) external view returns (bytes32);
}

/// @notice Hook implemented by domain contracts that consume L1 -> domain messages. The
/// spoke invokes it during protocol delivery. Implementations MUST authenticate both
/// `msg.sender` (the spoke) and `from` (their expected L1 counterpart).
interface IL1MessageReceiver {
    /// @param from The L1 account that called `sendL1Message` on the hub.
    /// @param data The message payload exactly as recorded on the hub.
    function onL1Message(address from, bytes calldata data) external;
}

/// @notice Hook implemented by L1 applications receiving domain messages. Implementations
/// MUST authenticate `msg.sender` (the hub), `domainChainId`, and `from` (their counterpart).
interface IDomainMessageReceiver {
    function onDomainMessage(uint64 domainChainId, address from, bytes calldata data) external;
}
