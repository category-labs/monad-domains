// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DomainHub} from "../../src/DomainHub.sol";
import {DomainSpoke} from "../../src/DomainSpoke.sol";
import {MerkleTreeLib} from "../../src/libraries/MerkleTreeLib.sol";

/// @notice Shared protocol steps for tests: registering a domain on the hub and attesting
/// state transitions the way validators do, on the domain's checkpoint schedule. A batch of
/// domain-origin messages is everything recorded since the last attestation; its root is the
/// anchor carried by the next attestation.
abstract contract DomainTestBase is Test {
    /// @dev Attested L1 heights must be multiples of this.
    uint64 internal constant CHECKPOINT_INTERVAL = 10;

    /// @dev `domainMessageCount` as of the last attestation per domain: the start of the
    /// next batch. Mirrors what a validator reads from the state at the previous checkpoint.
    mapping(uint64 => uint256) internal attestedMessageCounts;

    /// @dev Fee attached to test deliveries: above the hub's minimum for any test payload.
    uint256 internal constant DELIVERY_FEE = 0.1 ether;

    /// @dev Registered as every test domain's fee recipient.
    receive() external payable {}

    // ---------------------------------------------------------------------
    // Keys
    // ---------------------------------------------------------------------

    function _keys(uint256 key) internal pure returns (uint256[] memory keys) {
        keys = new uint256[](1);
        keys[0] = key;
    }

    function _keys(uint256 a, uint256 b) internal pure returns (uint256[] memory keys) {
        keys = new uint256[](2);
        keys[0] = a;
        keys[1] = b;
    }

    function _keys(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory keys) {
        keys = new uint256[](3);
        keys[0] = a;
        keys[1] = b;
        keys[2] = c;
    }

    function _addresses(uint256[] memory keys) internal pure returns (address[] memory validators) {
        validators = new address[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            validators[i] = vm.addr(keys[i]);
        }
    }

    // ---------------------------------------------------------------------
    // Registration
    // ---------------------------------------------------------------------

    /// @dev Registers `chainId` with the validators behind `keys`, the test contract as fee
    /// recipient, no viewing key and the shared checkpoint interval.
    function _registerDomain(DomainHub hub, uint64 chainId, uint256[] memory keys, uint256 quorum) internal {
        hub.registerDomain(chainId, _addresses(keys), quorum, address(this), "", CHECKPOINT_INTERVAL);
    }

    /// @dev Single validator, quorum 1.
    function _registerDomain(DomainHub hub, uint64 chainId, uint256 key) internal {
        _registerDomain(hub, chainId, _keys(key), 1);
    }

    // ---------------------------------------------------------------------
    // Attestation
    // ---------------------------------------------------------------------

    /// @dev The first scheduled height above the hub's latest attested one.
    function _nextCheckpointHeight(DomainHub hub, uint64 chainId) internal view returns (uint64) {
        uint64 interval = hub.checkpointIntervals(chainId);
        return (hub.domainBlockNumbers(chainId) / interval + 1) * interval;
    }

    /// @dev One validator's signature over the transition at the hub's current nonce.
    function _signTransition(DomainHub hub, uint64 chainId, uint64 l1Block, bytes32 root, bytes32 anchor, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hub.stateTransitionDigest(chainId, l1Block, root, anchor));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Attests `(l1Block, root, anchor)` with every key in turn, rolling the L1 past
    /// `l1Block` first so the height counts as final. Stops once the state advanced.
    function _attest(DomainHub hub, uint64 chainId, uint64 l1Block, bytes32 root, bytes32 anchor, uint256[] memory keys)
        internal
    {
        if (block.number <= l1Block) vm.roll(uint256(l1Block) + 1);
        for (uint256 i = 0; i < keys.length; i++) {
            hub.submitStateSignature(
                chainId, l1Block, root, anchor, _signTransition(hub, chainId, l1Block, root, anchor, keys[i])
            );
            if (hub.domainBlockNumbers(chainId) == l1Block) break;
        }
    }

    /// @dev Attests at the next scheduled height.
    function _attestNext(DomainHub hub, uint64 chainId, bytes32 root, bytes32 anchor, uint256[] memory keys)
        internal
        returns (uint64 l1Block)
    {
        l1Block = _nextCheckpointHeight(hub, chainId);
        _attest(hub, chainId, l1Block, root, anchor, keys);
    }

    // ---------------------------------------------------------------------
    // Batches
    // ---------------------------------------------------------------------

    /// @dev Message IDs with nonce in `[fromNonce, toNonce)`, the leaves of that batch.
    function _batchLeaves(DomainSpoke spoke, uint256 fromNonce, uint256 toNonce)
        internal
        view
        returns (bytes32[] memory leaves)
    {
        leaves = new bytes32[](toNonce - fromNonce);
        for (uint256 i = 0; i < leaves.length; i++) {
            leaves[i] = spoke.domainMessageIds(fromNonce + i);
        }
    }

    /// @dev Leaves of the batch an attestation would anchor now: everything recorded since
    /// the last attestation of this spoke's domain.
    function _pendingLeaves(DomainSpoke spoke) internal view returns (bytes32[] memory) {
        return _batchLeaves(spoke, attestedMessageCounts[spoke.DOMAIN_CHAIN_ID()], spoke.domainMessageCount());
    }

    /// @dev Anchors every message recorded since the last attestation at the next scheduled
    /// height, signed by `keys`. Returns the anchor (zero when nothing was recorded).
    function _attestBatch(DomainHub hub, DomainSpoke spoke, uint256[] memory keys) internal returns (bytes32 anchor) {
        bytes32[] memory leaves = _pendingLeaves(spoke);
        anchor = leaves.length == 0 ? bytes32(0) : MerkleTreeLib.root(leaves);
        _attestNext(hub, spoke.DOMAIN_CHAIN_ID(), bytes32(0), anchor, keys);
        attestedMessageCounts[spoke.DOMAIN_CHAIN_ID()] = spoke.domainMessageCount();
    }

    function _attestBatch(DomainHub hub, DomainSpoke spoke, uint256 key) internal returns (bytes32 anchor) {
        return _attestBatch(hub, spoke, _keys(key));
    }
}
