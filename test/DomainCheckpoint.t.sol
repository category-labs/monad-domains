// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VmSafe} from "forge-std/Vm.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {DomainHub} from "../src/DomainHub.sol";
import {DomainSpoke} from "../src/DomainSpoke.sol";
import {MerkleTreeLib} from "../src/libraries/MerkleTreeLib.sol";
import {DomainTestBase} from "./helpers/DomainTestBase.sol";

/// @notice Checkpoint attestation on the hub: vote accumulation, the checkpoint schedule, the
/// anchors a quorum records, the typed digest, and the state-update event layout the domain
/// execution client decodes. CHAIN_ID has two validators with quorum 2.
contract DomainCheckpointTest is DomainTestBase {
    uint64 internal constant CHAIN_ID = 7777;
    uint256 internal constant K1 = 0xA11CE;
    uint256 internal constant K2 = 0xB0B;
    uint256 internal constant STRANGER_KEY = 0xBEEF;

    /// @dev Pinned by the execution client's scanner (private_domain_scanner.cpp).
    bytes32 internal constant DOMAIN_STATE_UPDATED_SIGNATURE =
        0x430254339a03e208e4f6cfb37d6928ba19f2f6315b1680dbecfba7e622f8c838;

    DomainHub internal hub;
    DomainSpoke internal spoke;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        hub = new DomainHub();
        _registerDomain(hub, CHAIN_ID, _keys(K1, K2), 2);
        spoke = new DomainSpoke(CHAIN_ID, block.chainid, address(hub));
        // Scheduled heights 10, 20, ... 90 are in the past from here on.
        vm.roll(100);
    }

    function _sig(uint64 blockNumber, bytes32 root, bytes32 anchor, uint256 key) internal view returns (bytes memory) {
        return _signTransition(hub, CHAIN_ID, blockNumber, root, anchor, key);
    }

    function _submit(uint64 blockNumber, bytes32 root, bytes32 anchor, uint256 key) internal {
        hub.submitStateSignature(CHAIN_ID, blockNumber, root, anchor, _sig(blockNumber, root, anchor, key));
    }

    // ---------------------------------------------------------------------
    // Votes
    // ---------------------------------------------------------------------

    function test_rejectsUnregisteredDomain() public {
        bytes memory sig = _signTransition(hub, 9999, 10, bytes32(0), bytes32(0), K1);
        vm.expectRevert("DomainHub: domain not registered");
        hub.submitStateSignature(9999, 10, bytes32(0), bytes32(0), sig);
    }

    function test_rejectsNonValidator() public {
        bytes memory sig = _sig(10, bytes32(0), bytes32(0), STRANGER_KEY);
        vm.expectRevert("DomainHub: not a validator");
        hub.submitStateSignature(CHAIN_ID, 10, bytes32(0), bytes32(0), sig);
    }

    function test_rejectsDoubleVote() public {
        _submit(10, bytes32(0), bytes32(0), K1);
        bytes memory sig = _sig(10, bytes32(0), bytes32(0), K1);
        vm.expectRevert("DomainHub: already voted");
        hub.submitStateSignature(CHAIN_ID, 10, bytes32(0), bytes32(0), sig);
    }

    function test_advancesOnlyAtQuorum() public {
        bytes32 root = keccak256("state root");
        bytes32 anchor = keccak256("anchor");
        bytes32 digest = hub.stateTransitionDigest(CHAIN_ID, 10, root, anchor);

        _submit(10, root, anchor, K1);
        assertEq(hub.stateVotes(digest), 1);
        assertEq(hub.readCommitment(CHAIN_ID), bytes32(0));
        assertFalse(hub.domainAnchors(CHAIN_ID, anchor));
        assertEq(hub.stateNonces(CHAIN_ID), 0);
        assertEq(hub.domainBlockNumbers(CHAIN_ID), 0);

        _submit(10, root, anchor, K2);
        assertEq(hub.readCommitment(CHAIN_ID), root);
        assertTrue(hub.domainAnchors(CHAIN_ID, anchor));
        assertEq(hub.stateNonces(CHAIN_ID), 1);
        assertEq(hub.domainBlockNumbers(CHAIN_ID), 10);
    }

    function test_votesForDifferentHeightsDoNotCombine() public {
        _submit(10, bytes32(0), bytes32(0), K1);
        _submit(20, bytes32(0), bytes32(0), K2);
        assertEq(hub.domainBlockNumbers(CHAIN_ID), 0);
        assertEq(hub.stateVotes(hub.stateTransitionDigest(CHAIN_ID, 10, bytes32(0), bytes32(0))), 1);
        assertEq(hub.stateVotes(hub.stateTransitionDigest(CHAIN_ID, 20, bytes32(0), bytes32(0))), 1);

        // Whichever proposal reaches quorum first wins; the other dies with the nonce bump.
        _submit(10, bytes32(0), bytes32(0), K2);
        assertEq(hub.domainBlockNumbers(CHAIN_ID), 10);
        assertEq(hub.stateVotes(hub.stateTransitionDigest(CHAIN_ID, 20, bytes32(0), bytes32(0))), 0);
    }

    function test_staleSignatureDoesNotReplayAfterAdvance() public {
        bytes memory staleSig = _sig(10, bytes32(0), bytes32(0), K1);
        hub.submitStateSignature(CHAIN_ID, 10, bytes32(0), bytes32(0), staleSig);
        _submit(10, bytes32(0), bytes32(0), K2);
        assertEq(hub.stateNonces(CHAIN_ID), 1);

        // Under the new nonce the old signature recovers to a non-validator.
        vm.expectRevert("DomainHub: not a validator");
        hub.submitStateSignature(CHAIN_ID, 20, bytes32(0), bytes32(0), staleSig);
    }

    // ---------------------------------------------------------------------
    // Schedule
    // ---------------------------------------------------------------------

    function test_rejectsOffScheduleBlockNumber() public {
        bytes memory sig = _sig(15, bytes32(0), bytes32(0), K1);
        vm.expectRevert("DomainHub: block number off schedule");
        hub.submitStateSignature(CHAIN_ID, 15, bytes32(0), bytes32(0), sig);
    }

    function test_rejectsBlockNumberNotInThePast() public {
        vm.roll(20);
        bytes memory sig = _sig(20, bytes32(0), bytes32(0), K1);
        vm.expectRevert("DomainHub: block number not in the past");
        hub.submitStateSignature(CHAIN_ID, 20, bytes32(0), bytes32(0), sig);

        // One L1 block later the height is in the past; finality is the validators' concern.
        vm.roll(21);
        _submit(20, bytes32(0), bytes32(0), K1);
        _submit(20, bytes32(0), bytes32(0), K2);
        assertEq(hub.domainBlockNumbers(CHAIN_ID), 20);
    }

    function test_heightsMustIncreaseButMaySkipSlots() public {
        _submit(10, bytes32(0), bytes32(0), K1);
        _submit(10, bytes32(0), bytes32(0), K2);

        // A domain that fell behind catches up with one checkpoint at any later slot.
        _submit(50, bytes32(0), bytes32(0), K1);
        _submit(50, bytes32(0), bytes32(0), K2);
        assertEq(hub.domainBlockNumbers(CHAIN_ID), 50);
        assertEq(hub.stateNonces(CHAIN_ID), 2);

        // At or below the committed height is stale.
        bytes memory sig = _sig(50, bytes32(0), bytes32(0), K1);
        vm.expectRevert("DomainHub: stale block number");
        hub.submitStateSignature(CHAIN_ID, 50, bytes32(0), bytes32(0), sig);
        sig = _sig(40, bytes32(0), bytes32(0), K1);
        vm.expectRevert("DomainHub: stale block number");
        hub.submitStateSignature(CHAIN_ID, 40, bytes32(0), bytes32(0), sig);
    }

    // ---------------------------------------------------------------------
    // Anchors
    // ---------------------------------------------------------------------

    function test_zeroAnchorIsNotRecorded() public {
        bytes32 root = keccak256("idle root");
        _submit(10, root, bytes32(0), K1);
        _submit(10, root, bytes32(0), K2);
        assertEq(hub.readCommitment(CHAIN_ID), root);
        assertEq(hub.domainBlockNumbers(CHAIN_ID), 10);
        assertFalse(hub.domainAnchors(CHAIN_ID, bytes32(0)));
    }

    function test_batchesFollowAttestationsAcrossIdleAndActivePeriods() public {
        // Batch 1: three messages, anchored at height 10.
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(alice);
            spoke.sendDomainMessage(uint64(block.chainid), bob, abi.encodePacked(i));
        }
        bytes32[] memory firstLeaves = _pendingLeaves(spoke);
        bytes32 firstAnchor = _attestBatch(hub, spoke, _keys(K1, K2));
        assertEq(firstAnchor, MerkleTreeLib.root(firstLeaves));
        assertTrue(hub.domainAnchors(CHAIN_ID, firstAnchor));
        assertFalse(hub.domainAnchors(8888, firstAnchor));

        // Idle period: the commitment advances with no messages and a zero anchor.
        assertEq(_attestBatch(hub, spoke, _keys(K1, K2)), bytes32(0));
        assertEq(hub.domainBlockNumbers(CHAIN_ID), 20);

        // Batch 2 only covers what was recorded since; earlier ids are never re-anchored.
        vm.prank(alice);
        spoke.sendDomainMessage(uint64(block.chainid), bob, hex"aa");
        vm.prank(alice);
        spoke.sendDomainMessage(uint64(block.chainid), bob, hex"bb");
        bytes32[] memory secondLeaves = _pendingLeaves(spoke);
        assertEq(secondLeaves.length, 2);
        assertEq(secondLeaves[0], spoke.domainMessageIds(3));
        bytes32 secondAnchor = _attestBatch(hub, spoke, _keys(K1, K2));
        assertEq(secondAnchor, MerkleTreeLib.root(secondLeaves));
        assertEq(hub.domainBlockNumbers(CHAIN_ID), 30);

        // Every message proves against its own batch's anchor, and only that one.
        for (uint256 i = 0; i < firstLeaves.length; i++) {
            assertTrue(MerkleProof.verify(MerkleTreeLib.getProof(firstLeaves, i), firstAnchor, firstLeaves[i]));
            assertFalse(MerkleProof.verify(MerkleTreeLib.getProof(firstLeaves, i), secondAnchor, firstLeaves[i]));
        }
        for (uint256 i = 0; i < secondLeaves.length; i++) {
            assertTrue(MerkleProof.verify(MerkleTreeLib.getProof(secondLeaves, i), secondAnchor, secondLeaves[i]));
        }
    }

    // ---------------------------------------------------------------------
    // Digest and event layout
    // ---------------------------------------------------------------------

    function test_digestIsEip712TypedHashBoundToHubAndChain() public view {
        bytes32 root = keccak256("root");
        bytes32 anchor = keccak256("anchor");
        assertEq(
            hub.STATE_TRANSITION_TYPEHASH(),
            keccak256(
                "StateTransition(uint64 domainChainId,uint256 stateNonce,uint64 domainBlockNumber,bytes32 newStateRoot,bytes32 domainAnchor)"
            )
        );
        bytes32 separator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("MonadDomainHub"),
                keccak256("1"),
                block.chainid,
                address(hub)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(hub.STATE_TRANSITION_TYPEHASH(), CHAIN_ID, hub.stateNonces(CHAIN_ID), uint64(10), root, anchor)
        );
        assertEq(
            hub.stateTransitionDigest(CHAIN_ID, 10, root, anchor),
            keccak256(abi.encodePacked("\x19\x01", separator, structHash))
        );
    }

    function test_domainStateUpdatedKeepsClientLayout() public {
        bytes32 root = keccak256("root");
        bytes32 anchor = keccak256("anchor");
        assertEq(keccak256("DomainStateUpdated(uint64,uint256,uint64,bytes32,bytes32)"), DOMAIN_STATE_UPDATED_SIGNATURE);

        _submit(10, root, anchor, K1);
        vm.recordLogs();
        _submit(10, root, anchor, K2);

        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != DOMAIN_STATE_UPDATED_SIGNATURE) continue;
            found = true;
            assertEq(logs[i].emitter, address(hub));
            assertEq(logs[i].topics.length, 2);
            assertEq(logs[i].topics[1], bytes32(uint256(CHAIN_ID)));
            // Four non-indexed words, in this order: stateNonce, domainBlockNumber, newStateRoot, domainAnchor.
            assertEq(logs[i].data.length, 4 * 32);
            (uint256 stateNonce, uint64 blockNumber, bytes32 newRoot, bytes32 newAnchor) =
                abi.decode(logs[i].data, (uint256, uint64, bytes32, bytes32));
            assertEq(stateNonce, 0);
            assertEq(blockNumber, 10);
            assertEq(newRoot, root);
            assertEq(newAnchor, anchor);
        }
        assertTrue(found);
    }
}
