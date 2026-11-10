// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDomainSpoke, IDomainMessageReceiver} from "./interfaces/IDomain.sol";
import {IDomainAccessPolicy} from "./interfaces/IDomainAccessControl.sol";
import {MessageLib} from "./libraries/MessageLib.sol";

contract DomainSpoke is IDomainSpoke {
    error NotPolicyOwner();
    error NotPendingPolicyOwner();
    error NotSystemRelayer();
    error ZeroHub();
    error DomainIsL1();
    error L1ChainIdTooLarge();
    error ZeroPolicyOwner();
    error DeploymentFailed();
    error PolicyHasNoCode();
    error InvalidSelfPolicy();
    error InvalidSource();
    error OutOfOrderNonce();
    error NotFailedMessage();
    error RetryFailed();
    error SameDomain();
    error ZeroTarget();

    /// @notice Reserved sender of protocol-injected system transactions.
    address public constant SYSTEM_RELAYER = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;

    /// @notice Gas kept back from a delivery's target call so the spoke can still record a
    /// failed delivery for retry after the target exhausts everything it was given.
    uint256 public constant DELIVERY_GAS_RESERVE = 60_000;

    /// @notice Chain id of the domain this spoke serves.
    uint64 public immutable DOMAIN_CHAIN_ID;
    /// @notice L1 chain id bound into every outbound message ID.
    uint64 public immutable L1_CHAIN_ID;
    /// @notice Hub address bound into every outbound message ID.
    address public immutable HUB;

    // Storage layout: the domain RPC reads `policyOwners` (slot 2) and `logReaders` (slot 6)
    // directly from state, so these declarations must not be reordered.

    /// @notice Number of domain-origin messages recorded so far; the nonce the next one gets.
    uint256 public domainMessageCount;
    /// @notice Message ID of every recorded domain-origin message, by source nonce.
    mapping(uint256 => bytes32) public domainMessageIds;
    /// @notice Account that may name each contract's access policy; zero for contracts not
    /// deployed through `deployContract`.
    mapping(address => address) public policyOwners;
    /// @notice Policy deciding calls into each contract; zero admits every caller.
    mapping(address => address) public accessPolicies;
    /// @notice Minimum nonce the next delivered L1 -> domain message may carry.
    uint256 public nextL1Nonce;
    /// @notice Hashes of delivered messages whose target call failed; retryable via
    /// `retryL1Message`.
    mapping(bytes32 => bool) public failedL1Messages;
    /// @notice Accounts besides the policy owner that the domain RPC lets read every log of a
    /// contract.
    mapping(address => mapping(address => bool)) public logReaders;
    /// @notice Nominated policy owner per target; zero when no transfer is pending.
    mapping(address => address) public pendingPolicyOwners;

    modifier onlyPolicyOwner(address target) {
        address policyOwner = policyOwners[target];
        if (policyOwner == address(0) || msg.sender != policyOwner) revert NotPolicyOwner();
        _;
    }

    modifier onlySystem() {
        if (msg.sender != SYSTEM_RELAYER) revert NotSystemRelayer();
        _;
    }

    constructor(uint64 domainChainId, uint256 l1ChainId, address hub) {
        if (hub == address(0)) revert ZeroHub();
        if (domainChainId == l1ChainId) revert DomainIsL1();
        if (l1ChainId > type(uint64).max) revert L1ChainIdTooLarge();
        DOMAIN_CHAIN_ID = domainChainId;
        L1_CHAIN_ID = uint64(l1ChainId);
        HUB = hub;
    }

    // ---------------------------------------------------------------------
    // Contract deployment and access control
    // ---------------------------------------------------------------------

    function deployContract(bytes calldata initCode, address policyOwner) external returns (address deployed) {
        if (policyOwner == address(0)) revert ZeroPolicyOwner();
        bytes memory code = initCode;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        if (deployed == address(0) || deployed.code.length == 0) revert DeploymentFailed();
        policyOwners[deployed] = policyOwner;
        emit ContractDeployed(deployed, msg.sender, policyOwner);
    }

    /// @notice Nominate the next policy owner of `target`, replacing any pending nomination.
    /// @dev Only the current policy owner may nominate. It retains authority until acceptance;
    /// a zero `newOwner` cancels the pending transfer without changing the current owner.
    /// @param target Registered contract whose policy ownership is being transferred.
    /// @param newOwner Account that must accept the transfer, or zero to cancel it.
    function transferPolicyOwnership(address target, address newOwner) external onlyPolicyOwner(target) {
        pendingPolicyOwners[target] = newOwner;
        emit PolicyOwnershipTransferStarted(target, msg.sender, newOwner);
    }

    /// @notice Accept a pending policy ownership transfer for `target` as its nominated owner.
    /// @dev Clears the nomination and transfers authority without changing policies or reader grants.
    /// @param target Registered contract whose pending policy ownership the caller accepts.
    function acceptPolicyOwnership(address target) external {
        address pendingOwner = pendingPolicyOwners[target];
        if (pendingOwner == address(0) || msg.sender != pendingOwner) revert NotPendingPolicyOwner();
        address previousOwner = policyOwners[target];
        delete pendingPolicyOwners[target];
        policyOwners[target] = pendingOwner;
        emit PolicyOwnershipTransferred(target, previousOwner, pendingOwner);
    }

    function setAccessPolicy(address target, address policy) external onlyPolicyOwner(target) {
        if (policy != address(0) && policy.code.length == 0) revert PolicyHasNoCode();
        if (policy == address(this)) revert InvalidSelfPolicy();
        accessPolicies[target] = policy;
        emit AccessPolicySet(target, policy);
    }

    function setLogReader(address target, address reader, bool allowed) external onlyPolicyOwner(target) {
        logReaders[target][reader] = allowed;
        emit LogReaderSet(target, reader, allowed);
    }

    /// @notice Ask the policy named for `context`; no policy means allow.
    /// @dev Anything but a canonical ABI `true` denies, so a policy that reverts, runs out of
    /// gas or returns something else fails closed. Only one word of the answer is copied back.
    function canCall(address caller, address context, bytes calldata data) external view returns (bool) {
        address policy = accessPolicies[context];
        if (policy == address(0)) return true;
        bytes memory query = abi.encodeCall(IDomainAccessPolicy.canCall, (caller, context, data));
        bool ok;
        uint256 verdict;
        assembly ("memory-safe") {
            ok := staticcall(gas(), policy, add(query, 32), mload(query), 0, 32)
            ok := and(ok, eq(returndatasize(), 32))
            verdict := mload(0)
        }
        return ok && verdict == 1;
    }

    // ---------------------------------------------------------------------
    // Delivery of L1 messages (protocol system transactions)
    // ---------------------------------------------------------------------

    function relayL1Message(uint64 sourceChainId, address from, address to, bytes calldata data, uint256 nonce)
        external
        onlySystem
    {
        if (sourceChainId == DOMAIN_CHAIN_ID) revert InvalidSource();
        if (nonce < nextL1Nonce) revert OutOfOrderNonce();
        nextL1Nonce = nonce + 1;
        MessageLib.Message memory message = MessageLib.Message(sourceChainId, from, to, data, nonce);
        bytes32 messageHash = MessageLib.hashMessage(message);
        bool success = to.code.length != 0 && _callReceiver(message, DELIVERY_GAS_RESERVE);
        if (!success) failedL1Messages[messageHash] = true;
        emit L1MessageRelayed(messageHash, sourceChainId, from, to, nonce, success);
    }

    function retryL1Message(MessageLib.Message calldata message) external {
        bytes32 messageHash = MessageLib.hashMessage(message);
        if (!failedL1Messages[messageHash]) revert NotFailedMessage();
        delete failedL1Messages[messageHash];
        if (message.to.code.length == 0 || !_callReceiver(message, 0)) revert RetryFailed();
        emit L1MessageRelayed(messageHash, message.sourceChainId, message.from, message.to, message.nonce, true);
    }

    /// @dev Calls the target with every unit of gas but `gasReserve`, measured once the call
    /// data is built, and copies no return data, so nothing the target does can eat the reserve.
    function _callReceiver(MessageLib.Message memory message, uint256 gasReserve) internal returns (bool success) {
        bytes memory input =
            abi.encodeCall(IDomainMessageReceiver.onDomainMessage, (message.sourceChainId, message.from, message.data));
        address target = message.to;
        assembly ("memory-safe") {
            let budget := gas()
            if lt(budget, gasReserve) { revert(0, 0) }
            success := call(sub(budget, gasReserve), target, 0, add(input, 32), mload(input), 0, 0)
        }
    }

    // ---------------------------------------------------------------------
    // Domain-origin messaging (L1 execution or forwarding to another domain)
    // ---------------------------------------------------------------------

    function sendDomainMessage(uint64 destinationChainId, address to, bytes calldata data)
        external
        returns (bytes32 messageId)
    {
        if (destinationChainId == DOMAIN_CHAIN_ID) revert SameDomain();
        if (to == address(0)) revert ZeroTarget();
        uint256 sourceNonce = domainMessageCount++;
        MessageLib.DomainMessage memory message = MessageLib.DomainMessage({
            sourceChainId: DOMAIN_CHAIN_ID,
            destinationChainId: destinationChainId,
            from: msg.sender,
            to: to,
            sourceNonce: sourceNonce,
            data: data
        });
        messageId = MessageLib.hashDomainMessage(message, L1_CHAIN_ID, HUB);
        domainMessageIds[sourceNonce] = messageId;
        emit DomainMessageRecorded(messageId, abi.encode(message));
    }
}
