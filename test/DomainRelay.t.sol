// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DomainHub} from "../src/DomainHub.sol";
import {IDomainHub, IDomainMessageReceiver} from "../src/interfaces/IDomain.sol";
import {MessageLib} from "../src/libraries/MessageLib.sol";
import {MerkleTreeLib} from "../src/libraries/MerkleTreeLib.sol";

contract DomainReceiverMock is IDomainMessageReceiver {
    DomainHub public immutable HUB;
    bool public shouldFail;
    uint256 public calls;
    uint64 public sourceDomain;
    address public sourceSender;
    bytes public payload;
    bytes public reentry;
    bool public reentrySucceeded;

    constructor(DomainHub hub) {
        HUB = hub;
    }

    function setFailure(bool fail) external {
        shouldFail = fail;
    }

    function setReentry(bytes calldata data) external {
        reentry = data;
    }

    function onDomainMessage(uint64 domainChainId, address from, bytes calldata data) external {
        require(msg.sender == address(HUB), "not hub");
        require(!shouldFail, "receiver failure");
        ++calls;
        sourceDomain = domainChainId;
        sourceSender = from;
        payload = data;
        if (reentry.length != 0) {
            (reentrySucceeded,) = address(HUB).call(reentry);
        }
    }
}

contract GasHungryDomainReceiver is IDomainMessageReceiver {
    uint256 public calls;

    function onDomainMessage(uint64, address, bytes calldata) external {
        require(gasleft() > 2_000_000, "needs more gas");
        ++calls;
    }
}

