// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IDomainHub, IDomainMessageReceiver} from "./interfaces/IDomain.sol";
import {MessageLib} from "./libraries/MessageLib.sol";

contract DomainHub is IDomainHub, EIP712 {
    error L1ChainIdNotAllowed();
    error DomainAlreadyRegistered();
    error ZeroQuorum();
    error QuorumExceedsValidators();
    error ZeroFeeRecipient();
    error ZeroCheckpointInterval();
    error AttestationTimeoutBelowTwoIntervals();
    error InvalidViewingKey();
    error ZeroValidator();
    error DuplicateValidator();
    error DomainNotRegistered();
    error StaleBlockNumber();
    error BlockNumberNotInPast();
    error BlockNumberOffSchedule();
    error NotValidator();
    error AlreadyVoted();
    error SameDomain();
    error SourceNotRegistered();
    error ZeroTarget();
    error MessageAlreadyRelayed();
    error UnknownAnchor();
    error InvalidProof();
    error DestinationNotRegistered();
    error UnexpectedL1CallbackFee();
    error RetryOnDestinationDomain();
    error NotFailedMessage();
    error RetryFailed();
    error SequencingFeeTooLow();
    error DomainAttestationStalled();
    error DomainBlockGasLimitExceeded();
    error FeeTransferFailed();
    error DeliveryFeeTooLow();

    /// @notice EIP-712 type of the digest a validator signs to approve a state transition.
    bytes32 public constant STATE_TRANSITION_TYPEHASH = keccak256(
        "StateTransition(uint64 domainChainId,uint256 stateNonce,uint64 domainBlockNumber,bytes32 newStateRoot,bytes32 domainAnchor)"
    );
    /// @notice Length of an uncompressed SEC1 P-256 point: the only accepted viewing key encoding.
    uint256 public constant VIEWING_KEY_LENGTH = 65;
    /// @notice Price of one unit of domain gas, in wei; mirrored by the execution client.
    uint256 public constant DOMAIN_GAS_PRICE = 50 gwei;
    /// @notice Gas a delivery needs beyond its payload to run or be recorded as failed: the
    /// system transaction's intrinsic gas, the spoke's own work and its reserve.
    uint256 public constant DELIVERY_BASE_GAS = 200_000;
    /// @notice Gas a delivery needs per payload byte: the calldata floor (EIP-7623) and the
    /// spoke's copies.
    uint256 public constant DELIVERY_GAS_PER_BYTE = 48;
    /// @notice Most gas each domain may sell per L1 block, across sequencing and messages.
    uint256 public constant DOMAIN_BLOCK_GAS_LIMIT = 150_000_000;
    /// @notice Gas any transaction needs to execute at all: the least a sequencing call must buy.
    uint256 public constant TRANSACTION_BASE_GAS = 21_000;

    /// @notice Gas sold for a domain's current L1 block.
    struct BlockGasSales {
        /// @dev L1 block `gasSold` counts; any earlier block means nothing is sold yet in this one.
        uint64 blockNumber;
        /// @dev Domain gas bought by the fees paid in `blockNumber`.
        uint128 gasSold;
        /// @dev L1 block of the first sale since the domain's last quorum, or zero while every
        /// sale so far has been followed by one.
        uint64 backlogSince;
    }

    struct DomainConfig {
        // The first slot holds what every sale reads.
        bool registered;
        /// @dev Receives every fee paid for the domain.
        address feeRecipient;
        /// @dev L1 blocks a backlog of sales may stay open without a quorum before the domain
        /// stops selling gas.
        uint64 attestationTimeout;
        /// @dev Attested block numbers must be multiples of this interval.
        uint64 checkpointInterval;
        /// @dev Distinct validator signatures required to advance the state.
        uint256 quorum;
        address[] validators;
        /// @dev Uncompressed P-256 point senders encrypt domain transactions to, or empty.
        bytes viewingKey;
        mapping(address => bool) isValidator;
    }

    /// @dev Registration of each domain, by chain id.
    mapping(uint64 => DomainConfig) internal _configs;
    /// @notice Gas each domain has sold in the current L1 block, against `DOMAIN_BLOCK_GAS_LIMIT`.
    mapping(uint64 => BlockGasSales) public blockGasSales;
    /// @notice Latest attested state root of each domain.
    mapping(uint64 => bytes32) public stateRoots;
    /// @notice Next delivery nonce of each destination domain, shared by plaintext, encrypted
    /// and forwarded messages.
    mapping(uint64 => uint256) public l1MessageCounts;
    /// @notice Attested batch roots of domain-origin messages, by source domain.
    mapping(uint64 => mapping(bytes32 => bool)) public domainAnchors;
    /// @notice Domain-origin messages already relayed, by source domain.
    mapping(uint64 => mapping(bytes32 => bool)) public relayedDomainMessages;
    /// @notice L1 callbacks that failed and await a successful retry, by source domain.
    mapping(uint64 => mapping(bytes32 => bool)) public failedDomainMessages;
    /// @notice Monotonic per-domain transition counter bound into every digest, so a round's
    /// signatures cannot be replayed against a later transition.
    mapping(uint64 => uint256) public stateNonces;
    /// @notice Domain block number of the latest attested state root; strictly increasing.
    mapping(uint64 => uint64) public domainBlockNumbers;
    /// @notice Votes accumulated for a proposal, keyed by its `stateTransitionDigest`.
    mapping(bytes32 => uint256) public stateVotes;
    /// @notice Whether a validator has already voted for a proposal digest.
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
        uint64 checkpointInterval,
        uint64 attestationTimeout
    ) external {
        if (domainChainId == block.chainid) revert L1ChainIdNotAllowed();
        DomainConfig storage config = _configs[domainChainId];
        if (config.registered) revert DomainAlreadyRegistered();
        if (quorum == 0) revert ZeroQuorum();
        if (quorum > validators.length) revert QuorumExceedsValidators();
        if (feeRecipient == address(0)) revert ZeroFeeRecipient();
        if (checkpointInterval == 0) revert ZeroCheckpointInterval();
        if (attestationTimeout < 2 * uint256(checkpointInterval)) revert AttestationTimeoutBelowTwoIntervals();
        if (viewingKey.length != 0 && (viewingKey.length != VIEWING_KEY_LENGTH || viewingKey[0] != 0x04)) {
            revert InvalidViewingKey();
        }

        config.registered = true;
        config.checkpointInterval = checkpointInterval;
        config.attestationTimeout = attestationTimeout;
        config.feeRecipient = feeRecipient;
        config.quorum = quorum;
        config.viewingKey = viewingKey;
        for (uint256 i = 0; i < validators.length; i++) {
            address validator = validators[i];
            if (validator == address(0)) revert ZeroValidator();
            if (config.isValidator[validator]) revert DuplicateValidator();
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

    function quorums(uint64 domainChainId) external view returns (uint256) {
        return _configs[domainChainId].quorum;
    }

    function feeRecipients(uint64 domainChainId) external view returns (address) {
        return _configs[domainChainId].feeRecipient;
    }

    function checkpointIntervals(uint64 domainChainId) external view returns (uint64) {
        return _configs[domainChainId].checkpointInterval;
    }

    function attestationTimeouts(uint64 domainChainId) external view returns (uint64) {
        return _configs[domainChainId].attestationTimeout;
    }

    function viewingKeys(uint64 domainChainId) external view returns (bytes memory) {
        return _configs[domainChainId].viewingKey;
    }

    // ---------------------------------------------------------------------
    // State attestation
    // ---------------------------------------------------------------------

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
        if (!config.registered) revert DomainNotRegistered();
        if (domainBlockNumber <= domainBlockNumbers[domainChainId]) revert StaleBlockNumber();
        if (uint256(domainBlockNumber) >= block.number) revert BlockNumberNotInPast();
        if (domainBlockNumber % config.checkpointInterval != 0) revert BlockNumberOffSchedule();

        bytes32 digest = stateTransitionDigest(domainChainId, domainBlockNumber, newStateRoot, domainAnchor);
        address signer = ECDSA.recover(digest, signature);
        if (!config.isValidator[signer]) revert NotValidator();
        if (hasVotedFor[digest][signer]) revert AlreadyVoted();

        hasVotedFor[digest][signer] = true;
        uint256 votes = ++stateVotes[digest];
        emit StateSignatureSubmitted(domainChainId, signer, domainBlockNumber, newStateRoot, domainAnchor, votes);

        // Advance exactly once, when the vote count first reaches quorum. The subsequent
        // stateNonce bump changes the digest, so this proposal can never be revisited.
        if (votes == config.quorum) {
            uint256 nonce = stateNonces[domainChainId]++;
            stateRoots[domainChainId] = newStateRoot;
            if (domainAnchor != bytes32(0)) domainAnchors[domainChainId][domainAnchor] = true;
            domainBlockNumbers[domainChainId] = domainBlockNumber;
            blockGasSales[domainChainId].backlogSince = 0;
            emit DomainStateUpdated(domainChainId, nonce, domainBlockNumber, newStateRoot, domainAnchor);
        }
    }

    // ---------------------------------------------------------------------
    // Delivery of domain messages
    // ---------------------------------------------------------------------

    function relayDomainMessage(MessageLib.DomainMessage calldata message, bytes32 anchor, bytes32[] calldata proof)
        external
        payable
        returns (bool success)
    {
        if (message.sourceChainId == message.destinationChainId) revert SameDomain();
        if (!_configs[message.sourceChainId].registered) revert SourceNotRegistered();
        if (message.to == address(0)) revert ZeroTarget();
        bytes32 messageHash = MessageLib.hashDomainMessage(message, block.chainid, address(this));
        if (relayedDomainMessages[message.sourceChainId][messageHash]) revert MessageAlreadyRelayed();
        if (!domainAnchors[message.sourceChainId][anchor]) revert UnknownAnchor();
        if (!MerkleProof.verifyCalldata(proof, anchor, messageHash)) revert InvalidProof();
        relayedDomainMessages[message.sourceChainId][messageHash] = true;

        if (message.destinationChainId != block.chainid) {
            if (!_configs[message.destinationChainId].registered) revert DestinationNotRegistered();
            uint256 deliveryNonce = _sendL1Message(
                message.destinationChainId, message.sourceChainId, message.from, message.to, message.data, msg.value
            );
            emit DomainMessageRouted(messageHash, message.sourceChainId, message.destinationChainId, deliveryNonce);
            return true; // Queued atomically; destination execution happens asynchronously.
        }

        if (msg.value != 0) revert UnexpectedL1CallbackFee();
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
        if (message.destinationChainId != block.chainid) revert RetryOnDestinationDomain();
        bytes32 messageHash = MessageLib.hashDomainMessage(message, block.chainid, address(this));
        if (!failedDomainMessages[message.sourceChainId][messageHash]) revert NotFailedMessage();
        delete failedDomainMessages[message.sourceChainId][messageHash];
        (bool success,) = message.to
            .call(
                abi.encodeCall(
                    IDomainMessageReceiver.onDomainMessage, (message.sourceChainId, message.from, message.data)
                )
            );
        if (!success) revert RetryFailed();
        emit DomainMessageRelayed(
            message.sourceChainId, messageHash, message.from, message.to, message.sourceNonce, true
        );
    }

    // ---------------------------------------------------------------------
    // Domain transactions: sequenced on the L1
    // ---------------------------------------------------------------------

    function minSequencingFee() public pure returns (uint256) {
        return TRANSACTION_BASE_GAS * DOMAIN_GAS_PRICE;
    }

    function sequenceToDomain(uint64 domainChainId, bytes calldata rlpTx) external payable {
        if (!_configs[domainChainId].registered) revert DomainNotRegistered();
        if (msg.value < minSequencingFee()) revert SequencingFeeTooLow();
        _buyGas(domainChainId, msg.value);
        emit DomainTransactionSequenced(domainChainId, rlpTx, msg.value);
    }

    // ---------------------------------------------------------------------
    // Gas sales: every paying call, bounded per L1 block and by attestation
    // ---------------------------------------------------------------------

    /// @notice Whether the hub still sells gas to `domainChainId` as far as attestation goes:
    /// nothing was sold since its validators last reached quorum, or the first sale since is at
    /// most `attestationTimeout` blocks old. False for an unregistered domain.
    function isDomainLive(uint64 domainChainId) public view returns (bool) {
        DomainConfig storage config = _configs[domainChainId];
        uint64 since = blockGasSales[domainChainId].backlogSince;
        return config.registered && (since == 0 || block.number - since <= config.attestationTimeout);
    }

    /// @dev Counts the gas `fee` buys against the domain's budget for this L1 block and pays
    /// the fee to the domain's fee recipient, who must accept it. The first sale after a quorum
    /// opens the domain's attestation backlog; once that backlog has waited more than
    /// `attestationTimeout` blocks for the next quorum, nothing more is sold.
    function _buyGas(uint64 domainChainId, uint256 fee) internal {
        if (!isDomainLive(domainChainId)) revert DomainAttestationStalled();
        BlockGasSales memory domainSales = blockGasSales[domainChainId];
        uint256 sold = (domainSales.blockNumber == block.number ? domainSales.gasSold : 0) + fee / DOMAIN_GAS_PRICE;
        if (sold > DOMAIN_BLOCK_GAS_LIMIT) revert DomainBlockGasLimitExceeded();
        if (domainSales.backlogSince == 0) domainSales.backlogSince = uint64(block.number);
        blockGasSales[domainChainId] = BlockGasSales(uint64(block.number), uint128(sold), domainSales.backlogSince);
        (bool success,) = _configs[domainChainId].feeRecipient.call{value: fee}("");
        if (!success) revert FeeTransferFailed();
    }

    // ---------------------------------------------------------------------
    // Messaging: L1 -> domain
    // ---------------------------------------------------------------------

    function minDeliveryFee(uint256 dataLength) public pure returns (uint256) {
        return (DELIVERY_BASE_GAS + DELIVERY_GAS_PER_BYTE * dataLength) * DOMAIN_GAS_PRICE;
    }

    function sendL1Message(uint64 domainChainId, address to, bytes calldata data) external payable {
        if (!_configs[domainChainId].registered) revert DomainNotRegistered();
        _sendL1Message(domainChainId, SafeCast.toUint64(block.chainid), msg.sender, to, data, msg.value);
    }

    /// @dev Charges `fee` for the delivery, assigns the next delivery nonce of `domainChainId` and
    /// emits the message for the domain client to deliver.
    function _sendL1Message(
        uint64 domainChainId,
        uint64 sourceChainId,
        address from,
        address to,
        bytes memory data,
        uint256 fee
    ) internal returns (uint256 nonce) {
        if (fee < minDeliveryFee(data.length)) revert DeliveryFeeTooLow();
        _buyGas(domainChainId, fee);
        nonce = l1MessageCounts[domainChainId]++;
        bytes32 messageHash = MessageLib.hashMessage(MessageLib.Message(sourceChainId, from, to, data, nonce));
        emit L1MessageRecorded(domainChainId, sourceChainId, from, to, data, nonce, fee, messageHash);
    }

    function sendEncryptedL1Message(uint64 domainChainId, bytes calldata ciphertext) external payable {
        if (!_configs[domainChainId].registered) revert DomainNotRegistered();
        if (msg.value < minDeliveryFee(ciphertext.length)) revert DeliveryFeeTooLow();
        _buyGas(domainChainId, msg.value);
        uint256 nonce = l1MessageCounts[domainChainId]++;
        emit EncryptedL1MessageRecorded(
            domainChainId, SafeCast.toUint64(block.chainid), msg.sender, ciphertext, nonce, msg.value
        );
    }
}
