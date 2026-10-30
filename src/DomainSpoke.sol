// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDomainSpoke, IDomainMessageReceiver} from "./interfaces/IDomain.sol";
import {IDomainAccessPolicy} from "./interfaces/IDomainAccessControl.sol";
import {MerkleTreeLib} from "./libraries/MerkleTreeLib.sol";
import {MessageLib} from "./libraries/MessageLib.sol";

/// @notice Domain-side spoke of the messaging layer, deployed on a domain (intended
/// as a protocol predeploy at a fixed address). Mirror image of the hub: it records outbound
/// domain messages, and receives the L1 -> domain envelopes that the domain
/// protocol delivers as system transactions.
contract DomainSpoke is IDomainSpoke {
    /// @notice Reserved sender of protocol-injected system transactions.
    address public constant SYSTEM_RELAYER = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;

    /// @notice Gas forwarded to the target of a delivered message. Fixed so that delivery
    /// success is deterministic across every node executing the same system transaction.
    uint256 public constant DELIVERY_GAS_STIPEND = 2_000_000;

    /// @notice Chain id of the domain this spoke serves.
    uint64 public immutable DOMAIN_CHAIN_ID;
    /// @notice Protocol deployment binding outbound message IDs; the client authenticates inbound hub events.
    uint64 public immutable L1_CHAIN_ID;
    address public immutable HUB;

    /// @notice Number of domain-origin messages recorded so far; the nonce the next one gets.
    uint256 public domainMessageCount;
    /// @notice Message ID of every recorded domain-origin message, by source nonce. Never
    /// cleared: an attested batch stays rebuildable from state alone.
    mapping(uint256 => bytes32) public domainMessageIds;

    /// @notice Who may name each deployed contract's access policy.
    mapping(address => address) public policyOwners;
    /// @notice Policy deciding calls into each contract; zero admits every caller.
    mapping(address => address) public accessPolicies;

    /// @notice Minimum nonce the next delivered L1 -> domain message may carry.
    uint256 public nextL1Nonce;

    /// @notice Message hashes that were delivered but whose target call failed; retryable
    /// permissionlessly via `retryL1Message`.
    mapping(bytes32 => bool) public failedL1Messages;

    mapping(address => mapping(address => bool)) public logReaders;

    modifier onlyPolicyOwner(address target) {
        address policyOwner = policyOwners[target];
        require(policyOwner != address(0) && msg.sender == policyOwner, "DomainSpoke: not policy owner");
        _;
    }

    modifier onlySystem() {
        require(msg.sender == SYSTEM_RELAYER, "DomainSpoke: not system relayer");
        _;
    }

    constructor(uint64 domainChainId, uint256 l1ChainId, address hub) {
        require(hub != address(0), "DomainSpoke: zero hub");
        require(domainChainId != l1ChainId, "DomainSpoke: domain is L1");
        require(l1ChainId <= type(uint64).max, "DomainSpoke: L1 chain id too large");
        DOMAIN_CHAIN_ID = domainChainId;
        L1_CHAIN_ID = uint64(l1ChainId);
        HUB = hub;
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

    function setAccessPolicy(address target, address policy) external onlyPolicyOwner(target) {
        require(policy == address(0) || policy.code.length != 0, "DomainSpoke: policy has no code");
        require(policy != address(this), "DomainSpoke: spoke cannot be its own policy");
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

    /// @notice Delivers one L1 -> domain message. Only callable from the protocol's system
    /// transactions; nonces must arrive strictly increasing, so every nonce is deliverable at
    /// most once. A gap is how the client skips an encrypted message whose ciphertext does not
    /// decrypt. A failing target marks the message failed instead of reverting.
    function relayL1Message(uint64 sourceChainId, address from, address to, bytes calldata data, uint256 nonce)
        external
        onlySystem
    {
        require(sourceChainId != DOMAIN_CHAIN_ID, "DomainSpoke: invalid source");
        require(nonce >= nextL1Nonce, "DomainSpoke: out-of-order nonce");
        nextL1Nonce = nonce + 1;
        MessageLib.Message memory message = MessageLib.Message(sourceChainId, from, to, data, nonce);
        bytes32 messageHash = MessageLib.hashMessage(message);
        bool success = to.code.length != 0 && _callReceiver(message, DELIVERY_GAS_STIPEND);
        if (!success) failedL1Messages[messageHash] = true;
        emit L1MessageRelayed(messageHash, sourceChainId, from, to, nonce, success);
    }

    /// @notice Retries the exact authenticated delivery with the caller's gas.
    function retryL1Message(MessageLib.Message calldata message) external {
        bytes32 messageHash = MessageLib.hashMessage(message);
        require(failedL1Messages[messageHash], "DomainSpoke: not a failed message");
        delete failedL1Messages[messageHash];
        require(message.to.code.length != 0 && _callReceiver(message, gasleft()), "DomainSpoke: retry failed");
        emit L1MessageRelayed(messageHash, message.sourceChainId, message.from, message.to, message.nonce, true);
    }

    function _callReceiver(MessageLib.Message memory message, uint256 gasLimit) internal returns (bool success) {
        (success,) = message.to.call{gas: gasLimit}(
            abi.encodeCall(IDomainMessageReceiver.onDomainMessage, (message.sourceChainId, message.from, message.data))
        );
    }

    // ---------------------------------------------------------------------
    // Domain-origin messaging (L1 execution or forwarding to another domain)
    // ---------------------------------------------------------------------

    function sendDomainMessage(uint64 destinationChainId, address to, bytes calldata data)
        external
        returns (bytes32 messageId)
    {
        require(destinationChainId != DOMAIN_CHAIN_ID, "DomainSpoke: same domain");
        require(to != address(0), "DomainSpoke: zero target");
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

    /// @notice Merkle root over the recorded message IDs with nonce in `[fromNonce, toNonce)`,
    /// in nonce order; zero for an empty range. A validator attesting L1 height `H` after the
    /// previously attested height `P` anchors the root over `[count(P), count(H))`, where
    /// `count(x)` is `domainMessageCount` in the domain state at `x`. Convenience view for
    /// small ranges: hashing happens in memory, so a large batch exceeds an `eth_call` gas cap;
    /// read `domainMessageIds` nonce by nonce and hash off-chain in that case.
    function domainMessagesRoot(uint256 fromNonce, uint256 toNonce) external view returns (bytes32) {
        require(fromNonce <= toNonce, "DomainSpoke: invalid range");
        require(toNonce <= domainMessageCount, "DomainSpoke: range beyond recorded messages");
        if (fromNonce == toNonce) return bytes32(0);
        bytes32[] memory leaves = new bytes32[](toNonce - fromNonce);
        for (uint256 i = 0; i < leaves.length; i++) {
            leaves[i] = domainMessageIds[fromNonce + i];
        }
        return MerkleTreeLib.root(leaves);
    }
}
