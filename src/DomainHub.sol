// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IDomainHub, IDomainMessageReceiver} from "./interfaces/IDomain.sol";
import {MessageLib} from "./libraries/MessageLib.sol";

contract DomainHub is IDomainHub {
    uint8 public constant MAX_STATE_VERIFICATION_MODE = 2;

    event DomainRegistered(uint64 indexed domainChainId, address indexed operator, uint8 stateVerificationMode);
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
        uint8 stateVerificationMode;
        address operator;
        uint256 quorum;
        address[] validators;
        mapping(address => bool) isValidator;
    }

    mapping(uint64 => DomainConfig) public domainConfigs;
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

    // ---------------------------------------------------------------------
    // Registration
    // ---------------------------------------------------------------------

    function registerDomain(
        uint64 domainChainId,
        uint8 stateVerificationMode,
        address[] calldata validators,
        uint256 quorum
    ) external {
        require(domainChainId != block.chainid, "DomainHub: cannot register L1 chain id");
        require(!domainConfigs[domainChainId].registered, "DomainHub: already registered");
        require(stateVerificationMode <= MAX_STATE_VERIFICATION_MODE, "DomainHub: unknown verification mode");
        require(quorum > 0, "DomainHub: zero quorum");
        require(quorum <= validators.length, "DomainHub: quorum exceeds validators");

        DomainConfig storage config = domainConfigs[domainChainId];
        config.registered = true;
        config.stateVerificationMode = stateVerificationMode;
        config.operator = msg.sender;
        config.quorum = quorum;
        for (uint256 i = 0; i < validators.length; i++) {
            address validator = validators[i];
            require(validator != address(0), "DomainHub: zero validator");
            require(!config.isValidator[validator], "DomainHub: duplicate validator");
            config.isValidator[validator] = true;
            config.validators.push(validator);
        }

        emit DomainRegistered(domainChainId, msg.sender, stateVerificationMode);
    }

    function getValidators(uint64 domainChainId) external view returns (address[] memory) {
        return domainConfigs[domainChainId].validators;
    }

    function isDomainValidator(uint64 domainChainId, address account) external view returns (bool) {
        return domainConfigs[domainChainId].isValidator[account];
    }

    // ---------------------------------------------------------------------
    // State commitments & domain -> L1 anchors
    // ---------------------------------------------------------------------

    function readCommitment(uint64 domainChainId) external view returns (bytes32) {
        return _commitments[domainChainId];
    }

    /// @notice The digest a domain validator signs to approve a state transition. Bound to
    /// this hub, the L1 chain, the domain, and the current `stateNonce` so a signature is
    /// valid for exactly one transition on one deployment. `domainBlockNumber` is part of
    /// the digest, so validators attest that `newStateRoot` is the state at that block.
    function stateTransitionDigest(
        uint64 domainChainId,
        uint64 domainBlockNumber,
        bytes32 newStateRoot,
        bytes32 domainAnchor
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                address(this),
                block.chainid,
                domainChainId,
                stateNonces[domainChainId],
                domainBlockNumber,
                newStateRoot,
                domainAnchor
            )
        );
    }

    /// @notice A validator submits its signature over a proposed state transition. Votes
    /// accumulate on-chain; the state does NOT advance until a distinct quorum of the
    /// domain's registered validators has signed the same
    /// `(domainBlockNumber, newStateRoot, domainAnchor)` for the current `stateNonce`.
    /// The quorum-th signature writes the new commitment, records `domainAnchor`, stores
    /// `domainBlockNumber`, and increments `stateNonce`.
    function submitStateSignature(
        uint64 domainChainId,
        uint64 domainBlockNumber,
        bytes32 newStateRoot,
        bytes32 domainAnchor,
        bytes calldata signature
    ) external {
        DomainConfig storage config = domainConfigs[domainChainId];
        require(config.registered, "DomainHub: domain not registered");
        require(domainBlockNumber > domainBlockNumbers[domainChainId], "DomainHub: stale block number");

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
            domainAnchors[domainChainId][domainAnchor] = true;
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
        require(domainConfigs[message.sourceChainId].registered, "DomainHub: source not registered");
        require(message.to != address(0), "DomainHub: zero target");
        bytes32 messageHash = MessageLib.hashDomainMessage(message, block.chainid, address(this));
        require(!relayedDomainMessages[message.sourceChainId][messageHash], "DomainHub: message already relayed");
        require(domainAnchors[message.sourceChainId][anchor], "DomainHub: unknown anchor");
        require(MerkleProof.verifyCalldata(proof, anchor, messageHash), "DomainHub: invalid proof");
        relayedDomainMessages[message.sourceChainId][messageHash] = true;

        if (message.destinationChainId != block.chainid) {
            require(domainConfigs[message.destinationChainId].registered, "DomainHub: destination not registered");
            uint256 deliveryNonce = _sendL1Message(
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
    /// domain operator as a prepaid, non-refundable execution fee and emits the transaction
    /// for domain validators to include.
    function sequenceToDomain(uint64 domainChainId, bytes calldata rlpTx) external payable {
        DomainConfig storage config = domainConfigs[domainChainId];
        require(config.registered, "DomainHub: domain not registered");

        (bool success,) = config.operator.call{value: msg.value}("");
        require(success, "DomainHub: fee transfer failed");
        emit DomainTransactionSequenced(domainChainId, rlpTx, msg.value);
    }

    // ---------------------------------------------------------------------
    // Messaging: L1 -> domain
    // ---------------------------------------------------------------------

    /// @notice Records a message to the target domain. The domain protocol derives this call's
    /// `L1MessageRecorded` event and delivers the message onto the spoke as a system transaction.
    function sendL1Message(uint64 domainChainId, address to, bytes calldata data) external {
        require(domainConfigs[domainChainId].registered, "DomainHub: domain not registered");
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
        require(domainConfigs[domainChainId].registered, "DomainHub: domain not registered");
        uint256 nonce = l1MessageCounts[domainChainId]++;
        emit EncryptedL1MessageRecorded(domainChainId, SafeCast.toUint64(block.chainid), msg.sender, ciphertext, nonce);
    }
}
