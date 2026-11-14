// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DomainAccessRules} from "../src/access/DomainAccessRules.sol";

import {Vm} from "forge-std/Test.sol";
import {IDomainHub, IDomainSpoke} from "../src/interfaces/IDomain.sol";
import {DomainHub} from "../src/DomainHub.sol";
import {DomainSpoke} from "../src/DomainSpoke.sol";
import {DomainBridge} from "../src/bridge/DomainBridge.sol";
import {MessageLib} from "../src/libraries/MessageLib.sol";
import {InputQueue} from "../src/libraries/InputQueue.sol";
import {MerkleTreeLib} from "./helpers/MerkleTreeLib.sol";
import {CrossDomainReceiver} from "./mocks/CrossDomainReceiver.sol";
import {MockDomainEncryption} from "./mocks/MockDomainEncryption.sol";
import {DomainTestBase} from "./helpers/DomainTestBase.sol";

/// @notice Domain -> domain messaging: the source spoke seals domain-bound messages through
/// the encryption precompile, the hub forwards only the ciphertext, and the destination client
/// (played here by the test) opens it into the delivery `relayL1Message` executes.
contract NativeRoutingTest is DomainTestBase {
    uint64 internal constant A = 7777;
    uint64 internal constant B = 8888;
    uint64 internal constant C = 9999;
    uint256 internal constant L1 = 1;
    uint256 internal constant KEY = 0xA11CE;
    DomainHub internal hub;
    DomainSpoke internal spokeA;
    DomainSpoke internal spokeB;
    MockDomainEncryption internal precompile;
    CrossDomainReceiver internal receiver;
    address internal alice = makeAddr("alice");
    bytes32 internal constant L1_EVENT =
        keccak256("L1MessageRecorded(uint64,uint64,address,address,bytes,uint256,uint256,bytes32)");
    bytes32 internal constant ENCRYPTED_L1_EVENT =
        keccak256("EncryptedL1MessageRecorded(uint64,uint64,uint256,bytes,uint256,uint256)");
    /// @dev Gas limit of a delivery whose fee bought this much gas.
    uint256 internal constant DELIVERY_GAS = 2_500_000;

    function setUp() public {
        vm.chainId(L1);
        hub = new DomainHub();
        _register(hub, A);
        _registerKeyedDomain(hub, B, KEY);
        _registerKeyedDomain(hub, C, KEY);
        spokeA = new DomainSpoke(A, L1, address(hub));
        spokeB = new DomainSpoke(B, L1, address(hub));
        receiver = new CrossDomainReceiver(address(spokeB), A, alice);
        precompile = _installEncryptionPrecompile();
        // Spoke A learns B's and C's keys from the hub before it can seal to them.
        _deliverViewingKey(hub, spokeA, B);
        _deliverViewingKey(hub, spokeA, C);
        vm.deal(makeAddr("relayer"), 100 ether);
        vm.deal(alice, 100 ether);
    }

    function _register(DomainHub h, uint64 chain) internal {
        _registerDomain(h, chain, KEY);
    }

    /// @dev Attests an arbitrary `anchor` for `source` at its next scheduled height.
    function _post(DomainHub h, uint64 source, bytes32 anchor) internal {
        _attestNext(h, source, bytes32(0), anchor, _keys(KEY));
    }

    function _send(address target, bytes memory data) internal returns (MessageLib.DomainMessage memory) {
        return _sendFrom(spokeA, B, target, data);
    }

    function _sendTo(uint64 destination, address target, bytes memory data)
        internal
        returns (MessageLib.DomainMessage memory)
    {
        return _sendFrom(spokeA, destination, target, data);
    }

    /// @dev Alice sends on `spoke`; the recorded envelope is read back from its event.
    function _sendFrom(DomainSpoke spoke, uint64 destination, address target, bytes memory data)
        internal
        returns (MessageLib.DomainMessage memory message)
    {
        vm.recordLogs();
        vm.chainId(spoke.DOMAIN_CHAIN_ID());
        vm.prank(alice);
        bytes32 id = spoke.sendDomainMessage(destination, target, data, TEST_SALT);
        vm.chainId(L1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        message = abi.decode(abi.decode(logs[0].data, (bytes)), (MessageLib.DomainMessage));
        assertEq(id, _id(message));
        assertEq(logs[0].topics[1], id);
        assertEq(spoke.domainMessageIds(message.sourceNonce), id);
    }

    function _id(MessageLib.DomainMessage memory message) internal view returns (bytes32) {
        return MessageLib.hashDomainMessage(message, L1, address(hub));
    }

    /// @dev Relays `message` with a fee and returns the delivery the destination client
    /// derives: the forwarded ciphertext opened, under the hub's delivery nonce.
    function _relay(MessageLib.DomainMessage memory message, bytes32 anchor, bytes32[] memory proof)
        internal
        returns (MessageLib.Message memory envelope)
    {
        vm.recordLogs();
        vm.prank(makeAddr("relayer"));
        assertTrue(hub.relayDomainMessage{value: DELIVERY_FEE}(message, anchor, proof));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hub)) continue;
            assertTrue(logs[i].topics[0] != L1_EVENT, "a forwarded message must not record a plaintext delivery");
            if (logs[i].topics[0] != ENCRYPTED_L1_EVENT) continue;
            assertFalse(found, "one delivery per route");
            found = true;
            assertEq(uint256(logs[i].topics[1]), message.destinationChainId);
            assertEq(uint256(logs[i].topics[2]), message.sourceChainId);
            (uint256 sourceNonce, bytes memory ciphertext, uint256 nonce,) =
                abi.decode(logs[i].data, (uint256, bytes, uint256, uint256));
            assertEq(sourceNonce, message.sourceNonce, "the event names the sealed message by its source nonce");
            assertEq(ciphertext, message.data, "the hub forwards the ciphertext untouched");
            (address from, address to, bytes memory data) = _openMessage(ciphertext);
            envelope = MessageLib.Message(message.sourceChainId, from, to, data, nonce);
        }
        assertTrue(found, "missing forwarded delivery event");
    }

    /// @dev Attests everything spoke A recorded since the last attestation as one batch and
    /// routes `message` (expected to be that batch's only leaf) through the hub.
    function _route(MessageLib.DomainMessage memory message) internal returns (MessageLib.Message memory) {
        return _relay(message, _attestBatch(hub, spokeA, KEY), new bytes32[](0));
    }

    function _deliver(MessageLib.Message memory envelope) internal {
        vm.chainId(B);
        vm.prank(spokeB.SYSTEM_RELAYER());
        spokeB.relayL1Message{gas: DELIVERY_GAS}(
            envelope.sourceChainId, envelope.from, envelope.to, envelope.data, envelope.nonce
        );
        vm.chainId(L1);
    }

    /// @dev Attests `forged` as a genuine leaf of A and checks the hub still rejects it.
    function _rejectAttested(MessageLib.DomainMessage memory forged, bytes4 error) internal {
        _post(hub, A, _id(forged));
        vm.expectRevert(error);
        hub.relayDomainMessage(forged, _id(forged), new bytes32[](0));
        assertFalse(hub.relayedDomainMessages(A, _id(forged)));
    }

    // ---------------------------------------------------------------------
    // Sealing on the source spoke
    // ---------------------------------------------------------------------

    function test_domainBoundSendIsSealedByThePrecompileAndNamesNobody() public {
        MessageLib.DomainMessage memory message = _send(address(receiver), hex"abcd");
        assertTrue(message.kind == MessageLib.MessageKind.Encrypted);
        assertEq(message.sourceChainId, A);
        assertEq(message.destinationChainId, B);
        assertEq(message.sourceNonce, 0);
        assertEq(message.from, address(0), "the envelope hides the sender");
        assertEq(message.to, address(0), "the envelope hides the target");

        // Sealed by spoke A, for B, under this envelope's nonce.
        (address sealer, uint64 destination, uint256 sequence, bytes32 keyHash, bytes memory plaintext) =
            precompile.openMessage(message.data);
        assertEq(sealer, address(spokeA));
        assertEq(destination, B);
        assertEq(sequence, 0);
        assertEq(keyHash, keccak256(hub.viewingKeys(B)), "sealed under B's registered key");
        assertEq(plaintext, MessageLib.encodePlaintext(alice, address(receiver), hex"abcd"));
        assertEq(precompile.seals(), 1);

        // The next envelope is sealed under the next nonce.
        MessageLib.DomainMessage memory next = _send(address(receiver), hex"");
        (,, sequence,,) = precompile.openMessage(next.data);
        assertEq(sequence, 1);
        assertEq(next.sourceNonce, 1);
    }

    function test_l1BoundSendStaysPlain() public {
        MessageLib.DomainMessage memory message = _sendTo(uint64(L1), address(receiver), hex"aa");
        assertTrue(message.kind == MessageLib.MessageKind.Plain);
        assertEq(message.from, alice);
        assertEq(message.to, address(receiver));
        assertEq(message.data, hex"aa");
        assertEq(precompile.seals(), 0, "nothing is sealed for the L1");
    }

    function test_sendRejectsSameDomainZeroTargetAndUnknownDestinationKey() public {
        vm.chainId(A);
        vm.startPrank(alice);
        vm.expectRevert(DomainSpoke.SameDomain.selector);
        spokeA.sendDomainMessage(A, address(receiver), hex"", TEST_SALT);
        vm.expectRevert(DomainSpoke.ZeroTarget.selector);
        spokeA.sendDomainMessage(B, address(0), hex"", TEST_SALT);
        // Spoke A holds no key for domain 1234.
        vm.expectRevert("MockDomainEncryption: unknown viewing key");
        spokeA.sendDomainMessage(1234, address(receiver), hex"", TEST_SALT);
        vm.stopPrank();
        vm.chainId(L1);
        assertEq(spokeA.domainMessageCount(), 0);
    }

    // ---------------------------------------------------------------------
    // Forwarding through the hub and delivery on the destination
    // ---------------------------------------------------------------------

    function test_routePreservesOriginAndDoesNotExecuteOnL1() public {
        MessageLib.DomainMessage memory message = _send(address(receiver), hex"1234");
        bytes32 anchor = _attestBatch(hub, spokeA, KEY);
        vm.expectEmit(address(hub));
        emit IDomainHub.EncryptedL1MessageRecorded(B, A, 0, message.data, 0, DELIVERY_FEE);
        vm.expectEmit(address(hub));
        emit IDomainHub.DomainMessageRouted(_id(message), A, B, 0);
        MessageLib.Message memory envelope = _relay(message, anchor, new bytes32[](0));
        assertEq(receiver.calls(), 0, "routing must not call application on L1");
        assertTrue(hub.relayedDomainMessages(A, _id(message)));
        assertEq(hub.l1MessageCounts(B), 1);

        // The delivery B's client derives from the opened ciphertext.
        assertEq(envelope.sourceChainId, A);
        assertEq(envelope.from, alice);
        assertEq(envelope.to, address(receiver));
        assertEq(envelope.data, hex"1234");
        assertEq(envelope.nonce, 0);
        vm.expectEmit(address(spokeB));
        emit IDomainSpoke.L1MessageRelayed(MessageLib.hashMessage(envelope), A, alice, address(receiver), 0, true);
        _deliver(envelope);
        assertEq(receiver.calls(), 1);
        assertEq(receiver.source(), A);
        assertEq(receiver.sender(), alice);
        assertEq(receiver.payload(), hex"1234");
        assertFalse(spokeB.failedL1Messages(MessageLib.hashMessage(envelope)));
        assertEq(spokeB.nextL1Nonce(), 1);
    }

    function test_sameSendAndRelayExecuteL1OrForwardAccordingToDestination() public {
        CrossDomainReceiver l1Receiver = new CrossDomainReceiver(address(hub), A, alice);
        MessageLib.DomainMessage memory local = _sendTo(uint64(L1), address(l1Receiver), hex"aa");
        MessageLib.DomainMessage memory remote = _send(address(receiver), hex"bb");
        bytes32[] memory leaves = _pendingLeaves(spokeA);
        bytes32 anchor = _attestBatch(hub, spokeA, KEY);
        assertTrue(hub.relayDomainMessage(local, anchor, MerkleTreeLib.getProof(leaves, 0)));
        assertEq(l1Receiver.calls(), 1);
        assertEq(l1Receiver.payload(), hex"aa");
        assertEq(hub.l1MessageCounts(B), 0);
        MessageLib.Message memory envelope = _relay(remote, anchor, MerkleTreeLib.getProof(leaves, 1));
        assertEq(hub.l1MessageCounts(B), 1);
        assertEq(receiver.calls(), 0);
        assertEq(l1Receiver.calls(), 1, "forwarding must not execute an L1 operation");
        vm.expectRevert(DomainHub.RetryOnDestinationDomain.selector);
        hub.retryDomainMessage(remote);
        _deliver(envelope);
        assertEq(receiver.calls(), 1);
        assertEq(receiver.payload(), hex"bb");
    }

    function test_unknownDestinationDoesNotConsumeAuthenticatedMessage() public {
        // Spoke A cannot seal to an unregistered domain, so this is a forgery A's validators
        // attested; the hub still does not consume it.
        MessageLib.DomainMessage memory message = MessageLib.DomainMessage({
            kind: MessageLib.MessageKind.Encrypted,
            sourceChainId: A,
            destinationChainId: 1234,
            from: address(0),
            to: address(0),
            sourceNonce: 0,
            salt: bytes32(0),
            data: hex"c0ffee"
        });
        _post(hub, A, _id(message));
        vm.expectRevert(DomainHub.DestinationNotRegistered.selector);
        hub.relayDomainMessage(message, _id(message), new bytes32[](0));
        assertFalse(hub.relayedDomainMessages(A, _id(message)));
    }

    function test_rejectsUnknownSourceDestinationSameChainAndNonCanonicalShapes() public {
        MessageLib.DomainMessage memory message = _send(address(receiver), hex"");
        message.sourceChainId = 1234;
        vm.expectRevert(DomainHub.SourceNotRegistered.selector);
        hub.relayDomainMessage(message, bytes32(0), new bytes32[](0));
        message.sourceChainId = A;
        message.destinationChainId = 1234;
        vm.expectRevert(DomainHub.UnknownAnchor.selector);
        hub.relayDomainMessage(message, bytes32(0), new bytes32[](0));
        message.destinationChainId = A;
        vm.expectRevert(DomainHub.SameDomain.selector);
        hub.relayDomainMessage(message, bytes32(0), new bytes32[](0));
        message.destinationChainId = B;
        message.to = address(receiver);
        vm.expectRevert(DomainHub.EncryptedMessageWithTarget.selector);
        hub.relayDomainMessage(message, bytes32(0), new bytes32[](0));
        message.to = address(0);
        message.from = alice;
        vm.expectRevert(DomainHub.EncryptedMessageWithSender.selector);
        hub.relayDomainMessage(message, bytes32(0), new bytes32[](0));
        message.from = address(0);
        message.kind = MessageLib.MessageKind.Plain;
        vm.expectRevert(DomainHub.PlaintextDomainMessage.selector);
        hub.relayDomainMessage(message, bytes32(0), new bytes32[](0));
    }

    function test_registeredDomainNeedsNoSpokeRegistration() public {
        MessageLib.DomainMessage memory message = _sendTo(C, address(receiver), hex"");
        bytes32 anchor = _attestBatch(hub, spokeA, KEY);
        MessageLib.Message memory envelope = _relay(message, anchor, new bytes32[](0));
        assertTrue(hub.relayedDomainMessages(A, _id(message)));
        assertEq(hub.l1MessageCounts(C), 1);
        assertEq(envelope.to, address(receiver));
    }

    function testFuzz_reverseOrderRoutingAndRetriesExecuteEachMessageOnce(uint8 count, uint256 failures) public {
        count = uint8(bound(count, 1, 8));
        MessageLib.DomainMessage[] memory messages = new MessageLib.DomainMessage[](count);
        MessageLib.Message[] memory envelopes = new MessageLib.Message[](count);
        for (uint256 i; i < count; ++i) {
            messages[i] = _send(address(receiver), abi.encode(i));
        }
        bytes32[] memory leaves = _pendingLeaves(spokeA);
        bytes32 anchor = _attestBatch(hub, spokeA, KEY);
        uint256 initiallyDelivered;
        for (uint256 i; i < count; ++i) {
            uint256 sourceIndex = count - i - 1;
            MessageLib.DomainMessage memory message = messages[sourceIndex];
            bytes32[] memory proof = MerkleTreeLib.getProof(leaves, sourceIndex);
            envelopes[i] = _relay(message, anchor, proof);
            assertEq(envelopes[i].nonce, i, "delivery nonces follow relay order");
            assertEq(envelopes[i].data, abi.encode(sourceIndex));
            bool fails = (failures >> i) & 1 == 1;
            receiver.setReject(fails);
            _deliver(envelopes[i]);
            if (!fails) initiallyDelivered++;
            vm.expectRevert(DomainHub.MessageAlreadyRelayed.selector);
            hub.relayDomainMessage(message, anchor, proof);
        }
        assertEq(receiver.calls(), initiallyDelivered);
        receiver.setReject(false);
        for (uint256 i; i < count; ++i) {
            if ((failures >> i) & 1 == 1) spokeB.retryL1Message(envelopes[i]);
        }
        for (uint256 i; i < count; ++i) {
            assertFalse(spokeB.failedL1Messages(MessageLib.hashMessage(envelopes[i])));
        }
        assertEq(receiver.calls(), count);
        assertEq(hub.l1MessageCounts(B), count);
    }

    function testFuzz_tamperedEnvelopesAreRejectedWithoutConsumption(uint8 field) public {
        MessageLib.DomainMessage memory message = _send(address(receiver), hex"abcd");
        bytes32 anchor = _attestBatch(hub, spokeA, KEY);
        _post(hub, C, anchor); // Even reattestation under another source cannot change its identity.
        field = uint8(bound(field, 0, 7));
        bytes4 error = DomainHub.InvalidProof.selector;
        if (field == 0) message.sourceChainId = C;
        if (field == 1) message.destinationChainId = C;
        if (field == 2) {
            // Naming a sender or a target is rejected before the proof is consulted.
            message.from = address(123);
            error = DomainHub.EncryptedMessageWithSender.selector;
        }
        if (field == 3) {
            message.to = address(123);
            error = DomainHub.EncryptedMessageWithTarget.selector;
        }
        if (field == 4) message.sourceNonce++;
        if (field == 5) message.data = hex"abce";
        if (field == 6) {
            message.kind = MessageLib.MessageKind.Plain;
            error = DomainHub.PlaintextDomainMessage.selector;
        }
        if (field == 7) message.salt = TEST_SALT;
        vm.expectRevert(error);
        hub.relayDomainMessage(message, anchor, new bytes32[](0));
        assertFalse(hub.relayedDomainMessages(message.sourceChainId, _id(message)));
        assertEq(hub.l1MessageCounts(B), 0);
        assertEq(hub.l1MessageCounts(C), 0);
    }

    function test_proofCannotCrossHubOrL1Deployment() public {
        MessageLib.DomainMessage memory message = _send(address(receiver), hex"");
        bytes32 anchor = _attestBatch(hub, spokeA, KEY);
        DomainHub other = new DomainHub();
        _register(other, A);
        _register(other, B);
        _post(other, A, anchor);
        vm.expectRevert(DomainHub.InvalidProof.selector);
        other.relayDomainMessage(message, anchor, new bytes32[](0));
        vm.chainId(2);
        vm.expectRevert(DomainHub.InvalidProof.selector);
        hub.relayDomainMessage(message, anchor, new bytes32[](0));
        vm.chainId(L1);
        hub.relayDomainMessage{value: DELIVERY_FEE}(message, anchor, new bytes32[](0));
    }

    function test_routeForwardsTheRelayerFeeToTheDestination() public {
        MessageLib.DomainMessage memory message = _send(address(receiver), hex"");
        bytes32 anchor = _attestBatch(hub, spokeA, KEY);
        address relayer = makeAddr("relayer");
        vm.deal(relayer, 1 ether);
        uint256 before = address(this).balance;

        vm.expectEmit(address(hub));
        emit IDomainHub.EncryptedL1MessageRecorded(B, A, 0, message.data, 0, 0.3 ether);
        vm.prank(relayer);
        assertTrue(hub.relayDomainMessage{value: 0.3 ether}(message, anchor, new bytes32[](0)));
        assertEq(address(this).balance - before, 0.3 ether, "B's fee recipient is paid");
        assertEq(address(hub).balance, 0);
    }

    function test_l1CallbackRejectsAFee() public {
        MessageLib.DomainMessage memory message = _sendTo(uint64(L1), address(receiver), hex"");
        bytes32 anchor = _attestBatch(hub, spokeA, KEY);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(DomainHub.UnexpectedL1CallbackFee.selector);
        hub.relayDomainMessage{value: 1}(message, anchor, new bytes32[](0));
        assertFalse(hub.relayedDomainMessages(A, _id(message)));
    }

    function test_routeRejectsAFeeBelowTheDestinationMinimum() public {
        MessageLib.DomainMessage memory message = _send(address(receiver), hex"1234");
        bytes32 anchor = _attestBatch(hub, spokeA, KEY);
        // The minimum is sized on the forwarded ciphertext.
        uint256 minimum = hub.minDeliveryFee(message.data.length);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(DomainHub.DeliveryFeeTooLow.selector);
        hub.relayDomainMessage{value: minimum - 1}(message, anchor, new bytes32[](0));
        assertFalse(hub.relayedDomainMessages(A, _id(message)), "an underpaid relay consumes nothing");
        assertTrue(hub.relayDomainMessage{value: minimum}(message, anchor, new bytes32[](0)));
    }

    function test_routeToAStalledDestinationStaysRelayable() public {
        MessageLib.DomainMessage memory message = _send(address(receiver), hex"1234");
        bytes32 anchor = _attestBatch(hub, spokeA, KEY);
        // B has left its registration unattested for more periods than it allows.
        vm.roll(block.number + uint256(MAX_UNATTESTED_PERIODS) * CHECKPOINT_INTERVAL);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(InputQueue.TooManyUnattestedPeriods.selector);
        hub.relayDomainMessage{value: DELIVERY_FEE}(message, anchor, new bytes32[](0));
        assertFalse(hub.relayedDomainMessages(A, _id(message)), "a refused relay consumes nothing");

        _post(hub, B, bytes32(0));
        assertTrue(hub.relayDomainMessage{value: DELIVERY_FEE}(message, anchor, new bytes32[](0)));

        // The forwarded ciphertext is B's newest queue entry, under its source domain and nonce.
        (uint64 head, uint64 index) = _queueBounds(hub, B);
        QueueEntry memory entry;
        while (index < head) {
            (entry, index) = _queueEntry(hub, B, index);
        }
        assertEq(entry.kind, InputQueue.ENCRYPTED_MESSAGE);
        assertEq(entry.fee, DELIVERY_FEE);
        assertEq(entry.payload, abi.encodePacked(A, uint64(message.sourceNonce), uint64(0), message.data));
    }

    function test_deliveryNoncesAreSharedWithL1MessagesAndGapsClose() public {
        hub.sendL1Message{value: DELIVERY_FEE}(B, address(123), hex"");
        MessageLib.DomainMessage memory first = _send(address(receiver), hex"01");
        MessageLib.DomainMessage memory second = _send(address(receiver), hex"02");
        bytes32[] memory leaves = _pendingLeaves(spokeA);
        bytes32 anchor = _attestBatch(hub, spokeA, KEY);
        MessageLib.Message memory skipped = _relay(first, anchor, MerkleTreeLib.getProof(leaves, 0));
        MessageLib.Message memory envelope = _relay(second, anchor, MerkleTreeLib.getProof(leaves, 1));
        assertEq(skipped.nonce, 1, "forwarded deliveries draw from B's shared queue");
        assertEq(envelope.nonce, 2);
        vm.prank(spokeB.SYSTEM_RELAYER());
        spokeB.relayL1Message(uint64(L1), address(this), address(123), hex"", 0);
        // Nonce 1 stands for a ciphertext B's client could not open; the next delivery consumes it.
        _deliver(envelope);
        assertEq(spokeB.nextL1Nonce(), 3);
        assertEq(receiver.payload(), hex"02");
        vm.prank(spokeB.SYSTEM_RELAYER());
        vm.expectRevert(DomainSpoke.OutOfOrderNonce.selector);
        spokeB.relayL1Message(skipped.sourceChainId, skipped.from, skipped.to, skipped.data, skipped.nonce);
    }

    function test_sameSenderAndNonceOnDifferentSourcesRemainDistinct() public {
        MessageLib.DomainMessage memory first = _send(address(receiver), hex"");
        _deliver(_route(first));
        DomainSpoke spokeC = new DomainSpoke(C, L1, address(hub));
        _deliverViewingKey(hub, spokeC, B);
        MessageLib.DomainMessage memory second = _sendFrom(spokeC, B, address(receiver), hex"");
        assertNotEq(_id(first), _id(second));
        bytes32 anchor = _attestBatch(hub, spokeC, KEY);
        MessageLib.Message memory envelope = _relay(second, anchor, new bytes32[](0));
        assertEq(envelope.from, alice);
        _deliver(envelope);
        assertEq(receiver.calls(), 1, "same address on untrusted C must not be accepted");
        assertTrue(spokeB.failedL1Messages(MessageLib.hashMessage(envelope)));
        receiver.setPeer(C, alice);
        spokeB.retryL1Message(envelope);
        assertEq(receiver.calls(), 2);
    }

    function test_retryCanSupplyMoreGas() public {
        receiver.setMinimumGas(2_600_000);
        MessageLib.DomainMessage memory message = _send(address(receiver), hex"");
        MessageLib.Message memory envelope = _route(message);
        _deliver(envelope);
        assertTrue(spokeB.failedL1Messages(MessageLib.hashMessage(envelope)));
        spokeB.retryL1Message{gas: 3_000_000}(envelope);
        assertEq(receiver.calls(), 1);
    }

    function test_failureDoesNotBlockLaterMessageOrRerouteSource() public {
        receiver.setReject(true);
        MessageLib.DomainMessage memory first = _send(address(receiver), hex"01");
        MessageLib.Message memory failed = _route(first);
        _deliver(failed);
        receiver.setReject(false);
        MessageLib.DomainMessage memory second = _send(address(receiver), hex"02");
        _deliver(_route(second));
        assertEq(receiver.calls(), 1);
        assertEq(receiver.payload(), hex"02");
        spokeB.retryL1Message(failed);
        assertEq(receiver.calls(), 2);
        assertEq(receiver.payload(), hex"01");
        vm.expectRevert(DomainHub.MessageAlreadyRelayed.selector);
        hub.relayDomainMessage(first, _id(first), new bytes32[](0));
    }

    function testFuzz_retryRequiresExactTransportEnvelope(uint8 field) public {
        receiver.setReject(true);
        MessageLib.Message memory envelope = _route(_send(address(receiver), hex""));
        _deliver(envelope);
        bytes32 originalHash = MessageLib.hashMessage(envelope);
        field = uint8(bound(field, 0, 4));
        if (field == 0) envelope.from = address(123);
        if (field == 1) envelope.to = address(123);
        if (field == 2) envelope.data = hex"abcd";
        if (field == 3) envelope.nonce++;
        if (field == 4) envelope.sourceChainId = C;
        vm.expectRevert(DomainSpoke.NotFailedMessage.selector);
        spokeB.retryL1Message(envelope);
        assertTrue(spokeB.failedL1Messages(originalHash));
    }

    function test_reentrantRetryCannotExecuteTwice() public {
        MessageLib.Message memory envelope = _route(_send(address(receiver), hex""));
        receiver.setReject(true);
        _deliver(envelope);
        receiver.setReject(false);
        receiver.setReentry(address(spokeB), abi.encodeCall(spokeB.retryL1Message, (envelope)));
        spokeB.retryL1Message(envelope);
        assertFalse(receiver.reentrySucceeded());
        assertEq(receiver.calls(), 1);
    }

    function test_directAndPublicL1SendCannotForgeDomainOrigin() public {
        vm.expectRevert("Receiver: not spoke");
        receiver.onDomainMessage(A, alice, hex"");
        vm.expectRevert(DomainSpoke.NotSystemRelayer.selector);
        spokeB.relayL1Message(A, alice, address(receiver), hex"", 0);
        // Even the same sender address on L1 cannot claim source domain A.
        vm.prank(alice);
        hub.sendL1Message{value: DELIVERY_FEE}(B, address(receiver), hex"");
        MessageLib.Message memory forged = MessageLib.Message(uint64(L1), alice, address(receiver), hex"", 0);
        _deliver(forged);
        assertEq(receiver.calls(), 0);
        assertTrue(spokeB.failedL1Messages(MessageLib.hashMessage(forged)));
    }

    function test_routeCannotImpersonateL1Bridge() public {
        DomainBridge bridge = new DomainBridge(spokeB, alice, address(this), address(new DomainAccessRules(spokeB)));
        MessageLib.DomainMessage memory message =
            _send(address(bridge), MessageLib.encodeTransfer(alice, address(123), 1));
        MessageLib.Message memory envelope = _route(message);
        _deliver(envelope);
        assertTrue(spokeB.failedL1Messages(MessageLib.hashMessage(envelope)));
        assertEq(address(bridge.bridgedTokens(address(123))), address(0));
    }

    function test_ordinaryAndRoutedDeliveryUseTheSameApplicationCallback() public {
        receiver.setPeer(uint64(L1), alice);
        vm.prank(alice);
        hub.sendL1Message{value: DELIVERY_FEE}(B, address(receiver), hex"11");
        _deliver(MessageLib.Message(uint64(L1), alice, address(receiver), hex"11", 0));
        assertEq(receiver.source(), L1);
        assertEq(receiver.sender(), alice);
        _deliver(_route(_send(address(receiver), hex"22")));
        assertEq(receiver.source(), A);
        assertEq(receiver.sender(), alice);
        assertEq(receiver.calls(), 2);
        assertEq(spokeB.nextL1Nonce(), 2);
    }

    function test_destinationRejectsLocalSource() public {
        vm.prank(spokeB.SYSTEM_RELAYER());
        vm.expectRevert(DomainSpoke.InvalidSource.selector);
        spokeB.relayL1Message(B, alice, address(receiver), hex"", 0);
        assertEq(spokeB.nextL1Nonce(), 0);
    }

    function test_noCodeTargetFailsAndIsRetryable() public {
        address futureReceiver = makeAddr("future receiver");
        MessageLib.DomainMessage memory message = _send(futureReceiver, hex"");
        MessageLib.Message memory envelope = _route(message);
        _deliver(envelope);
        assertTrue(spokeB.failedL1Messages(MessageLib.hashMessage(envelope)));
        CrossDomainReceiver template = new CrossDomainReceiver(address(spokeB), A, alice);
        vm.etch(futureReceiver, address(template).code);
        CrossDomainReceiver(futureReceiver).setPeer(A, alice);
        spokeB.retryL1Message(envelope);
        assertEq(CrossDomainReceiver(futureReceiver).calls(), 1);
    }

    // ---------------------------------------------------------------------
    // Envelope shapes the hub accepts
    // ---------------------------------------------------------------------

    function test_routeBindsTheCiphertextAndCannotRepeat() public {
        MessageLib.DomainMessage memory message = _send(address(receiver), hex"1234");
        bytes32 anchor = _attestBatch(hub, spokeA, KEY);
        MessageLib.DomainMessage memory tampered = abi.decode(abi.encode(message), (MessageLib.DomainMessage));
        tampered.data = hex"04deadbeef";
        vm.expectRevert(DomainHub.InvalidProof.selector);
        hub.relayDomainMessage(tampered, anchor, new bytes32[](0));
        _relay(message, anchor, new bytes32[](0));
        vm.expectRevert(DomainHub.MessageAlreadyRelayed.selector);
        hub.relayDomainMessage(message, anchor, new bytes32[](0));
        assertEq(hub.l1MessageCounts(B), 1);
    }

    /// @dev Rejected before the anchor is consulted, so even an attested forgery is not consumed.
    function test_hubRejectsNonCanonicalEnvelopes() public {
        MessageLib.DomainMessage memory forged = MessageLib.DomainMessage({
            kind: MessageLib.MessageKind.Encrypted,
            sourceChainId: A,
            destinationChainId: uint64(L1),
            from: address(0),
            to: address(0),
            sourceNonce: 0,
            salt: bytes32(0),
            data: hex"c0ffee"
        });
        _rejectAttested(forged, DomainHub.EncryptedL1Callback.selector);

        forged.kind = MessageLib.MessageKind.Plain;
        _rejectAttested(forged, DomainHub.ZeroTarget.selector);

        forged.destinationChainId = B;
        forged.to = address(receiver);
        _rejectAttested(forged, DomainHub.PlaintextDomainMessage.selector);

        forged.kind = MessageLib.MessageKind.Encrypted;
        _rejectAttested(forged, DomainHub.EncryptedMessageWithTarget.selector);

        forged.to = address(0);
        forged.from = alice;
        _rejectAttested(forged, DomainHub.EncryptedMessageWithSender.selector);
        assertEq(hub.l1MessageCounts(B), 0);
    }
}