contract DomainRelayTest is Test {
    uint64 internal constant CHAIN_A = 7777;
    uint64 internal constant CHAIN_B = 8888;
    uint256 internal constant VALIDATOR_KEY = 0xA11CE;
    DomainHub internal hub;
    DomainReceiverMock internal receiver;
    address internal sender = address(0x1234);

    function setUp() public {
        hub = new DomainHub();
        address[] memory validators = new address[](1);
        validators[0] = vm.addr(VALIDATOR_KEY);
        hub.registerDomain(CHAIN_A, 0, validators, 1);
        hub.registerDomain(CHAIN_B, 0, validators, 1);
        receiver = new DomainReceiverMock(hub);
    }

    function _message(uint256 nonce) internal view returns (MessageLib.Message memory) {
        return MessageLib.Message(sender, address(receiver), hex"123456", nonce);
    }

    function _anchor(uint64 chainId, bytes32 anchor) internal {
        uint64 height = hub.domainBlockNumbers(chainId) + 1;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(VALIDATOR_KEY, hub.stateTransitionDigest(chainId, height, bytes32(0), anchor));
        hub.submitStateSignature(chainId, height, bytes32(0), anchor, abi.encodePacked(r, s, v));
    }

    function _relay(uint64 chainId, MessageLib.Message memory message) internal returns (bool) {
        return hub.relayDomainMessage(chainId, message, MessageLib.hashMessage(message), new bytes32[](0));
    }

    function test_permissionlessDeliveryAuthenticatesSourceAndPayload() public {
        MessageLib.Message memory message = _message(4);
        bytes32 hash = MessageLib.hashMessage(message);
        _anchor(CHAIN_A, hash);
        vm.expectEmit(address(hub));
        emit IDomainHub.DomainMessageRelayed(CHAIN_A, hash, sender, address(receiver), 4, true);
        vm.prank(makeAddr("relayer"));
        assertTrue(_relay(CHAIN_A, message));
        assertEq(receiver.calls(), 1);
        assertEq(receiver.sourceDomain(), CHAIN_A);
        assertEq(receiver.sourceSender(), sender);
        assertEq(receiver.payload(), message.data);
        assertTrue(hub.relayedDomainMessages(CHAIN_A, hash));
        assertFalse(hub.failedDomainMessages(CHAIN_A, hash));
    }

    function test_replayProtectionSurvivesReanchoring() public {
        MessageLib.Message memory message = _message(0);
        bytes32 hash = MessageLib.hashMessage(message);
        _anchor(CHAIN_A, hash);
        assertTrue(_relay(CHAIN_A, message));
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = hash;
        leaves[1] = bytes32(uint256(42));
        bytes32 root = MerkleTreeLib.root(leaves);
        _anchor(CHAIN_A, root);
        vm.expectRevert("DomainHub: message already relayed");
        hub.relayDomainMessage(CHAIN_A, message, root, MerkleTreeLib.getProof(leaves, 0));
        assertEq(receiver.calls(), 1);
    }

    function test_identicalMessagesFromDifferentDomainsAreIndependent() public {
        MessageLib.Message memory message = _message(0);
        bytes32 hash = MessageLib.hashMessage(message);
        _anchor(CHAIN_A, hash);
        _anchor(CHAIN_B, hash);
        assertTrue(_relay(CHAIN_A, message));
        assertTrue(_relay(CHAIN_B, message));
        assertEq(receiver.calls(), 2);
        assertEq(receiver.sourceDomain(), CHAIN_B);
    }

    function test_anchorCannotAuthenticateAnotherDomain() public {
        MessageLib.Message memory message = _message(0);
        _anchor(CHAIN_A, MessageLib.hashMessage(message));
        vm.expectRevert("DomainHub: unknown anchor");
        _relay(CHAIN_B, message);
        vm.expectRevert("DomainHub: unknown anchor");
        _relay(9999, message);
        assertEq(receiver.calls(), 0);
    }

    function testFuzz_proofBindsEveryMessageField(uint8 field) public {
        MessageLib.Message memory message = _message(0);
        bytes32 hash = MessageLib.hashMessage(message);
        _anchor(CHAIN_A, hash);
        field = uint8(bound(field, 0, 3));
        if (field == 0) message.from = address(0xDEAD);
        if (field == 1) message.to = address(0xDEAD);
        if (field == 2) message.data = hex"9999";
        if (field == 3) message.nonce = 1;
        vm.expectRevert("DomainHub: invalid proof");
        hub.relayDomainMessage(CHAIN_A, message, hash, new bytes32[](0));
        assertFalse(hub.relayedDomainMessages(CHAIN_A, MessageLib.hashMessage(message)));
        assertEq(receiver.calls(), 0);
    }

    function test_multiLeafMessagesCanArriveOutOfOrder() public {
        bytes32[] memory leaves = new bytes32[](3);
        for (uint256 i; i < 3; ++i) {
            leaves[i] = MessageLib.hashMessage(_message(i));
        }
        bytes32 root = MerkleTreeLib.root(leaves);
        _anchor(CHAIN_A, root);
        for (uint256 i = 3; i > 0; --i) {
            assertTrue(hub.relayDomainMessage(CHAIN_A, _message(i - 1), root, MerkleTreeLib.getProof(leaves, i - 1)));
        }
        assertEq(receiver.calls(), 3);
    }

    function test_failedDeliveryAndRetryLifecycle() public {
        MessageLib.Message memory message = _message(0);
        bytes32 hash = MessageLib.hashMessage(message);
        _anchor(CHAIN_A, hash);
        receiver.setFailure(true);
        vm.expectEmit(address(hub));
        emit IDomainHub.DomainMessageRelayed(CHAIN_A, hash, sender, address(receiver), 0, false);
        assertFalse(_relay(CHAIN_A, message));
        assertTrue(hub.relayedDomainMessages(CHAIN_A, hash));
        assertTrue(hub.failedDomainMessages(CHAIN_A, hash));
        vm.expectRevert("DomainHub: message already relayed");
        _relay(CHAIN_A, message);
        vm.expectRevert("DomainHub: retry failed");
        hub.retryDomainMessage(CHAIN_A, message);
        assertTrue(hub.failedDomainMessages(CHAIN_A, hash));
        receiver.setFailure(false);
        vm.expectEmit(address(hub));
        emit IDomainHub.DomainMessageRelayed(CHAIN_A, hash, sender, address(receiver), 0, true);
        vm.prank(makeAddr("another relayer"));
        hub.retryDomainMessage(CHAIN_A, message);
        assertEq(receiver.calls(), 1);
        assertFalse(hub.failedDomainMessages(CHAIN_A, hash));
        vm.expectRevert("DomainHub: not a failed message");
        hub.retryDomainMessage(CHAIN_A, message);
    }

    function test_retryRequiresExactAuthenticatedMessageAndDomain() public {
        MessageLib.Message memory message = _message(0);
        vm.expectRevert("DomainHub: not a failed message");
        hub.retryDomainMessage(CHAIN_A, message);
        _anchor(CHAIN_A, MessageLib.hashMessage(message));
        receiver.setFailure(true);
        assertFalse(_relay(CHAIN_A, message));
        vm.expectRevert("DomainHub: not a failed message");
        hub.retryDomainMessage(CHAIN_B, message);
        message.data = hex"ffff";
        vm.expectRevert("DomainHub: not a failed message");
        hub.retryDomainMessage(CHAIN_A, message);
    }

    function test_reentrantRelayCannotExecuteTwice() public {
        MessageLib.Message memory message = _message(0);
        bytes32 hash = MessageLib.hashMessage(message);
        _anchor(CHAIN_A, hash);
        receiver.setReentry(abi.encodeCall(hub.relayDomainMessage, (CHAIN_A, message, hash, new bytes32[](0))));
        assertTrue(_relay(CHAIN_A, message));
        assertFalse(receiver.reentrySucceeded());
        assertEq(receiver.calls(), 1);
    }

    function test_reentrantRetryCannotExecuteTwice() public {
        MessageLib.Message memory message = _message(0);
        _anchor(CHAIN_A, MessageLib.hashMessage(message));
        receiver.setFailure(true);
        assertFalse(_relay(CHAIN_A, message));
        receiver.setFailure(false);
        receiver.setReentry(abi.encodeCall(hub.retryDomainMessage, (CHAIN_A, message)));
        hub.retryDomainMessage(CHAIN_A, message);
        assertFalse(receiver.reentrySucceeded());
        assertEq(receiver.calls(), 1);
    }

    function test_deliveryToAddressWithoutCodeSucceeds() public {
        MessageLib.Message memory message = _message(0);
        message.to = makeAddr("future receiver");
        bytes32 hash = MessageLib.hashMessage(message);
        _anchor(CHAIN_A, hash);
        assertTrue(_relay(CHAIN_A, message));
        assertTrue(hub.relayedDomainMessages(CHAIN_A, hash));
        assertFalse(hub.failedDomainMessages(CHAIN_A, hash));
        vm.expectRevert("DomainHub: message already relayed");
        _relay(CHAIN_A, message);
        vm.expectRevert("DomainHub: not a failed message");
        hub.retryDomainMessage(CHAIN_A, message);
    }

    function test_retryToAddressWithoutCodeSucceeds() public {
        MessageLib.Message memory message = _message(0);
        bytes32 hash = MessageLib.hashMessage(message);
        _anchor(CHAIN_A, hash);
        receiver.setFailure(true);
        assertFalse(_relay(CHAIN_A, message));
        assertTrue(hub.failedDomainMessages(CHAIN_A, hash));
        vm.etch(message.to, hex"");
        hub.retryDomainMessage(CHAIN_A, message);
        assertTrue(hub.relayedDomainMessages(CHAIN_A, hash));
        assertFalse(hub.failedDomainMessages(CHAIN_A, hash));
    }

    function test_initialDeliveryCanUseMoreThanTwoMillionGas() public {
        GasHungryDomainReceiver hungry = new GasHungryDomainReceiver();
        MessageLib.Message memory message = _message(0);
        message.to = address(hungry);
        bytes32 hash = MessageLib.hashMessage(message);
        _anchor(CHAIN_A, hash);
        assertTrue(hub.relayDomainMessage{gas: 3_000_000}(CHAIN_A, message, hash, new bytes32[](0)));
        assertEq(hungry.calls(), 1);
        assertFalse(hub.failedDomainMessages(CHAIN_A, hash));
    }

    function test_retryCanUseMoreGasThanInitialAttempt() public {
        GasHungryDomainReceiver hungry = new GasHungryDomainReceiver();
        MessageLib.Message memory message = _message(0);
        message.to = address(hungry);
        bytes32 hash = MessageLib.hashMessage(message);
        _anchor(CHAIN_A, hash);
        assertFalse(hub.relayDomainMessage{gas: 1_000_000}(CHAIN_A, message, hash, new bytes32[](0)));
        assertTrue(hub.failedDomainMessages(CHAIN_A, hash));
        hub.retryDomainMessage{gas: 3_000_000}(CHAIN_A, message);
        assertEq(hungry.calls(), 1);
        assertFalse(hub.failedDomainMessages(CHAIN_A, hash));
    }

    function test_initialDeliveryCanUseLessThanTwoMillionGas() public {
        MessageLib.Message memory message = _message(0);
        bytes32 hash = MessageLib.hashMessage(message);
        _anchor(CHAIN_A, hash);
        assertTrue(hub.relayDomainMessage{gas: 500_000}(CHAIN_A, message, hash, new bytes32[](0)));
        assertTrue(hub.relayedDomainMessages(CHAIN_A, hash));
        assertFalse(hub.failedDomainMessages(CHAIN_A, hash));
        assertEq(receiver.calls(), 1);
    }
}
