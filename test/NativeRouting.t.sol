// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {IDomainSpoke} from "../src/interfaces/IDomain.sol";
import {DomainHub} from "../src/DomainHub.sol";
import {DomainSpoke} from "../src/DomainSpoke.sol";
import {DomainBridge} from "../src/bridge/DomainBridge.sol";
import {MessageLib} from "../src/libraries/MessageLib.sol";
import {MerkleTreeLib} from "../src/libraries/MerkleTreeLib.sol";
import {CrossDomainReceiver} from "./mocks/CrossDomainReceiver.sol";
import {DomainTestBase} from "./helpers/DomainTestBase.sol";

contract RoutingHubHarness is DomainHub {
    function setDeliveryNonce(uint64 chain, uint256 nonce) external {
        l1MessageCounts[chain] = nonce;
    }
}

contract NativeRoutingTest is DomainTestBase {
    uint64 internal constant A = 7777;
    uint64 internal constant B = 8888;
    uint64 internal constant C = 9999;
    uint256 internal constant L1 = 1;
    uint256 internal constant KEY = 0xA11CE;
    DomainHub internal hub;
    DomainSpoke internal spokeA;
    DomainSpoke internal spokeB;
    CrossDomainReceiver internal receiver;
    address internal alice = makeAddr("alice");
    bytes32 internal constant L1_EVENT =
        keccak256("L1MessageRecorded(uint64,uint64,address,address,bytes,uint256,bytes32)");

    function setUp() public {
        vm.chainId(L1);
        hub = new RoutingHubHarness();
        _register(hub, A);
        _register(hub, B);
        _register(hub, C);
        spokeA = new DomainSpoke(A, L1, address(hub));
        spokeB = new DomainSpoke(B, L1, address(hub));
        receiver = new CrossDomainReceiver(address(spokeB), A, alice);
    }

    function _register(DomainHub h, uint64 chain) internal {
        _registerDomain(h, chain, KEY);
    }

    /// @dev Attests an arbitrary `anchor` for `source` at its next scheduled height.
    function _post(DomainHub h, uint64 source, bytes32 anchor) internal {
        _attestNext(h, source, bytes32(0), anchor, _keys(KEY));
    }

    function _send(address target, bytes memory data) internal returns (MessageLib.DomainMessage memory message) {
        return _sendTo(B, target, data);
    }

    function _sendTo(uint64 destination, address target, bytes memory data)
        internal
        returns (MessageLib.DomainMessage memory message)
    {
        vm.recordLogs();
        vm.chainId(A);
        vm.prank(alice);
        bytes32 id = spokeA.sendDomainMessage(destination, target, data);
        vm.chainId(L1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        message = abi.decode(abi.decode(logs[0].data, (bytes)), (MessageLib.DomainMessage));
        assertEq(id, _id(message));
        assertEq(logs[0].topics[1], id);
    }

    function _id(MessageLib.DomainMessage memory message) internal view returns (bytes32) {
        return MessageLib.hashDomainMessage(message, L1, address(hub));
    }

    /// @dev Attests everything spoke A recorded since the last attestation as one batch and
    /// routes `message` (expected to be that batch's only leaf) through the hub.
    function _route(MessageLib.DomainMessage memory message) internal returns (MessageLib.Message memory envelope) {
        bytes32 anchor = _attestBatch(hub, spokeA, KEY);
        vm.recordLogs();
        vm.prank(makeAddr("relayer"));
        hub.relayDomainMessage(message, anchor, new bytes32[](0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hub) && logs[i].topics[0] == L1_EVENT) {
                (uint64 source, bytes memory data, uint256 nonce, bytes32 hash) =
                    abi.decode(logs[i].data, (uint64, bytes, uint256, bytes32));
                envelope = MessageLib.Message(
                    source,
                    address(uint160(uint256(logs[i].topics[2]))),
                    address(uint160(uint256(logs[i].topics[3]))),
                    data,
                    nonce
                );
                assertEq(uint256(logs[i].topics[1]), B);
                assertEq(hash, MessageLib.hashMessage(envelope));
                return envelope;
            }
        }
        fail("missing transport event");
    }

    function _deliver(MessageLib.Message memory envelope) internal {
        vm.chainId(B);
        vm.prank(spokeB.SYSTEM_RELAYER());
        spokeB.relayL1Message(envelope.sourceChainId, envelope.from, envelope.to, envelope.data, envelope.nonce);
        vm.chainId(L1);
    }

    function test_routePreservesOriginAndDoesNotExecuteOnL1() public {
        MessageLib.DomainMessage memory message = _send(address(receiver), hex"1234");
        MessageLib.Message memory envelope = _route(message);
        assertEq(receiver.calls(), 0, "routing must not call application on L1");
        assertEq(envelope.sourceChainId, A);
        assertEq(envelope.from, alice);
        assertEq(envelope.to, address(receiver));
        assertEq(envelope.data, message.data);
        assertTrue(hub.relayedDomainMessages(message.sourceChainId, _id(message)));
        vm.expectEmit(address(spokeB));
        emit IDomainSpoke.L1MessageRelayed(MessageLib.hashMessage(envelope), A, alice, address(receiver), 0, true);
        _deliver(envelope);
        assertEq(receiver.calls(), 1);
        assertEq(receiver.source(), A);
        assertEq(receiver.sender(), alice);

        assertEq(receiver.payload(), hex"1234");
        assertFalse(spokeB.failedL1Messages(MessageLib.hashMessage(envelope)));
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
        assertTrue(hub.relayDomainMessage(remote, anchor, MerkleTreeLib.getProof(leaves, 1)));
        assertEq(hub.l1MessageCounts(B), 1);
        assertEq(receiver.calls(), 0);
        assertEq(l1Receiver.calls(), 1, "forwarding must not execute an L1 operation");
        vm.expectRevert("DomainHub: retry on destination domain");
        hub.retryDomainMessage(remote);
        _deliver(MessageLib.Message(remote.sourceChainId, remote.from, remote.to, remote.data, 0));
        assertEq(receiver.calls(), 1);
        assertEq(receiver.payload(), hex"bb");
    }

    function test_unknownDestinationDoesNotConsumeAuthenticatedMessage() public {
        MessageLib.DomainMessage memory message = _sendTo(1234, address(receiver), hex"");
        bytes32 anchor = _attestBatch(hub, spokeA, KEY);
        vm.expectRevert("DomainHub: destination not registered");
        hub.relayDomainMessage(message, anchor, new bytes32[](0));
        assertFalse(hub.relayedDomainMessages(A, _id(message)));
    }

    function test_constructorRejectsInvalidBindings() public {
        vm.expectRevert("DomainSpoke: zero hub");
        new DomainSpoke(A, L1, address(0));
        vm.expectRevert("DomainSpoke: domain is L1");
        new DomainSpoke(1, L1, address(hub));
        vm.expectRevert("DomainSpoke: L1 chain id too large");
        new DomainSpoke(A, uint256(type(uint64).max) + 1, address(hub));
    }

    function test_senderIdentityIsAssignedAndSameChainAndZeroTargetRejected() public {
        vm.expectRevert("DomainSpoke: same domain");
        spokeA.sendDomainMessage(A, address(receiver), hex"");
        vm.expectRevert("DomainSpoke: zero target");
        spokeA.sendDomainMessage(B, address(0), hex"");
        MessageLib.DomainMessage memory message = _send(address(receiver), hex"");
        assertEq(message.from, alice);
        assertEq(message.sourceChainId, A);
        assertEq(message.sourceNonce, 0);
    }

    function test_rejectsUnknownSourceDestinationAndSameChain() public {
        MessageLib.DomainMessage memory message = _send(address(receiver), hex"");
        message.sourceChainId = 1234;
        vm.expectRevert("DomainHub: source not registered");
        hub.relayDomainMessage(message, bytes32(0), new bytes32[](0));
        message.sourceChainId = A;
        message.destinationChainId = 1234;
        vm.expectRevert("DomainHub: unknown anchor");
        hub.relayDomainMessage(message, bytes32(0), new bytes32[](0));
        message.destinationChainId = A;
        vm.expectRevert("DomainHub: same domain");
        hub.relayDomainMessage(message, bytes32(0), new bytes32[](0));
        message.destinationChainId = B;
        message.to = address(0);
        vm.expectRevert("DomainHub: zero target");
        hub.relayDomainMessage(message, bytes32(0), new bytes32[](0));
    }

    function test_registeredDomainNeedsNoSpokeRegistration() public {
        MessageLib.DomainMessage memory message = _sendTo(C, address(receiver), hex"");
        bytes32 anchor = _attestBatch(hub, spokeA, KEY);
        assertTrue(hub.relayDomainMessage(message, anchor, new bytes32[](0)));
        assertTrue(hub.relayedDomainMessages(A, _id(message)));
        assertEq(hub.l1MessageCounts(C), 1);
    }

    function test_duplicateRouteAndReanchoringCannotEnqueueTwice() public {
        MessageLib.DomainMessage memory message = _send(address(receiver), hex"");
        _route(message);
        // Re-anchoring the same id under a crafted root at the next checkpoint changes nothing.
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _id(message);
        leaves[1] = bytes32(uint256(2));
        bytes32[] memory proof = MerkleTreeLib.getProof(leaves, 0);
        bytes32 anchor = MerkleTreeLib.root(leaves);
        _post(hub, A, anchor);
        vm.expectRevert("DomainHub: message already relayed");
        hub.relayDomainMessage(message, anchor, proof);
        assertEq(hub.l1MessageCounts(B), 1);
    }

    function test_enqueueFailureRollsBackSourceConsumption() public {
        MessageLib.DomainMessage memory message = _send(address(receiver), hex"");
        bytes32 anchor = _attestBatch(hub, spokeA, KEY);
        RoutingHubHarness(address(hub)).setDeliveryNonce(B, type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        hub.relayDomainMessage(message, anchor, new bytes32[](0));
        assertFalse(hub.relayedDomainMessages(message.sourceChainId, _id(message)));
        RoutingHubHarness(address(hub)).setDeliveryNonce(B, 0);
        assertTrue(hub.relayDomainMessage(message, anchor, new bytes32[](0)));
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
            uint256 deliveryNonce = hub.l1MessageCounts(B);
            assertTrue(hub.relayDomainMessage(message, anchor, proof));
            assertEq(deliveryNonce, i);
            envelopes[i] = MessageLib.Message(message.sourceChainId, message.from, message.to, message.data, i);
            bool fails = (failures >> i) & 1 == 1;
            receiver.setReject(fails);
            _deliver(envelopes[i]);
            if (!fails) initiallyDelivered++;
            vm.expectRevert("DomainHub: message already relayed");
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

    function testFuzz_proofBindsEveryEnvelopeField(uint8 field) public {
        MessageLib.DomainMessage memory message = _send(address(receiver), hex"abcd");
        bytes32 anchor = _attestBatch(hub, spokeA, KEY);
        _post(hub, C, anchor); // Even reattestation under another source cannot change its identity.
        field = uint8(bound(field, 0, 5));
        if (field == 0) message.sourceChainId = C;
        if (field == 1) message.destinationChainId = C;
        if (field == 2) message.from = address(123);
        if (field == 3) message.to = address(123);
        if (field == 4) message.sourceNonce++;
        if (field == 5) message.data = hex"abce";
        vm.expectRevert("DomainHub: invalid proof");
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
        vm.expectRevert("DomainHub: invalid proof");
        other.relayDomainMessage(message, anchor, new bytes32[](0));
        vm.chainId(2);
        vm.expectRevert("DomainHub: invalid proof");
        hub.relayDomainMessage(message, anchor, new bytes32[](0));
        vm.chainId(L1);
        hub.relayDomainMessage(message, anchor, new bytes32[](0));
    }

    function test_wrongAnchorNamespaceRejected() public {
        MessageLib.DomainMessage memory message = _send(address(receiver), hex"");
        // The batch root is attested under C, not under its source A.
        bytes32 anchor = MerkleTreeLib.root(_pendingLeaves(spokeA));
        _post(hub, C, anchor);
        vm.expectRevert("DomainHub: unknown anchor");
        hub.relayDomainMessage(message, anchor, new bytes32[](0));
    }

    function test_mixedL1AndRoutedBatchHasSharedSourceNonce() public {
        vm.prank(alice);
        spokeA.sendDomainMessage(uint64(L1), address(123), hex"01");
        MessageLib.DomainMessage memory local = MessageLib.DomainMessage(A, uint64(L1), alice, address(123), 0, hex"01");
        MessageLib.DomainMessage memory message = _send(address(receiver), hex"02");
        assertEq(message.sourceNonce, 1);
        bytes32[] memory leaves = _pendingLeaves(spokeA);
        bytes32[] memory l1Proof = MerkleTreeLib.getProof(leaves, 0);
        bytes32[] memory routeProof = MerkleTreeLib.getProof(leaves, 1);
        bytes32 anchor = _attestBatch(hub, spokeA, KEY);
        assertTrue(hub.relayDomainMessage(local, anchor, l1Proof));
        assertTrue(hub.relayDomainMessage(message, anchor, routeProof));
    }

    function test_routedProofCannotBeUsedForL1Callback() public {
        MessageLib.DomainMessage memory message = _send(address(receiver), hex"");
        bytes32 anchor = _attestBatch(hub, spokeA, KEY);
        message.destinationChainId = uint64(L1);
        vm.expectRevert("DomainHub: invalid proof");
        hub.relayDomainMessage(message, anchor, new bytes32[](0));
    }

    function test_deliveryNoncesSharePlaintextAndEncryptedQueue() public {
        hub.sendL1Message(B, address(123), hex"");
        hub.sendEncryptedL1Message(B, hex"bad0");
        MessageLib.DomainMessage memory message = _send(address(receiver), hex"");
        MessageLib.Message memory envelope = _route(message);
        assertEq(message.sourceNonce, 0);
        assertEq(envelope.nonce, 2);
        vm.prank(spokeB.SYSTEM_RELAYER());
        spokeB.relayL1Message(uint64(L1), address(this), address(123), hex"", 0);
        _deliver(envelope); // nonce 1 undecryptable, skipped by protocol
        assertEq(spokeB.nextL1Nonce(), 3);
        vm.prank(spokeB.SYSTEM_RELAYER());
        vm.expectRevert("DomainSpoke: out-of-order nonce");
        spokeB.relayL1Message(envelope.sourceChainId, envelope.from, envelope.to, envelope.data, 2);
    }

    function test_sameSenderAndNonceOnDifferentSourcesRemainDistinct() public {
        MessageLib.DomainMessage memory first = _send(address(receiver), hex"");
        _deliver(_route(first));
        DomainSpoke spokeC = new DomainSpoke(C, L1, address(hub));
        vm.prank(alice);
        spokeC.sendDomainMessage(B, address(receiver), hex"");
        MessageLib.DomainMessage memory second = MessageLib.DomainMessage(C, B, alice, address(receiver), 0, hex"");
        bytes32 anchor = _attestBatch(hub, spokeC, KEY);
        uint256 nonce = hub.l1MessageCounts(B);
        assertTrue(hub.relayDomainMessage(second, anchor, new bytes32[](0)));
        MessageLib.Message memory envelope =
            MessageLib.Message(second.sourceChainId, second.from, second.to, second.data, nonce);
        assertNotEq(_id(first), _id(second));
        _deliver(envelope);
        assertEq(receiver.calls(), 1, "same address on untrusted C must not be accepted");
        assertTrue(spokeB.failedL1Messages(MessageLib.hashMessage(envelope)));
        receiver.setPeer(C, alice);
        spokeB.retryL1Message(envelope);
        assertEq(receiver.calls(), 2);
    }

    function test_receiverFailureAndPermissionlessRetry() public {
        receiver.setReject(true);
        MessageLib.DomainMessage memory message = _send(address(receiver), hex"1234");
        MessageLib.Message memory envelope = _route(message);
        _deliver(envelope);
        assertTrue(hub.relayedDomainMessages(message.sourceChainId, _id(message)));
        assertTrue(spokeB.failedL1Messages(MessageLib.hashMessage(envelope)));
        assertEq(spokeB.nextL1Nonce(), 1);
        vm.expectRevert("DomainSpoke: retry failed");
        spokeB.retryL1Message(envelope);
        assertTrue(spokeB.failedL1Messages(MessageLib.hashMessage(envelope)));
        receiver.setReject(false);
        vm.expectEmit(address(spokeB));
        emit IDomainSpoke.L1MessageRelayed(MessageLib.hashMessage(envelope), A, alice, address(receiver), 0, true);
        vm.prank(makeAddr("retry caller"));
        spokeB.retryL1Message(envelope);
        assertEq(receiver.calls(), 1);
        assertFalse(spokeB.failedL1Messages(MessageLib.hashMessage(envelope)));
        vm.expectRevert("DomainSpoke: not a failed message");
        spokeB.retryL1Message(envelope);
    }

    function test_retryCanSupplyMoreGas() public {
        receiver.setMinimumGas(2_100_000);
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
        vm.expectRevert("DomainHub: message already relayed");
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
        vm.expectRevert("DomainSpoke: not a failed message");
        spokeB.retryL1Message(envelope);
        assertTrue(spokeB.failedL1Messages(originalHash));
    }

    function test_reentrantRetryAndForgedCallbackCannotExecuteTwice() public {
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
        vm.expectRevert("DomainSpoke: not system relayer");
        spokeB.relayL1Message(A, alice, address(receiver), hex"", 0);
        // Even the same sender address on L1 cannot claim source domain A.
        vm.prank(alice);
        hub.sendL1Message(B, address(receiver), hex"");
        MessageLib.Message memory forged = MessageLib.Message(uint64(L1), alice, address(receiver), hex"", 0);
        _deliver(forged);
        assertEq(receiver.calls(), 0);
        assertTrue(spokeB.failedL1Messages(MessageLib.hashMessage(forged)));
    }

    function test_routeCannotImpersonateL1Bridge() public {
        DomainBridge bridge = new DomainBridge(spokeB, alice);
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
        hub.sendL1Message(B, address(receiver), hex"11");
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
        vm.expectRevert("DomainSpoke: invalid source");
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

    function test_duplicateDeliveryNonceCannotExecuteAgain() public {
        MessageLib.Message memory envelope = _route(_send(address(receiver), hex""));
        _deliver(envelope);
        vm.prank(spokeB.SYSTEM_RELAYER());
        vm.expectRevert("DomainSpoke: out-of-order nonce");
        spokeB.relayL1Message(envelope.sourceChainId, envelope.from, envelope.to, envelope.data, envelope.nonce);
        assertEq(receiver.calls(), 1);
    }
}
