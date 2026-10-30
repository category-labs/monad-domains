// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDomainMessageReceiver, IDomainHub, IDomainSpoke} from "../src/interfaces/IDomain.sol";
import {MessageLib} from "../src/libraries/MessageLib.sol";
import {MerkleTreeLib} from "../src/libraries/MerkleTreeLib.sol";
import {DomainHub} from "../src/DomainHub.sol";
import {DomainSpoke} from "../src/DomainSpoke.sol";
import {DomainTestBase} from "./helpers/DomainTestBase.sol";

/// @notice Exercises the messaging layer directly: the hub (L1) and spoke (domain). The test
/// contract is the fee recipient. Checkpoint attestation is covered by DomainCheckpoint.t.sol.
contract DomainMessagingTest is DomainTestBase {
    uint64 internal constant CHAIN_ID = 7777;

    // Validator private keys of the registered set.
    uint256 internal constant K1 = 0xA11CE;
    uint256 internal constant K2 = 0xB0B;
    uint256 internal constant K3 = 0xC0DE;

    bytes internal constant VIEWING_KEY =
        hex"04d31f49ed035afc6c7045c4dd33b6485466fcf6021eb3e01a54a95cbc0b3e5399de67354267cc3cf62b8e933b932af6dfc19ce8e6be68d707c59873e6fb184a50";

    DomainHub internal hub;
    DomainSpoke internal spoke;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");
    address internal feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        hub = new DomainHub();
        _registerDomain(hub, CHAIN_ID, _keys(K1, K2, K3), 2);
        spoke = new DomainSpoke(CHAIN_ID, block.chainid, address(hub));
    }

    function _validators() internal pure returns (address[] memory) {
        return _addresses(_keys(K1, K2, K3));
    }

    function _register(uint64 chainId, address recipient, bytes memory viewingKey, uint64 interval) internal {
        hub.registerDomain(chainId, _validators(), 2, recipient, viewingKey, interval);
    }

    // ---------------------------------------------------------------------
    // Registration
    // ---------------------------------------------------------------------

    function test_register_rejectsL1ChainId() public {
        vm.expectRevert("DomainHub: cannot register L1 chain id");
        _register(uint64(block.chainid), feeRecipient, "", 1);
    }

    function test_register_rejectsDuplicate() public {
        vm.expectRevert("DomainHub: already registered");
        _register(CHAIN_ID, feeRecipient, "", 1);
    }

    function test_register_rejectsZeroQuorum() public {
        vm.expectRevert("DomainHub: zero quorum");
        hub.registerDomain(4444, _validators(), 0, feeRecipient, "", 1);
    }

    function test_register_rejectsQuorumAboveValidatorCount() public {
        vm.expectRevert("DomainHub: quorum exceeds validators");
        hub.registerDomain(4444, _validators(), 4, feeRecipient, "", 1);
    }

    function test_register_rejectsZeroValidator() public {
        address[] memory validators = new address[](1);
        validators[0] = address(0);
        vm.expectRevert("DomainHub: zero validator");
        hub.registerDomain(4444, validators, 1, feeRecipient, "", 1);
    }

    function test_register_rejectsDuplicateValidator() public {
        address[] memory validators = new address[](2);
        validators[0] = vm.addr(K1);
        validators[1] = vm.addr(K1);
        vm.expectRevert("DomainHub: duplicate validator");
        hub.registerDomain(4444, validators, 1, feeRecipient, "", 1);
    }

    function test_register_rejectsZeroFeeRecipient() public {
        vm.expectRevert("DomainHub: zero fee recipient");
        _register(4444, address(0), "", 1);
    }

    function test_register_rejectsZeroCheckpointInterval() public {
        vm.expectRevert("DomainHub: zero checkpoint interval");
        _register(4444, feeRecipient, "", 0);
    }

    function test_register_rejectsMalformedViewingKey() public {
        // Wrong length.
        vm.expectRevert("DomainHub: invalid viewing key");
        _register(4444, feeRecipient, hex"04c0ffee", 1);

        // Right length, not an uncompressed-point prefix.
        bytes memory compressedPrefix = VIEWING_KEY;
        compressedPrefix[0] = 0x02;
        vm.expectRevert("DomainHub: invalid viewing key");
        _register(4444, feeRecipient, compressedPrefix, 1);
    }

    function test_register_storesConfig() public {
        vm.expectEmit(true, true, false, true, address(hub));
        emit IDomainHub.DomainRegistered(4444, feeRecipient, 25);
        vm.expectEmit(true, false, false, true, address(hub));
        emit IDomainHub.ViewingKeyRegistered(4444, "");
        vm.prank(stranger); // registration is permissionless; the caller gets no role
        _register(4444, feeRecipient, "", 25);

        assertTrue(hub.isDomainRegistered(4444));
        assertFalse(hub.isDomainRegistered(5555));
        assertEq(hub.feeRecipients(4444), feeRecipient);
        assertEq(hub.checkpointIntervals(4444), 25);
        assertEq(hub.quorums(4444), 2);
        assertEq(hub.viewingKeys(4444), "");
        assertEq(hub.getValidators(4444).length, 3);
        assertTrue(hub.isDomainValidator(4444, vm.addr(K1)));
        assertTrue(hub.isDomainValidator(4444, vm.addr(K3)));
        assertFalse(hub.isDomainValidator(4444, stranger));
    }

    function test_register_publishesViewingKey() public {
        vm.expectEmit(true, false, false, true, address(hub));
        emit IDomainHub.ViewingKeyRegistered(4444, VIEWING_KEY);
        _register(4444, feeRecipient, VIEWING_KEY, 1);

        // Senders read the key from the hub to encrypt domain transactions to it.
        assertEq(hub.viewingKeys(4444), VIEWING_KEY);
        assertEq(hub.viewingKeys(4444).length, hub.VIEWING_KEY_LENGTH());
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
        bytes32 expectedHash = MessageLib.hashMessage(
            MessageLib.Message({sourceChainId: uint64(block.chainid), from: alice, to: bob, data: data, nonce: 0})
        );

        vm.expectEmit(address(hub));
        emit IDomainHub.L1MessageRecorded(CHAIN_ID, uint64(block.chainid), alice, bob, data, 0, expectedHash);
        vm.prank(alice);
        hub.sendL1Message(CHAIN_ID, bob, data);

        assertEq(hub.l1MessageCounts(CHAIN_ID), 1);
    }

    function test_sendL1Message_noncesArePerDomain() public {
        _register(4444, feeRecipient, "", 1);

        // Each domain assigns its own gapless nonce sequence, checked via the emitted
        // preimages.
        vm.expectEmit(address(hub));
        emit IDomainHub.L1MessageRecorded(
            CHAIN_ID,
            uint64(block.chainid),
            alice,
            bob,
            hex"01",
            0,
            MessageLib.hashMessage(MessageLib.Message(uint64(block.chainid), alice, bob, hex"01", 0))
        );
        vm.prank(alice);
        hub.sendL1Message(CHAIN_ID, bob, hex"01");

        vm.expectEmit(address(hub));
        emit IDomainHub.L1MessageRecorded(
            4444,
            uint64(block.chainid),
            alice,
            bob,
            hex"01",
            0,
            MessageLib.hashMessage(MessageLib.Message(uint64(block.chainid), alice, bob, hex"01", 0))
        );
        vm.prank(alice);
        hub.sendL1Message(4444, bob, hex"01");

        vm.expectEmit(address(hub));
        emit IDomainHub.L1MessageRecorded(
            CHAIN_ID,
            uint64(block.chainid),
            alice,
            bob,
            hex"01",
            1,
            MessageLib.hashMessage(MessageLib.Message(uint64(block.chainid), alice, bob, hex"01", 1))
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
        emit IDomainHub.EncryptedL1MessageRecorded(CHAIN_ID, uint64(block.chainid), alice, ciphertext, 0);
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
        emit IDomainHub.EncryptedL1MessageRecorded(CHAIN_ID, uint64(block.chainid), alice, hex"02", 1);
        vm.prank(alice);
        hub.sendEncryptedL1Message(CHAIN_ID, hex"02"); // nonce 1

        vm.expectEmit(address(hub));
        emit IDomainHub.L1MessageRecorded(
            CHAIN_ID,
            uint64(block.chainid),
            alice,
            bob,
            hex"03",
            2,
            MessageLib.hashMessage(MessageLib.Message(uint64(block.chainid), alice, bob, hex"03", 2))
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
        spoke.relayL1Message(uint64(block.chainid), alice, bob, hex"01", 0);
    }

    function test_relayL1Message_deliversInOrder() public {
        RecordingReceiver receiver = new RecordingReceiver();

        vm.startPrank(spoke.SYSTEM_RELAYER());
        spoke.relayL1Message(uint64(block.chainid), alice, address(receiver), hex"01", 0);
        spoke.relayL1Message(uint64(block.chainid), bob, address(receiver), hex"02", 1);
        vm.stopPrank();

        assertEq(spoke.nextL1Nonce(), 2);
        assertEq(receiver.callCount(), 2);
        assertEq(receiver.lastSource(), block.chainid);
        assertEq(receiver.lastFrom(), bob);
        assertEq(receiver.lastData(), hex"02");
    }

    function test_relayL1Message_rejectsReplayedOrRegressedNonce() public {
        vm.startPrank(spoke.SYSTEM_RELAYER());
        spoke.relayL1Message(uint64(block.chainid), alice, bob, hex"01", 3);

        // Nonces are strictly increasing: a delivered nonce cannot be replayed and no earlier
        // nonce can be delivered afterwards.
        vm.expectRevert("DomainSpoke: out-of-order nonce");
        spoke.relayL1Message(uint64(block.chainid), alice, bob, hex"01", 3);
        vm.expectRevert("DomainSpoke: out-of-order nonce");
        spoke.relayL1Message(uint64(block.chainid), alice, bob, hex"02", 1);
        vm.stopPrank();
    }

    function test_relayL1Message_toEOAFailsAndIsRetryable() public {
        vm.prank(spoke.SYSTEM_RELAYER());
        spoke.relayL1Message(uint64(block.chainid), alice, bob, hex"01", 0);
        assertEq(spoke.nextL1Nonce(), 1);
        assertTrue(
            spoke.failedL1Messages(
                MessageLib.hashMessage(MessageLib.Message(uint64(block.chainid), alice, bob, hex"01", 0))
            )
        );
    }

    function test_relayL1Message_marksFailedAndAdvancesQueue() public {
        RecordingReceiver receiver = new RecordingReceiver();
        receiver.setRejecting(true);
        MessageLib.Message memory message =
            MessageLib.Message(uint64(block.chainid), alice, address(receiver), hex"01", 0);
        bytes32 messageHash = MessageLib.hashMessage(message);

        vm.expectEmit(address(spoke));
        emit IDomainSpoke.L1MessageRelayed(messageHash, uint64(block.chainid), alice, address(receiver), 0, false);
        vm.prank(spoke.SYSTEM_RELAYER());
        spoke.relayL1Message(uint64(block.chainid), alice, address(receiver), hex"01", 0);

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
        vm.expectEmit(address(spoke));
        emit IDomainSpoke.L1MessageRelayed(messageHash, uint64(block.chainid), alice, address(receiver), 0, true);
        vm.prank(stranger);
        spoke.retryL1Message(message);
        assertFalse(spoke.failedL1Messages(messageHash));
        assertEq(receiver.callCount(), 1);
        assertEq(receiver.lastSource(), block.chainid);
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
        spoke.relayL1Message(uint64(block.chainid), alice, address(receiver), hex"01", 0);
        spoke.relayL1Message(uint64(block.chainid), bob, address(receiver), hex"02", 2);
        vm.stopPrank();

        assertEq(spoke.nextL1Nonce(), 3);
        assertEq(receiver.callCount(), 2);

        // The skipped nonce is consumed for good: it cannot be delivered afterwards.
        vm.prank(spoke.SYSTEM_RELAYER());
        vm.expectRevert("DomainSpoke: out-of-order nonce");
        spoke.relayL1Message(uint64(block.chainid), alice, address(receiver), hex"03", 1);
    }

    function test_retryL1Message_rejectsUnknownMessage() public {
        vm.expectRevert("DomainSpoke: not a failed message");
        spoke.retryL1Message(MessageLib.Message(uint64(block.chainid), alice, bob, hex"01", 0));
    }

    function test_deliverL1Messages_endToEnd() public {
        RecordingReceiver receiver = new RecordingReceiver();

        for (uint256 i = 0; i < 3; i++) {
            bytes memory data = abi.encodePacked(i);
            vm.prank(alice);
            hub.sendL1Message(CHAIN_ID, address(receiver), data);

            vm.prank(spoke.SYSTEM_RELAYER());
            spoke.relayL1Message(uint64(block.chainid), alice, address(receiver), data, i);
        }

        assertEq(hub.l1MessageCounts(CHAIN_ID), 3);
        assertEq(spoke.nextL1Nonce(), 3);
        assertEq(receiver.callCount(), 3);
        assertEq(receiver.lastData(), abi.encodePacked(uint256(2)));
    }

    // ---------------------------------------------------------------------
    // Domain -> L1
    // ---------------------------------------------------------------------

    function test_sendDomainMessage_recordsIdByNonceAndEmitsPreimage() public {
        MessageLib.DomainMessage memory message = MessageLib.DomainMessage(
            MessageLib.MessageKind.Plain, CHAIN_ID, uint64(block.chainid), alice, bob, 0, hex"cafe"
        );
        bytes32 expectedHash = MessageLib.hashDomainMessage(message, block.chainid, address(hub));

        vm.expectEmit(address(spoke));
        emit IDomainSpoke.DomainMessageRecorded(expectedHash, abi.encode(message));
        vm.prank(alice);
        bytes32 messageId = spoke.sendDomainMessage(uint64(block.chainid), bob, hex"cafe");

        assertEq(messageId, expectedHash);
        assertEq(spoke.domainMessageCount(), 1);
        assertEq(spoke.domainMessageIds(0), expectedHash);
    }

    function test_domainMessageIds_storedByNonceAndRootMatchesMerkleTree() public {
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            spoke.sendDomainMessage(uint64(block.chainid), bob, abi.encodePacked(i));
        }
        assertEq(spoke.domainMessageCount(), 5);

        // Each id is the hash of its envelope, keyed by nonce; an unrecorded nonce reads zero.
        bytes32[] memory all = _batchLeaves(spoke, 0, 5);
        for (uint256 i = 0; i < 5; i++) {
            MessageLib.DomainMessage memory message = MessageLib.DomainMessage(
                MessageLib.MessageKind.Plain, CHAIN_ID, uint64(block.chainid), alice, bob, i, abi.encodePacked(i)
            );
            assertEq(all[i], MessageLib.hashDomainMessage(message, block.chainid, address(hub)));
        }
        assertEq(spoke.domainMessageIds(5), bytes32(0));

        // The on-chain root matches the library over any range; one leaf is its own root.
        assertEq(spoke.domainMessagesRoot(0, 5), MerkleTreeLib.root(all));
        assertEq(spoke.domainMessagesRoot(2, 4), MerkleTreeLib.root(_batchLeaves(spoke, 2, 4)));
        assertEq(spoke.domainMessagesRoot(4, 5), all[4]);
        assertEq(spoke.domainMessagesRoot(3, 3), bytes32(0));
    }

    function test_domainMessagesRoot_rejectsInvalidRanges() public {
        vm.prank(alice);
        spoke.sendDomainMessage(uint64(block.chainid), bob, hex"01");

        vm.expectRevert("DomainSpoke: invalid range");
        spoke.domainMessagesRoot(1, 0);
        vm.expectRevert("DomainSpoke: range beyond recorded messages");
        spoke.domainMessagesRoot(0, 2);
    }

    // ---------------------------------------------------------------------
    // L1-sequenced domain transactions
    // ---------------------------------------------------------------------

    function test_sequenceToDomain_forwardsFeeAndEmits() public {
        _register(4444, feeRecipient, "", 1);
        vm.deal(alice, 1 ether);

        vm.expectEmit(address(hub));
        emit DomainHub.DomainTransactionSequenced(4444, hex"c0ffee", 0.1 ether);
        vm.prank(alice);
        hub.sequenceToDomain{value: 0.1 ether}(4444, hex"c0ffee");

        assertEq(feeRecipient.balance, 0.1 ether);
        assertEq(address(hub).balance, 0);
    }

    function test_sequenceToDomain_rejectsUnregisteredDomain() public {
        vm.expectRevert("DomainHub: domain not registered");
        hub.sequenceToDomain(9999, hex"01");
    }

    function test_sequenceToDomain_revertsIfFeeRecipientRejectsFee() public {
        address rejecting = address(new RejectingFeeRecipient());
        _register(4444, rejecting, "", 1);
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert("DomainHub: fee transfer failed");
        hub.sequenceToDomain{value: 0.1 ether}(4444, hex"01");
    }
}

/// @dev Fee recipient without a payable fallback: any fee forwarded to it reverts.
contract RejectingFeeRecipient {}

/// @dev Receiver that records what the spoke delivers, with a toggleable rejection mode to
/// exercise the failed-delivery path.
contract RecordingReceiver is IDomainMessageReceiver {
    uint256 public callCount;
    uint64 public lastSource;
    address public lastFrom;
    bytes public lastData;

    bool internal _rejecting;

    function setRejecting(bool rejecting) external {
        _rejecting = rejecting;
    }

    function onDomainMessage(uint64 sourceChainId, address from, bytes calldata data) external {
        require(!_rejecting, "RecordingReceiver: rejecting");
        callCount++;
        lastSource = sourceChainId;
        lastFrom = from;
        lastData = data;
    }
}
