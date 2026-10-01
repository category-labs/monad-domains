// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IL1MessageReceiver, IDomainSpoke} from "./interfaces/IDomain.sol";
import {MerkleTreeLib} from "./libraries/MerkleTreeLib.sol";
import {MessageLib} from "./libraries/MessageLib.sol";

/// @notice Domain-side spoke of the messaging layer, deployed on a domain (intended
/// as a protocol predeploy at a fixed address). Mirror image of the hub: it records outbound
/// domain -> L1 messages, and receives the L1 -> domain messages that the domain
/// protocol delivers as system transactions.
contract DomainSpoke is IDomainSpoke {
    /// @notice Reserved sender of protocol-injected system transactions.
    address public constant SYSTEM_RELAYER = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;

    /// @notice Gas forwarded to the target of a delivered message. Fixed so that delivery
    /// success is deterministic across every node executing the same system transaction.
    uint256 public constant DELIVERY_GAS_STIPEND = 2_000_000;

    /// @notice Chain id of the domain this spoke serves.
    uint64 public immutable DOMAIN_CHAIN_ID;

    /// @notice Account authorized to finalize domain -> L1 message batches.
    address public immutable OPERATOR;

    uint256 internal _nonce;
    bytes32[] internal _pendingDomainMessages;

    mapping(address => address) public policyOwners;
    mapping(address => mapping(bytes4 => AccessRule)) public accessControl;
    mapping(address => mapping(bytes4 => mapping(address => mapping(address => bool)))) public approvedReaders;

    /// @notice Minimum nonce the next delivered L1 -> domain message may carry.
    uint256 public nextL1Nonce;

    /// @notice Message hashes that were delivered but whose target call failed; retryable
    /// permissionlessly via `retryL1Message`.
    mapping(bytes32 => bool) public failedL1Messages;

    modifier onlyOperator() {
        require(msg.sender == OPERATOR, "DomainSpoke: not operator");
        _;
    }

    modifier onlyPolicyOwner(address target) {
        address policyOwner = policyOwners[target];
        require(policyOwner != address(0) && msg.sender == policyOwner, "DomainSpoke: not policy owner");
        _;
    }

    modifier onlySystem() {
        require(msg.sender == SYSTEM_RELAYER, "DomainSpoke: not system relayer");
        _;
    }

    constructor(uint64 domainChainId, address operator) {
        require(operator != address(0), "DomainSpoke: zero operator");
        DOMAIN_CHAIN_ID = domainChainId;
        OPERATOR = operator;
    }

    // ---------------------------------------------------------------------
    // Contract deployment and access control
    // ---------------------------------------------------------------------

    function deployContract(bytes calldata initCode, address policyOwner) external returns (address deployed) {
        require(policyOwner != address(0), "DomainSpoke: zero policy owner");
        bytes memory code = initCode;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        require(deployed != address(0) && deployed.code.length != 0, "DomainSpoke: deployment failed");
        policyOwners[deployed] = policyOwner;
        emit ContractDeployed(deployed, msg.sender, policyOwner);
    }

    function setAccessControl(address target, bytes4 selector, bool requireSubjectMatch, uint16 subjectArgumentIndex)
        external
        onlyPolicyOwner(target)
    {
        uint16 index = requireSubjectMatch ? subjectArgumentIndex : 0;
        accessControl[target][selector] = AccessRule(requireSubjectMatch, index);
        emit AccessControlSet(target, selector, requireSubjectMatch, index);
    }

    function setReaderAllowed(address target, bytes4 selector, address subject, address reader, bool allowed)
        external
        onlyPolicyOwner(target)
    {
        approvedReaders[target][selector][subject][reader] = allowed;
        emit ReaderAllowedSet(target, selector, subject, reader, allowed);
    }

    /// @notice Evaluate stored rules without executing the proposed call.
    /// @dev Check only the account whose storage is used, including during delegated
    /// execution. No restriction means allow.
    function canCall(address caller, address context, bytes calldata data) external view returns (bool) {
        bytes4 selector = data.length < 4 ? bytes4(0) : bytes4(data[:4]);
        return _checkAccess(caller, context, selector, data);
    }

    function _checkAccess(address caller, address target, bytes4 selector, bytes calldata data)
        internal
        view
        returns (bool)
    {
        AccessRule memory rule = accessControl[target][selector];
        if (!rule.requireSubjectMatch) return true;

        uint256 offset = 4 + uint256(rule.subjectArgumentIndex) * 32;
        if (data.length < offset + 32) return false;
        uint256 word;
        assembly ("memory-safe") {
            word := calldataload(add(data.offset, offset))
        }
        // Reject non-canonical ABI addresses rather than truncating their high bits.
        if (word > type(uint160).max) return false;
        // forge-lint: disable-next-line(unsafe-typecast)
        address subject = address(uint160(word));
        return caller == subject || approvedReaders[target][selector][subject][caller];
    }

    // ---------------------------------------------------------------------
    // Delivery of L1 messages (protocol system transactions)
    // ---------------------------------------------------------------------

    /// @notice Delivers one L1 -> domain message. Only callable from the protocol's system
    /// transactions; nonces must arrive strictly increasing, so every nonce is deliverable at
    /// most once. A gap is how the client skips an encrypted message whose ciphertext does not
    /// decrypt. A failing target marks the message failed instead of reverting.
    function relayL1Message(address from, address to, bytes calldata data, uint256 nonce) external onlySystem {
        require(nonce >= nextL1Nonce, "DomainSpoke: out-of-order nonce");
        nextL1Nonce = nonce + 1;

        bytes32 messageHash = MessageLib.hashMessage(MessageLib.Message(from, to, data, nonce));
        (bool success,) =
            to.call{gas: DELIVERY_GAS_STIPEND}(abi.encodeCall(IL1MessageReceiver.onL1Message, (from, data)));
        if (!success) failedL1Messages[messageHash] = true;
        emit L1MessageRelayed(messageHash, from, to, nonce, success);
    }

    /// @notice Permissionlessly re-executes a failed delivery with the caller's gas. Reverts if
    /// the target call fails again, which restores the failed mark.
    function retryL1Message(MessageLib.Message calldata message) external {
        bytes32 messageHash = MessageLib.hashMessage(message);
        require(failedL1Messages[messageHash], "DomainSpoke: not a failed message");
        delete failedL1Messages[messageHash];

        (bool success,) = message.to.call(abi.encodeCall(IL1MessageReceiver.onL1Message, (message.from, message.data)));
        require(success, "DomainSpoke: retry failed");
        emit L1MessageRelayed(messageHash, message.from, message.to, message.nonce, true);
    }

    // ---------------------------------------------------------------------
    // Messaging: domain -> L1
    // ---------------------------------------------------------------------

    function sendDomainMessage(address to, bytes calldata data) external {
        uint256 nonce = _nonce++;
        bytes32 messageHash = keccak256(abi.encodePacked(msg.sender, to, keccak256(data), nonce));
        _pendingDomainMessages.push(messageHash);
        emit DomainMessageRecorded(msg.sender, to, data, nonce, messageHash);
    }

    function pendingDomainMessages(uint256 index) external view returns (bytes32) {
        return _pendingDomainMessages[index];
    }

    function getPendingDomainMessages() external view returns (bytes32[] memory) {
        return _pendingDomainMessages;
    }

    /// @notice Operator merkleizes the pending domain -> L1 messages into an anchor and
    /// clears them. The operator relays the returned anchor onto the hub via
    /// `submitStateSignature`. Returns zero if nothing was pending.
    function finalizeDomainMessages() external onlyOperator returns (bytes32 anchor) {
        if (_pendingDomainMessages.length == 0) return bytes32(0);
        anchor = MerkleTreeLib.root(_pendingDomainMessages);
        delete _pendingDomainMessages;
    }
}
