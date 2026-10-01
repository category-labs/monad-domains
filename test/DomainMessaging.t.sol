// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IL1MessageReceiver, IDomainHub, IDomainSpoke} from "../src/interfaces/IDomain.sol";
import {MessageLib} from "../src/libraries/MessageLib.sol";
import {MerkleTreeLib} from "../src/libraries/MerkleTreeLib.sol";
import {DomainHub} from "../src/DomainHub.sol";
import {DomainSpoke} from "../src/DomainSpoke.sol";

/// @notice Exercises the messaging layer directly: the hub (L1) and spoke (domain). The
/// test contract is the domain operator, and CHAIN_ID has a 3-validator set with quorum 2
/// that must sign to advance the domain state.
contract DomainMessagingTest is Test {
    uint64 internal constant CHAIN_ID = 7777;

    // Validator private keys (K1..K3 are the registered set; STRANGER_KEY is not).
    uint256 internal constant K1 = 0xA11CE;
    uint256 internal constant K2 = 0xB0B;
    uint256 internal constant K3 = 0xC0DE;
    uint256 internal constant STRANGER_KEY = 0xBEEF;

    DomainHub internal hub;
    DomainSpoke internal spoke;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");
    address internal operator = makeAddr("operator");

    function setUp() public {
        hub = new DomainHub();
        hub.registerDomain(CHAIN_ID, 0, _validators(), 2); // test contract is the operator
        spoke = new DomainSpoke(CHAIN_ID, address(this));
    }

    // ---------------------------------------------------------------------
    // Validator signing helpers
    // ---------------------------------------------------------------------

    function _validators() internal view returns (address[] memory vs) {
        vs = new address[](3);
        vs[0] = vm.addr(K1);
        vs[1] = vm.addr(K2);
        vs[2] = vm.addr(K3);
    }

    /// @dev One validator's signature over the `(blockNumber, root, anchor)` transition at the
    /// current nonce.
    function _sig(uint64 chainId, uint64 blockNumber, bytes32 root, bytes32 anchor, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hub.stateTransitionDigest(chainId, blockNumber, root, anchor));
        return abi.encodePacked(r, s, v);
    }

    // ---------------------------------------------------------------------
    // Registration
    // ---------------------------------------------------------------------

    function test_register_rejectsL1ChainId() public {
        vm.expectRevert("DomainHub: cannot register L1 chain id");
        hub.registerDomain(uint64(block.chainid), 0, _validators(), 2);
    }

    function test_register_rejectsDuplicate() public {
        vm.expectRevert("DomainHub: already registered");
        hub.registerDomain(CHAIN_ID, 1, _validators(), 2);
    }

    function test_register_rejectsUnknownVerificationMode() public {
        vm.expectRevert("DomainHub: unknown verification mode");
        hub.registerDomain(8888, 3, _validators(), 2);
    }

    function test_register_rejectsZeroQuorum() public {
        vm.expectRevert("DomainHub: zero quorum");
        hub.registerDomain(4444, 0, _validators(), 0);
    }

    function test_register_rejectsQuorumAboveValidatorCount() public {
        vm.expectRevert("DomainHub: quorum exceeds validators");
        hub.registerDomain(4444, 0, _validators(), 4);
    }

    function test_register_rejectsZeroValidator() public {
        address[] memory validators = new address[](1);
        validators[0] = address(0);
        vm.expectRevert("DomainHub: zero validator");
        hub.registerDomain(4444, 0, validators, 1);
    }

    function test_register_rejectsDuplicateValidator() public {
        address[] memory validators = new address[](2);
        validators[0] = vm.addr(K1);
        validators[1] = vm.addr(K1);
        vm.expectRevert("DomainHub: duplicate validator");
        hub.registerDomain(4444, 0, validators, 1);
    }

    function test_register_storesOperatorValidatorsAndQuorum() public {
        vm.expectEmit(true, true, false, true, address(hub));
        emit DomainHub.DomainRegistered(4444, operator, 1);
        vm.prank(operator);
        hub.registerDomain(4444, 1, _validators(), 2);

        (bool registered, uint8 stateVerificationMode, address configuredOperator, uint256 quorum) =
            hub.domainConfigs(4444);
        assertTrue(registered);
        assertEq(stateVerificationMode, 1);
        assertEq(configuredOperator, operator);
        assertEq(quorum, 2);
        assertEq(hub.getValidators(4444).length, 3);
        assertTrue(hub.isDomainValidator(4444, vm.addr(K1)));
        assertTrue(hub.isDomainValidator(4444, vm.addr(K3)));
        assertFalse(hub.isDomainValidator(4444, stranger));
    }

    // ---------------------------------------------------------------------
    // L1 -> domain
    // ---------------------------------------------------------------------

    function test_sendL1Message_rejectsUnregisteredDomain() public {
        vm.expectRevert("DomainHub: domain not registered");
        hub.sendL1Message(9999, bob, hex"01");
    }

    function test_sendL1Message_recordsHashAndEmitsPreimage() public {
        bytes memory data = MessageLib.encodeTransfer(bob, address(0x1234), 100 ether);
        bytes32 expectedHash = MessageLib.hashMessage(MessageLib.Message({from: alice, to: bob, data: data, nonce: 0}));

        vm.expectEmit(address(hub));
        emit IDomainHub.L1MessageRecorded(CHAIN_ID, alice, bob, data, 0, expectedHash);
        vm.prank(alice);
        hub.sendL1Message(CHAIN_ID, bob, data);

        assertEq(hub.l1MessageCounts(CHAIN_ID), 1);
    }

    function test_sendL1Message_noncesArePerDomain() public {
        hub.registerDomain(4444, 0, _validators(), 2);

        // Each domain assigns its own gapless nonce sequence, checked via the emitted
        // preimages.
        vm.expectEmit(address(hub));
        emit IDomainHub.L1MessageRecorded(
            CHAIN_ID, alice, bob, hex"01", 0, MessageLib.hashMessage(MessageLib.Message(alice, bob, hex"01", 0))
        );
        vm.prank(alice);
        hub.sendL1Message(CHAIN_ID, bob, hex"01");

        vm.expectEmit(address(hub));
        emit IDomainHub.L1MessageRecorded(
            4444, alice, bob, hex"01", 0, MessageLib.hashMessage(MessageLib.Message(alice, bob, hex"01", 0))
        );
        vm.prank(alice);
        hub.sendL1Message(4444, bob, hex"01");

        vm.expectEmit(address(hub));
        emit IDomainHub.L1MessageRecorded(
            CHAIN_ID, alice, bob, hex"01", 1, MessageLib.hashMessage(MessageLib.Message(alice, bob, hex"01", 1))
        );
        vm.prank(alice);
        hub.sendL1Message(CHAIN_ID, bob, hex"01");

        assertEq(hub.l1MessageCounts(CHAIN_ID), 2);
        assertEq(hub.l1MessageCounts(4444), 1);
    }

    function test_sendEncryptedL1Message_rejectsUnregisteredDomain() public {
        vm.expectRevert("DomainHub: domain not registered");
        hub.sendEncryptedL1Message(9999, hex"01");
    }

    function test_sendEncryptedL1Message_emitsCiphertextAndSender() public {
        // The hub treats the ciphertext as opaque bytes; any payload is recordable.
        bytes memory ciphertext = hex"c0ffee";

        vm.expectEmit(address(hub));
        emit IDomainHub.EncryptedL1MessageRecorded(CHAIN_ID, alice, ciphertext, 0);
        vm.prank(alice);
        hub.sendEncryptedL1Message(CHAIN_ID, ciphertext);

        assertEq(hub.l1MessageCounts(CHAIN_ID), 1);
    }

    function test_sendEncryptedL1Message_sharesNonceSequenceWithPlaintext() public {
        // Plaintext and encrypted messages interleave in one gapless per-domain ordering,
        // matching the spoke's in-order delivery requirement.
        vm.prank(alice);
        hub.sendL1Message(CHAIN_ID, bob, hex"01"); // nonce 0

        vm.expectEmit(address(hub));
        emit IDomainHub.EncryptedL1MessageRecorded(CHAIN_ID, alice, hex"02", 1);
        vm.prank(alice);
        hub.sendEncryptedL1Message(CHAIN_ID, hex"02"); // nonce 1

        vm.expectEmit(address(hub));
        emit IDomainHub.L1MessageRecorded(
            CHAIN_ID, alice, bob, hex"03", 2, MessageLib.hashMessage(MessageLib.Message(alice, bob, hex"03", 2))
        );
        vm.prank(alice);
        hub.sendL1Message(CHAIN_ID, bob, hex"03"); // nonce 2

        assertEq(hub.l1MessageCounts(CHAIN_ID), 3);
    }

    // ---------------------------------------------------------------------
    // Protocol delivery of L1 messages
    // ---------------------------------------------------------------------

    function test_relayL1Message_onlySystemRelayer() public {
        vm.prank(stranger);
        vm.expectRevert("DomainSpoke: not system relayer");
        spoke.relayL1Message(alice, bob, hex"01", 0);
    }

    function test_relayL1Message_deliversInOrder() public {
        RecordingReceiver receiver = new RecordingReceiver();

        vm.startPrank(spoke.SYSTEM_RELAYER());
        spoke.relayL1Message(alice, address(receiver), hex"01", 0);
        spoke.relayL1Message(bob, address(receiver), hex"02", 1);
        vm.stopPrank();

        assertEq(spoke.nextL1Nonce(), 2);
        assertEq(receiver.callCount(), 2);
        assertEq(receiver.lastFrom(), bob);
        assertEq(receiver.lastData(), hex"02");
    }

    function test_relayL1Message_rejectsReplayedOrRegressedNonce() public {
        vm.startPrank(spoke.SYSTEM_RELAYER());
        spoke.relayL1Message(alice, bob, hex"01", 3);

        // Nonces are strictly increasing: a delivered nonce cannot be replayed and no earlier
        // nonce can be delivered afterwards.
        vm.expectRevert("DomainSpoke: out-of-order nonce");
        spoke.relayL1Message(alice, bob, hex"01", 3);
        vm.expectRevert("DomainSpoke: out-of-order nonce");
        spoke.relayL1Message(alice, bob, hex"02", 1);
        vm.stopPrank();
    }

    function test_relayL1Message_toEOASucceedsVacuously() public {
        vm.prank(spoke.SYSTEM_RELAYER());
        spoke.relayL1Message(alice, bob, hex"01", 0);
        assertEq(spoke.nextL1Nonce(), 1);
        assertFalse(spoke.failedL1Messages(MessageLib.hashMessage(MessageLib.Message(alice, bob, hex"01", 0))));
    }

    function test_relayL1Message_marksFailedAndAdvancesQueue() public {
        RecordingReceiver receiver = new RecordingReceiver();
        receiver.setRejecting(true);
        MessageLib.Message memory message = MessageLib.Message(alice, address(receiver), hex"01", 0);
        bytes32 messageHash = MessageLib.hashMessage(message);

        vm.expectEmit(address(spoke));
        emit IDomainSpoke.L1MessageRelayed(messageHash, alice, address(receiver), 0, false);
        vm.prank(spoke.SYSTEM_RELAYER());
        spoke.relayL1Message(alice, address(receiver), hex"01", 0);

        // The failure is recorded and the queue moved past it.
        assertTrue(spoke.failedL1Messages(messageHash));
        assertEq(receiver.callCount(), 0);
        assertEq(spoke.nextL1Nonce(), 1);

        // Retry fails while the target still rejects; the failed mark is retained.
        vm.expectRevert("DomainSpoke: retry failed");
        spoke.retryL1Message(message);
        assertTrue(spoke.failedL1Messages(messageHash));

        // Once the target accepts, anyone can re-execute the delivery.
        receiver.setRejecting(false);
        vm.prank(stranger);
        spoke.retryL1Message(message);
        assertFalse(spoke.failedL1Messages(messageHash));
        assertEq(receiver.callCount(), 1);
        assertEq(receiver.lastFrom(), alice);

        // A retried message cannot be replayed.
        vm.expectRevert("DomainSpoke: not a failed message");
        spoke.retryL1Message(message);
    }

    function test_relayL1Message_gapSkipsUndeliverableNonce() public {
        RecordingReceiver receiver = new RecordingReceiver();

        // Nonce 1 is an undecryptable encrypted message: the client never delivers it, and
        // the delivery of nonce 2 consumes the gap.
        vm.startPrank(spoke.SYSTEM_RELAYER());
        spoke.relayL1Message(alice, address(receiver), hex"01", 0);
        spoke.relayL1Message(bob, address(receiver), hex"02", 2);
        vm.stopPrank();

        assertEq(spoke.nextL1Nonce(), 3);
        assertEq(receiver.callCount(), 2);

        // The skipped nonce is consumed for good: it cannot be delivered afterwards.
        vm.prank(spoke.SYSTEM_RELAYER());
        vm.expectRevert("DomainSpoke: out-of-order nonce");
        spoke.relayL1Message(alice, address(receiver), hex"03", 1);
    }

    function test_retryL1Message_rejectsUnknownMessage() public {
        vm.expectRevert("DomainSpoke: not a failed message");
        spoke.retryL1Message(MessageLib.Message(alice, bob, hex"01", 0));
    }

    function test_deliverL1Messages_endToEnd() public {
        RecordingReceiver receiver = new RecordingReceiver();

        for (uint256 i = 0; i < 3; i++) {
            bytes memory data = abi.encodePacked(i);
            vm.prank(alice);
            hub.sendL1Message(CHAIN_ID, address(receiver), data);

            vm.prank(spoke.SYSTEM_RELAYER());
            spoke.relayL1Message(alice, address(receiver), data, i);
        }

        assertEq(hub.l1MessageCounts(CHAIN_ID), 3);
        assertEq(spoke.nextL1Nonce(), 3);
        assertEq(receiver.callCount(), 3);
        assertEq(receiver.lastData(), abi.encodePacked(uint256(2)));
    }

    // ---------------------------------------------------------------------
    // Domain -> L1
    // ---------------------------------------------------------------------

    function test_sendDomainMessage_recordsHashAndEmitsPreimage() public {
        bytes32 expectedHash = MessageLib.hashMessage(MessageLib.Message(alice, bob, hex"cafe", 0));

        vm.expectEmit(address(spoke));
        emit IDomainSpoke.DomainMessageRecorded(alice, bob, hex"cafe", 0, expectedHash);
        vm.prank(alice);
        spoke.sendDomainMessage(bob, hex"cafe");

        assertEq(spoke.pendingDomainMessages(0), expectedHash);
    }

    function test_finalizeDomainMessages_onlyOperator() public {
        vm.prank(stranger);
        vm.expectRevert("DomainSpoke: not operator");
        spoke.finalizeDomainMessages();
    }

    // ---------------------------------------------------------------------
    // Multisig state verification (on-chain vote accumulation)
    // ---------------------------------------------------------------------

    function test_submitStateSignature_advancesOnlyAtQuorum() public {
        bytes32 newRoot = keccak256("state root");
        bytes32 anchor = keccak256("domain anchor");
        bytes32 digest = hub.stateTransitionDigest(CHAIN_ID, 100, newRoot, anchor);

        // First validator votes: quorum (2) not met, so the state MUST NOT advance.
        hub.submitStateSignature(CHAIN_ID, 100, newRoot, anchor, _sig(CHAIN_ID, 100, newRoot, anchor, K1));
        assertEq(hub.stateVotes(digest), 1);
        assertEq(hub.readCommitment(CHAIN_ID), bytes32(0));
        assertFalse(hub.domainAnchors(CHAIN_ID, anchor));
        assertEq(hub.stateNonces(CHAIN_ID), 0);
        assertEq(hub.domainBlockNumbers(CHAIN_ID), 0);

        // Second, distinct validator votes: quorum reached, state advances.
        hub.submitStateSignature(CHAIN_ID, 100, newRoot, anchor, _sig(CHAIN_ID, 100, newRoot, anchor, K2));
        assertEq(hub.readCommitment(CHAIN_ID), newRoot);
        assertTrue(hub.domainAnchors(CHAIN_ID, anchor));
        assertEq(hub.stateNonces(CHAIN_ID), 1);
        assertEq(hub.domainBlockNumbers(CHAIN_ID), 100);
    }

    function test_submitStateSignature_rejectsUnregisteredDomain() public {
        bytes memory sig = _sig(9999, 1, bytes32(0), keccak256("anchor"), K1);
        vm.expectRevert("DomainHub: domain not registered");
        hub.submitStateSignature(9999, 1, bytes32(0), keccak256("anchor"), sig);
    }

    function test_submitStateSignature_rejectsNonValidator() public {
        bytes32 anchor = keccak256("anchor");
        bytes memory sig = _sig(CHAIN_ID, 1, bytes32(0), anchor, STRANGER_KEY);
        vm.expectRevert("DomainHub: not a validator");
        hub.submitStateSignature(CHAIN_ID, 1, bytes32(0), anchor, sig);
    }

    function test_submitStateSignature_rejectsDoubleVote() public {
        bytes32 anchor = keccak256("anchor");
        hub.submitStateSignature(CHAIN_ID, 1, bytes32(0), anchor, _sig(CHAIN_ID, 1, bytes32(0), anchor, K1));

        bytes memory sig = _sig(CHAIN_ID, 1, bytes32(0), anchor, K1);
        vm.expectRevert("DomainHub: already voted");
        hub.submitStateSignature(CHAIN_ID, 1, bytes32(0), anchor, sig);
    }

    function test_submitStateSignature_rejectsStaleBlockNumber() public {
        bytes32 anchor = keccak256("anchor");
        // Commit block 5.
        hub.submitStateSignature(CHAIN_ID, 5, bytes32(0), anchor, _sig(CHAIN_ID, 5, bytes32(0), anchor, K1));
        hub.submitStateSignature(CHAIN_ID, 5, bytes32(0), anchor, _sig(CHAIN_ID, 5, bytes32(0), anchor, K2));
        assertEq(hub.domainBlockNumbers(CHAIN_ID), 5);

        // A proposal at or below the committed block number is rejected outright.
        bytes memory sig = _sig(CHAIN_ID, 5, bytes32(0), anchor, K1);
        vm.expectRevert("DomainHub: stale block number");
        hub.submitStateSignature(CHAIN_ID, 5, bytes32(0), anchor, sig);
    }

    function test_submitStateSignature_signaturesDoNotReplayAcrossTransitions() public {
        bytes32 anchor = keccak256("anchor");
        // Capture K1's signature over the round-0 digest before the round advances.
        bytes memory staleSig = _sig(CHAIN_ID, 1, bytes32(0), anchor, K1);

        // Advance the transition to quorum (bumps stateNonce to 1).
        hub.submitStateSignature(CHAIN_ID, 1, bytes32(0), anchor, staleSig);
        hub.submitStateSignature(CHAIN_ID, 1, bytes32(0), anchor, _sig(CHAIN_ID, 1, bytes32(0), anchor, K2));
        assertEq(hub.stateNonces(CHAIN_ID), 1);

        // Resubmitted for block 2, the round-0 signature recovers to a non-validator against
        // the round-1 digest.
        vm.expectRevert("DomainHub: not a validator");
        hub.submitStateSignature(CHAIN_ID, 2, bytes32(0), anchor, staleSig);
    }

    function test_consumeDomainMessage_endToEnd() public {
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            spoke.sendDomainMessage(bob, abi.encodePacked(i));
        }
        bytes32[] memory leaves = spoke.getPendingDomainMessages();
        bytes32 anchor = spoke.finalizeDomainMessages();
        assertEq(anchor, MerkleTreeLib.root(leaves));
        assertEq(spoke.getPendingDomainMessages().length, 0);

        // A quorum of validators votes the anchor (with the new state root) onto the hub.
        bytes32 root = keccak256("root");
        hub.submitStateSignature(CHAIN_ID, 1, root, anchor, _sig(CHAIN_ID, 1, root, anchor, K1));
        hub.submitStateSignature(CHAIN_ID, 1, root, anchor, _sig(CHAIN_ID, 1, root, anchor, K2));
        assertTrue(hub.domainAnchors(CHAIN_ID, anchor));

        // Anchors are keyed by chain id: a different domain must not accept it.
        assertFalse(hub.domainAnchors(8888, anchor));

        for (uint256 i = 0; i < leaves.length; i++) {
            bytes32[] memory proof = MerkleTreeLib.getProof(leaves, i);
            assertTrue(MerkleProof.verify(proof, anchor, leaves[i]));
        }
    }

    // ---------------------------------------------------------------------
    // L1-sequenced domain transactions
    // ---------------------------------------------------------------------

    function test_sequenceToDomain_forwardsFeeAndEmits() public {
        vm.prank(operator);
        hub.registerDomain(4444, 0, _validators(), 2);
        vm.deal(alice, 1 ether);

        vm.expectEmit(address(hub));
        emit DomainHub.DomainTransactionSequenced(4444, hex"c0ffee", 0.1 ether);
        vm.prank(alice);
        hub.sequenceToDomain{value: 0.1 ether}(4444, hex"c0ffee");

        assertEq(operator.balance, 0.1 ether);
        assertEq(address(hub).balance, 0);
    }

    function test_sequenceToDomain_rejectsUnregisteredDomain() public {
        vm.expectRevert("DomainHub: domain not registered");
        hub.sequenceToDomain(9999, hex"01");
    }

    function test_sequenceToDomain_revertsIfOperatorRejectsFee() public {
        address rejecting = address(new RejectingOperator());
        vm.prank(rejecting);
        hub.registerDomain(4444, 0, _validators(), 2);
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert("DomainHub: fee transfer failed");
        hub.sequenceToDomain{value: 0.1 ether}(4444, hex"01");
    }
}

/// @dev Operator without a payable fallback: any fee forwarded to it reverts.
contract RejectingOperator {}

/// @dev Receiver that records what the spoke delivers, with a toggleable rejection mode to
/// exercise the failed-delivery path.
contract RecordingReceiver is IL1MessageReceiver {
    uint256 public callCount;
    address public lastFrom;
    bytes public lastData;

    bool internal _rejecting;

    function setRejecting(bool rejecting) external {
        _rejecting = rejecting;
    }

    function onL1Message(address from, bytes calldata data) external {
        require(!_rejecting, "RecordingReceiver: rejecting");
        callCount++;
        lastFrom = from;
        lastData = data;
    }
}
