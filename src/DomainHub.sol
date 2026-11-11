// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IDomainHub, IDomainMessageReceiver} from "./interfaces/IDomain.sol";
import {MessageLib} from "./libraries/MessageLib.sol";
import {InputQueue} from "./libraries/InputQueue.sol";

contract DomainHub is IDomainHub, EIP712 {
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

    /// @notice Words of each domain's input queue; an entry takes one word plus one per
    /// `INPUT_QUEUE_CHUNK` payload bytes.
    uint256 public constant INPUT_QUEUE_CAPACITY = InputQueue.CAPACITY;
    uint256 public constant INPUT_QUEUE_CHUNK = InputQueue.CHUNK;
    /// @notice Entry kinds of the input queue.
    uint8 public constant INPUT_TRANSACTION = 1;
    uint8 public constant INPUT_MESSAGE = 2;
    uint8 public constant INPUT_ENCRYPTED_MESSAGE = 3;
    /// @notice Kind of the entry that opens each domain block in the input queue.
    uint8 public constant INPUT_BLOCK = 4;
    /// @notice Contract that returns the L1 block's slot number (EIP-7843), or fails on an L1
    /// revision without it.
    address public immutable SLOT_NUMBER_PROBE;

    /// @dev Words of a domain's input queue page the hub keeps its per-input state in, so
    /// recording an input loads and writes that page and the data it appends, nothing else.
    /// `checkpointInterval(64) | feeRecipient(160)`: nonzero exactly when the domain is registered.
    uint256 internal constant SCHEDULE_WORD = 1;
    /// `blockNumber(64) | domainBlockNumber(64) | gasSold(128)`: the domain's latest block, the
    /// L1 block it is derived from, and the gas sold in that L1 block.
    uint256 internal constant BUDGET_WORD = 2;
    /// Next delivery nonce of the domain.
    uint256 internal constant MESSAGE_COUNT_WORD = 3;

    struct DomainConfig {
        /// @dev Distinct validator signatures required to advance the state.
        uint256 quorum;
        address[] validators;
        /// @dev Uncompressed P-256 point senders encrypt domain transactions to, or empty.
        bytes viewingKey;
        mapping(address => bool) isValidator;
    }

    /// @dev Registration of each domain, by chain id.
    mapping(uint64 => DomainConfig) internal _configs;
    /// @notice Latest attested state root of each domain.
    mapping(uint64 => bytes32) public stateRoots;
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

    constructor() EIP712("MonadDomainHub", "1") {
        // Runtime `SLOTNUM PUSH0 MSTORE PUSH1 32 PUSH0 RETURN`, behind the init code that
        // returns it. Solidity has no builtin for the opcode.
        bytes memory initCode = hex"664b5f5260205ff35f5260076019f3";
        address probe;
        assembly ("memory-safe") {
            probe := create(0, add(initCode, 32), mload(initCode))
        }
        require(probe != address(0), "DomainHub: slot number probe not deployed");
        SLOT_NUMBER_PROBE = probe;
    }

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
        uint256 queue = InputQueue.base(domainChainId);
        require(InputQueue.loadWord(queue, SCHEDULE_WORD) == 0, "DomainHub: already registered");
        require(quorum > 0, "DomainHub: zero quorum");
        require(quorum <= validators.length, "DomainHub: quorum exceeds validators");
        require(feeRecipient != address(0), "DomainHub: zero fee recipient");
        require(checkpointInterval > 0, "DomainHub: zero checkpoint interval");
        require(
            viewingKey.length == 0 || (viewingKey.length == VIEWING_KEY_LENGTH && viewingKey[0] == 0x04),
            "DomainHub: invalid viewing key"
        );

        InputQueue.storeWord(queue, SCHEDULE_WORD, (uint256(checkpointInterval) << 160) | uint160(feeRecipient));
        // The registering L1 block is the domain's block 0.
        InputQueue.storeWord(queue, BUDGET_WORD, block.number << 192);
        _recordBlock(queue, 0, _epoch(checkpointInterval));
        DomainConfig storage config = _configs[domainChainId];
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
        return _schedule(domainChainId) != 0;
    }

    function getValidators(uint64 domainChainId) external view returns (address[] memory) {
        return _configs[domainChainId].validators;
    }

    function quorums(uint64 domainChainId) external view returns (uint256) {
        return _configs[domainChainId].quorum;
    }

    function feeRecipients(uint64 domainChainId) external view returns (address) {
        return address(uint160(_schedule(domainChainId)));
    }

    function checkpointIntervals(uint64 domainChainId) external view returns (uint64) {
        return uint64(_schedule(domainChainId) >> 160);
    }

    function l1MessageCounts(uint64 domainChainId) external view returns (uint256) {
        return InputQueue.loadWord(InputQueue.base(domainChainId), MESSAGE_COUNT_WORD);
    }

    function _schedule(uint64 domainChainId) internal view returns (uint256) {
        return InputQueue.loadWord(InputQueue.base(domainChainId), SCHEDULE_WORD);
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
        uint64 checkpointInterval = uint64(_schedule(domainChainId) >> 160);
        require(checkpointInterval != 0, "DomainHub: domain not registered");
        require(domainBlockNumber > domainBlockNumbers[domainChainId], "DomainHub: stale block number");
        require(uint256(domainBlockNumber) < block.number, "DomainHub: block number not in the past");
        require(domainBlockNumber % checkpointInterval == 0, "DomainHub: block number off schedule");

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
            stateRoots[domainChainId] = newStateRoot;
            if (domainAnchor != bytes32(0)) domainAnchors[domainChainId][domainAnchor] = true;
            domainBlockNumbers[domainChainId] = domainBlockNumber;
            // The attested state covers every input up to this height: stop holding them.
            InputQueue.release(InputQueue.base(domainChainId), domainBlockNumber / checkpointInterval);
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
        require(message.sourceChainId != message.destinationChainId, "DomainHub: same domain");
        require(_schedule(message.sourceChainId) != 0, "DomainHub: source not registered");
        require(message.to != address(0), "DomainHub: zero target");
        bytes32 messageHash = MessageLib.hashDomainMessage(message, block.chainid, address(this));
        require(!relayedDomainMessages[message.sourceChainId][messageHash], "DomainHub: message already relayed");
        require(domainAnchors[message.sourceChainId][anchor], "DomainHub: unknown anchor");
        require(MerkleProof.verifyCalldata(proof, anchor, messageHash), "DomainHub: invalid proof");
        relayedDomainMessages[message.sourceChainId][messageHash] = true;

        if (message.destinationChainId != block.chainid) {
            require(_schedule(message.destinationChainId) != 0, "DomainHub: destination not registered");
            uint256 deliveryNonce = _sendL1Message(
                message.destinationChainId, message.sourceChainId, message.from, message.to, message.data, msg.value
            );
            emit DomainMessageRouted(messageHash, message.sourceChainId, message.destinationChainId, deliveryNonce);
            return true; // Queued atomically; destination execution happens asynchronously.
        }

        require(msg.value == 0, "DomainHub: fee on L1 callback");
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

    function sequenceToDomain(uint64 domainChainId, bytes calldata rlpTx) external payable {
        _recordInput(_registeredQueue(domainChainId), INPUT_TRANSACTION, msg.value, rlpTx);
        emit DomainTransactionSequenced(domainChainId, rlpTx, msg.value);
    }

    /// @dev The queue of a registered domain.
    function _registeredQueue(uint64 domainChainId) internal view returns (uint256 queue) {
        queue = InputQueue.base(domainChainId);
        require(InputQueue.loadWord(queue, SCHEDULE_WORD) != 0, "DomainHub: domain not registered");
    }

    /// @dev Charges `fee` against the domain's budget for this L1 block, appends the input to
    /// the domain's `queue` and pays the fee to the domain's fee recipient, who must accept it.
    /// The first input of an L1 block opens the domain's next block.
    function _recordInput(uint256 queue, uint8 kind, uint256 fee, bytes memory payload) internal {
        uint256 schedule = InputQueue.loadWord(queue, SCHEDULE_WORD);
        uint64 epoch = _epoch(schedule >> 160);

        uint256 budget = InputQueue.loadWord(queue, BUDGET_WORD);
        uint256 domainBlockNumber = uint64(budget >> 128);
        uint256 sold;
        if (budget >> 192 == block.number) {
            sold = uint128(budget);
        } else {
            domainBlockNumber++;
            _recordBlock(queue, uint64(domainBlockNumber), epoch);
        }
        sold += fee / DOMAIN_GAS_PRICE;
        require(sold <= DOMAIN_BLOCK_GAS_LIMIT, "DomainHub: domain block gas limit exceeded");
        InputQueue.storeWord(queue, BUDGET_WORD, (block.number << 192) | (domainBlockNumber << 128) | sold);

        // The budget above caps `fee` far below the 88 bits an entry holds.
        InputQueue.push(queue, kind, fee, payload, epoch);

        if (fee == 0) return;
        (bool success,) = address(uint160(schedule)).call{value: fee}("");
        require(success, "DomainHub: fee transfer failed");
    }

    /// @dev An L1 block belongs to the first scheduled checkpoint at or above it.
    function _epoch(uint256 checkpointInterval) internal view returns (uint64) {
        return uint64((block.number + checkpointInterval - 1) / checkpointInterval);
    }

    /// @dev Opens domain block `domainBlockNumber` in the queue with what its execution takes
    /// from this L1 block beyond the number and timestamp every entry carries: `prevrandao`,
    /// and the slot number on an L1 revision that has one.
    function _recordBlock(uint256 queue, uint64 domainBlockNumber, uint64 epoch) internal {
        bytes memory payload = abi.encodePacked(block.prevrandao, domainBlockNumber);
        // The probe's only opcode that can fail is SLOTNUM, which then takes all the gas it
        // was given.
        (bool success, bytes memory slotNumber) = SLOT_NUMBER_PROBE.staticcall{gas: 200}("");
        if (success && slotNumber.length == 32) {
            payload = bytes.concat(payload, bytes8(SafeCast.toUint64(abi.decode(slotNumber, (uint256)))));
        }
        InputQueue.push(queue, INPUT_BLOCK, 0, payload, epoch);
    }

    /// @dev Assigns the domain's next delivery nonce.
    function _nextMessageNonce(uint256 queue) internal returns (uint256 nonce) {
        nonce = InputQueue.loadWord(queue, MESSAGE_COUNT_WORD);
        InputQueue.storeWord(queue, MESSAGE_COUNT_WORD, nonce + 1);
    }

    function blockGas(uint64 domainChainId) external view returns (uint64 blockNumber, uint192 gasSold) {
        uint256 budget = InputQueue.loadWord(InputQueue.base(domainChainId), BUDGET_WORD);
        return (uint64(budget >> 192), uint128(budget));
    }

    function latestDomainBlock(uint64 domainChainId)
        external
        view
        returns (uint64 l1BlockNumber, uint64 domainBlockNumber)
    {
        uint256 budget = InputQueue.loadWord(InputQueue.base(domainChainId), BUDGET_WORD);
        return (uint64(budget >> 192), uint64(budget >> 128));
    }

    // ---------------------------------------------------------------------
    // Input queue
    // ---------------------------------------------------------------------

    function inputQueueBase(uint64 domainChainId) external pure returns (uint256) {
        return InputQueue.base(domainChainId);
    }

    function primeInputQueue(uint64 domainChainId, uint256 from, uint256 count) external {
        InputQueue.prime(_registeredQueue(domainChainId), from, count);
    }

    function inputQueueBounds(uint64 domainChainId) external view returns (uint64 head, uint64 tail) {
        return InputQueue.bounds(InputQueue.base(domainChainId));
    }

    function inputQueueEntry(uint64 domainChainId, uint64 index)
        external
        view
        returns (InputQueue.Entry memory entry, uint64 next)
    {
        return InputQueue.entryAt(InputQueue.base(domainChainId), index);
    }

    // ---------------------------------------------------------------------
    // Messaging: L1 -> domain
    // ---------------------------------------------------------------------

    function minDeliveryFee(uint256 dataLength) public pure returns (uint256) {
        return (DELIVERY_BASE_GAS + DELIVERY_GAS_PER_BYTE * dataLength) * DOMAIN_GAS_PRICE;
    }

    function sendL1Message(uint64 domainChainId, address to, bytes calldata data) external payable {
        _registeredQueue(domainChainId);
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
        require(fee >= minDeliveryFee(data.length), "DomainHub: delivery fee too low");
        uint256 queue = InputQueue.base(domainChainId);
        nonce = _nextMessageNonce(queue);
        _recordInput(queue, INPUT_MESSAGE, fee, abi.encodePacked(sourceChainId, from, to, uint64(nonce), data));
        bytes32 messageHash = MessageLib.hashMessage(MessageLib.Message(sourceChainId, from, to, data, nonce));
        emit L1MessageRecorded(domainChainId, sourceChainId, from, to, data, nonce, fee, messageHash);
    }

    function sendEncryptedL1Message(uint64 domainChainId, bytes calldata ciphertext) external payable {
        uint256 queue = _registeredQueue(domainChainId);
        require(msg.value >= minDeliveryFee(ciphertext.length), "DomainHub: delivery fee too low");
        uint256 nonce = _nextMessageNonce(queue);
        _recordInput(
            queue,
            INPUT_ENCRYPTED_MESSAGE,
            msg.value,
            abi.encodePacked(SafeCast.toUint64(block.chainid), msg.sender, uint64(nonce), ciphertext)
        );
        emit EncryptedL1MessageRecorded(
            domainChainId, SafeCast.toUint64(block.chainid), msg.sender, ciphertext, nonce, msg.value
        );
    }
}
