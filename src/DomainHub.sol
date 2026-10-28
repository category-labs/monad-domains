// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IDomainHub, IDomainMessageReceiver} from "./interfaces/IDomain.sol";
import {MessageLib} from "./libraries/MessageLib.sol";

contract DomainHub is IDomainHub, EIP712 {
    /// @notice EIP-712 type of the digest a validator signs to approve a state transition.
    bytes32 public constant STATE_TRANSITION_TYPEHASH = keccak256(
        "StateTransition(uint64 domainChainId,uint256 stateNonce,uint64 domainBlockNumber,bytes32 newStateRoot,bytes32 domainAnchor)"
    );
    /// @notice Length of an uncompressed SEC1 P-256 point: the only accepted viewing key encoding.
    uint256 public constant VIEWING_KEY_LENGTH = 65;

    /// @notice Emitted for every L1-sequenced domain transaction. Domain validators
    /// derive their blocks from these events. The transaction's sender is recovered from the
    /// signature inside `rlpTx`; the L1 submitter is the enclosing L1 transaction's own sender.
    event DomainTransactionSequenced(uint64 indexed domainChainId, bytes rlpTx, uint256 fee);
    /// @notice Emitted for each validator signature accepted toward the pending state
    /// transition, carrying the running vote tally for that proposal.
    event StateSignatureSubmitted(
        uint64 indexed domainChainId,
        address indexed validator,
        uint64 domainBlockNumber,
        bytes32 newStateRoot,
        bytes32 domainAnchor,
        uint256 votes
    );
    /// @notice Emitted when a quorum of domain validators advances the state.
    /// `domainBlockNumber` is the domain block `newStateRoot` is the state root of.
    event DomainStateUpdated(
        uint64 indexed domainChainId,
        uint256 stateNonce,
        uint64 domainBlockNumber,
        bytes32 newStateRoot,
        bytes32 domainAnchor
    );

    struct DomainConfig {
        bool registered;
        /// @dev Attested block numbers must be multiples of this interval.
        uint64 checkpointInterval;
        /// @dev Receives the value attached to `sequenceToDomain`.
        address feeRecipient;
        uint256 quorum;
        address[] validators;
        /// @dev Uncompressed P-256 point senders encrypt domain transactions to, or empty.
        bytes viewingKey;
        mapping(address => bool) isValidator;
    }

    mapping(uint64 => DomainConfig) internal _configs;
    mapping(uint64 => bytes32) internal _commitments;
    /// @notice Shared destination delivery nonce for plaintext, encrypted and routed messages.
    mapping(uint64 => uint256) public l1MessageCounts;
    mapping(uint64 => mapping(bytes32 => bool)) public domainAnchors;
    /// @notice Source messages consumed by the shared relay path, scoped by source domain.
    /// A native relay marks queueing here; destination execution is tracked by the spoke.
    mapping(uint64 => mapping(bytes32 => bool)) public relayedDomainMessages;
    mapping(uint64 => mapping(bytes32 => bool)) public failedDomainMessages;
    /// @notice Monotonic per-domain counter binding each state transition, so a round's
    /// signatures cannot be replayed against a later transition.
    mapping(uint64 => uint256) public stateNonces;
    /// @notice The domain block number of the latest committed state root. Transitions must
    /// commit strictly increasing block numbers.
    mapping(uint64 => uint64) public domainBlockNumbers;
    /// @notice Votes accumulated for a proposal, keyed by its `stateTransitionDigest`.
    mapping(bytes32 => uint256) public stateVotes;
    /// @notice Whether a given validator has already voted for a proposal digest.
    mapping(bytes32 => mapping(address => bool)) public hasVotedFor;

    constructor() EIP712("MonadDomainHub", "1") {}

    // ---------------------------------------------------------------------
    // Registration
    // ---------------------------------------------------------------------

    function registerDomain(
        uint64 domainChainId,
        address[] calldata validators,
        uint256 quorum,
        address feeRecipient,
        bytes calldata viewingKey,
        uint64 checkpointInterval
    ) external {
        require(domainChainId != block.chainid, "DomainHub: cannot register L1 chain id");
        DomainConfig storage config = _configs[domainChainId];
        require(!config.registered, "DomainHub: already registered");
        require(quorum > 0, "DomainHub: zero quorum");
        require(quorum <= validators.length, "DomainHub: quorum exceeds validators");
        require(feeRecipient != address(0), "DomainHub: zero fee recipient");
        require(checkpointInterval > 0, "DomainHub: zero checkpoint interval");
        require(
            viewingKey.length == 0 || (viewingKey.length == VIEWING_KEY_LENGTH && viewingKey[0] == 0x04),
            "DomainHub: invalid viewing key"
        );

        config.registered = true;
        config.checkpointInterval = checkpointInterval;
        config.feeRecipient = feeRecipient;
        config.quorum = quorum;
        config.viewingKey = viewingKey;
        for (uint256 i = 0; i < validators.length; i++) {
            address validator = validators[i];
            require(validator != address(0), "DomainHub: zero validator");
            require(!config.isValidator[validator], "DomainHub: duplicate validator");
            config.isValidator[validator] = true;
            config.validators.push(validator);
        }

        emit DomainRegistered(domainChainId, feeRecipient, checkpointInterval);
        emit ViewingKeyRegistered(domainChainId, viewingKey);
    }

    function isDomainRegistered(uint64 domainChainId) external view returns (bool) {
        return _configs[domainChainId].registered;
    }

    function getValidators(uint64 domainChainId) external view returns (address[] memory) {
        return _configs[domainChainId].validators;
    }

    function isDomainValidator(uint64 domainChainId, address account) external view returns (bool) {
        return _configs[domainChainId].isValidator[account];
    }

    function quorums(uint64 domainChainId) external view returns (uint256) {
        return _configs[domainChainId].quorum;
    }

    function feeRecipients(uint64 domainChainId) external view returns (address) {
        return _configs[domainChainId].feeRecipient;
    }

    function checkpointIntervals(uint64 domainChainId) external view returns (uint64) {
        return _configs[domainChainId].checkpointInterval;
    }

    function viewingKeys(uint64 domainChainId) external view returns (bytes memory) {
        return _configs[domainChainId].viewingKey;
    }

    // ---------------------------------------------------------------------
    // State commitments & domain -> L1 anchors
    // ---------------------------------------------------------------------

    function readCommitment(uint64 domainChainId) external view returns (bytes32) {
        return _commitments[domainChainId];
    }

    function stateTransitionDigest(
        uint64 domainChainId,
        uint64 domainBlockNumber,
        bytes32 newStateRoot,
        bytes32 domainAnchor
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    STATE_TRANSITION_TYPEHASH,
                    domainChainId,
                    stateNonces[domainChainId],
                    domainBlockNumber,
                    newStateRoot,
                    domainAnchor
                )
            )
        );
    }

    function submitStateSignature(
        uint64 domainChainId,
        uint64 domainBlockNumber,
        bytes32 newStateRoot,
        bytes32 domainAnchor,
        bytes calldata signature
    ) external {
        DomainConfig storage config = _configs[domainChainId];
        require(config.registered, "DomainHub: domain not registered");
        require(domainBlockNumber > domainBlockNumbers[domainChainId], "DomainHub: stale block number");
        require(uint256(domainBlockNumber) < block.number, "DomainHub: block number not in the past");
        require(domainBlockNumber % config.checkpointInterval == 0, "DomainHub: block number off schedule");

        bytes32 digest = stateTransitionDigest(domainChainId, domainBlockNumber, newStateRoot, domainAnchor);
        address signer = ECDSA.recover(digest, signature);
        require(config.isValidator[signer], "DomainHub: not a validator");
        require(!hasVotedFor[digest][signer], "DomainHub: already voted");

        hasVotedFor[digest][signer] = true;
        uint256 votes = ++stateVotes[digest];
        emit StateSignatureSubmitted(domainChainId, signer, domainBlockNumber, newStateRoot, domainAnchor, votes);

        // Advance exactly once, when the vote count first reaches quorum. The subsequent
        // stateNonce bump changes the digest, so this proposal can never be revisited.
        if (votes == config.quorum) {
            uint256 nonce = stateNonces[domainChainId]++;
            _commitments[domainChainId] = newStateRoot;
            if (domainAnchor != bytes32(0)) domainAnchors[domainChainId][domainAnchor] = true;
            domainBlockNumbers[domainChainId] = domainBlockNumber;
            emit DomainStateUpdated(domainChainId, nonce, domainBlockNumber, newStateRoot, domainAnchor);
        }
    }

    // ---------------------------------------------------------------------
    // Delivery of domain messages
    // ---------------------------------------------------------------------

    /// @notice One proof and replay boundary for every domain-origin message. The
    /// authenticated destination selects L1 execution or direct domain forwarding.
    function relayDomainMessage(MessageLib.DomainMessage calldata message, bytes32 anchor, bytes32[] calldata proof)
        external
        returns (bool success)
    {
        require(message.sourceChainId != message.destinationChainId, "DomainHub: same domain");
        require(_configs[message.sourceChainId].registered, "DomainHub: source not registered");
        bool encrypted = message.kind == MessageLib.MessageKind.Encrypted;
        if (encrypted) {
            require(message.to == address(0), "DomainHub: encrypted message with target");
            require(message.destinationChainId != block.chainid, "DomainHub: encrypted L1 callback");
        } else {
            require(message.to != address(0), "DomainHub: zero target");
        }
        bytes32 messageHash = MessageLib.hashDomainMessage(message, block.chainid, address(this));
        require(!relayedDomainMessages[message.sourceChainId][messageHash], "DomainHub: message already relayed");
        require(domainAnchors[message.sourceChainId][anchor], "DomainHub: unknown anchor");
        require(MerkleProof.verifyCalldata(proof, anchor, messageHash), "DomainHub: invalid proof");
        relayedDomainMessages[message.sourceChainId][messageHash] = true;

        if (message.destinationChainId != block.chainid) {
            require(_configs[message.destinationChainId].registered, "DomainHub: destination not registered");
            uint256 deliveryNonce = encrypted
                ? _sendEncryptedL1Message(message.destinationChainId, message.sourceChainId, message.from, message.data)
                : _sendL1Message(
                    message.destinationChainId, message.sourceChainId, message.from, message.to, message.data
                );
            emit DomainMessageRouted(messageHash, message.sourceChainId, message.destinationChainId, deliveryNonce);
            return true; // Queued atomically; destination execution happens asynchronously.
        }

        (success,) = message.to
            .call(
                abi.encodeCall(
                    IDomainMessageReceiver.onDomainMessage, (message.sourceChainId, message.from, message.data)
                )
            );
        if (!success) failedDomainMessages[message.sourceChainId][messageHash] = true;
        emit DomainMessageRelayed(
            message.sourceChainId, messageHash, message.from, message.to, message.sourceNonce, success
        );
    }

    function retryDomainMessage(MessageLib.DomainMessage calldata message) external {
        require(message.destinationChainId == block.chainid, "DomainHub: retry on destination domain");
        bytes32 messageHash = MessageLib.hashDomainMessage(message, block.chainid, address(this));
        require(failedDomainMessages[message.sourceChainId][messageHash], "DomainHub: not a failed message");
        delete failedDomainMessages[message.sourceChainId][messageHash];
        (bool success,) = message.to
            .call(
                abi.encodeCall(
                    IDomainMessageReceiver.onDomainMessage, (message.sourceChainId, message.from, message.data)
                )
            );
        require(success, "DomainHub: retry failed");
        emit DomainMessageRelayed(
            message.sourceChainId, messageHash, message.from, message.to, message.sourceNonce, true
        );
    }

    // ---------------------------------------------------------------------
    // Domain transactions: sequenced on the L1
    // ---------------------------------------------------------------------

    /// @notice Sequences a domain transaction through the L1. Forwards `msg.value` to the
    /// domain's fee recipient as a prepaid, non-refundable execution fee and emits the
    /// transaction for domain validators to include.
    function sequenceToDomain(uint64 domainChainId, bytes calldata rlpTx) external payable {
        DomainConfig storage config = _configs[domainChainId];
        require(config.registered, "DomainHub: domain not registered");

        (bool success,) = config.feeRecipient.call{value: msg.value}("");
        require(success, "DomainHub: fee transfer failed");
        emit DomainTransactionSequenced(domainChainId, rlpTx, msg.value);
    }

    // ---------------------------------------------------------------------
    // Messaging: L1 -> domain
    // ---------------------------------------------------------------------

    /// @notice Records a message to the target domain. The domain protocol derives this call's
    /// `L1MessageRecorded` event and delivers the message onto the spoke as a system transaction.
    function sendL1Message(uint64 domainChainId, address to, bytes calldata data) external {
        require(_configs[domainChainId].registered, "DomainHub: domain not registered");
        _sendL1Message(domainChainId, SafeCast.toUint64(block.chainid), msg.sender, to, data);
    }

    function _sendL1Message(uint64 domainChainId, uint64 sourceChainId, address from, address to, bytes memory data)
        internal
        returns (uint256 nonce)
    {
        nonce = l1MessageCounts[domainChainId]++;
        bytes32 messageHash = MessageLib.hashMessage(MessageLib.Message(sourceChainId, from, to, data, nonce));
        emit L1MessageRecorded(domainChainId, sourceChainId, from, to, data, nonce, messageHash);
    }

    /// @notice Records an encrypted message to the target domain. Draws from the same
    /// nonce sequence as `sendL1Message`. The client decrypts `abi.encodePacked(to, data)`
    /// out of `ciphertext` before deriving the system delivery transaction.
    function sendEncryptedL1Message(uint64 domainChainId, bytes calldata ciphertext) external {
        require(_configs[domainChainId].registered, "DomainHub: domain not registered");
        _sendEncryptedL1Message(domainChainId, SafeCast.toUint64(block.chainid), msg.sender, ciphertext);
    }

    function _sendEncryptedL1Message(uint64 domainChainId, uint64 sourceChainId, address from, bytes memory ciphertext)
        internal
        returns (uint256 nonce)
    {
        nonce = l1MessageCounts[domainChainId]++;
        emit EncryptedL1MessageRecorded(domainChainId, sourceChainId, from, ciphertext, nonce);
    }
}
