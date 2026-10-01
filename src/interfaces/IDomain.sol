// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDomainAccessControl} from "./IDomainAccessControl.sol";
import {MessageLib} from "../libraries/MessageLib.sol";

/// @notice L1-side hub interface of the domain messaging layer. The hub is the single L1
/// contract every domain (spoke) connects through. It records outbound L1 -> domain
/// messages and stores merkle anchors of all domain-origin messages, which domain validators
/// attest alongside a new state commitment.
interface IDomainHub {
    event DomainMessageRouted(
        bytes32 indexed messageId,
        uint64 indexed sourceChainId,
        uint64 indexed destinationChainId,
        uint256 deliveryNonce
    );

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
    /// preimage so the client needs no extra state reads. sourceChainId/from identify the
    /// proven source domain sender, or the L1 caller for ordinary sends; to is the application.
    event L1MessageRecorded(
        uint64 indexed domainChainId,
        uint64 sourceChainId,
        address indexed from,
        address indexed to,
        bytes data,
        uint256 nonce,
        bytes32 messageHash
    );

    /// @notice Emitted for every recorded encrypted L1 -> domain message.
    event EncryptedL1MessageRecorded(
        uint64 indexed domainChainId, uint64 sourceChainId, address indexed from, bytes ciphertext, uint256 nonce
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

    /// @notice True if `anchor` is a recorded merkle root of outbound messages sent from
    /// `domainChainId` (both L1 callbacks and native domain routes).
    function domainAnchors(uint64 domainChainId, bytes32 anchor) external view returns (bool);

    // --- Delivery of domain messages ---

    /// @notice Proves any domain-origin message against its source anchor. If its destination
    /// is L1, invokes onDomainMessage and returns callback success (failure is retryable here).
    /// Otherwise atomically queues it through the same path as sendL1Message and returns true;
    /// destination execution/retry happens on that domain. Messages can arrive in any order.
    function relayDomainMessage(MessageLib.DomainMessage calldata message, bytes32 anchor, bytes32[] calldata proof)
        external
        returns (bool success);

    /// @notice Permissionlessly retries an authenticated failed L1 callback with the caller's
    /// gas. A failed retry reverts, preserving the failed mark. Forwarded messages retry on
    /// their destination spoke using retryL1Message with the shared delivery envelope.
    function retryDomainMessage(MessageLib.DomainMessage calldata message) external;

    /// @notice True once an authenticated message has been attempted on L1 or queued to a domain.
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
/// hub: records outbound domain messages, and receives the L1 -> domain envelopes
/// that the domain protocol delivers as system transactions.
interface IDomainSpoke is IDomainAccessControl {
    function L1_CHAIN_ID() external view returns (uint64);
    /// @notice Full domain-origin envelope, whether addressed to L1 or another domain.
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

    // --- Delivery of L1 messages (protocol system transactions) ---

    /// @notice Delivers one L1 -> domain message. Callable ONLY from the protocol's system
    /// transactions, which the client derives from the hub's `L1MessageRecorded` and
    /// `EncryptedL1MessageRecorded` events. Nonces must arrive strictly increasing; a gap is
    /// an undecryptable encrypted message the client never delivers, consumed for good by the
    /// delivery that jumps it. The client must derive sourceChainId/from from authenticated
    /// hub events. The spoke calls to.onDomainMessage(sourceChainId, from, data); targets
    /// without code are marked failed and can be retried after deployment.
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

    /// @notice Operator-only. Merkleizes all pending outbound messages into an anchor and
    /// clears them. The operator relays the returned anchor onto the hub via
    /// `submitStateSignature`.
    function finalizeDomainMessages() external returns (bytes32 anchor);

    /// @notice Pending outbound domain message ID at `index`.
    function pendingDomainMessages(uint256 index) external view returns (bytes32);
}

/// @notice Shared hook for L1-origin and domain-origin messages. Authenticate msg.sender
/// (the hub on L1, local spoke on a domain), sourceChainId and from together.
interface IDomainMessageReceiver {
    function onDomainMessage(uint64 sourceChainId, address from, bytes calldata data) external;
}
