// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DomainHub} from "../src/DomainHub.sol";
import {IDomainHub, IDomainMessageReceiver} from "../src/interfaces/IDomain.sol";
import {MessageLib} from "../src/libraries/MessageLib.sol";
import {MerkleTreeLib} from "./helpers/MerkleTreeLib.sol";
import {DomainTestBase} from "./helpers/DomainTestBase.sol";

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

contract DomainRelayTest is DomainTestBase {
    uint64 internal constant CHAIN_A = 7777;
    uint64 internal constant CHAIN_B = 8888;
    uint256 internal constant VALIDATOR_KEY = 0xA11CE;
    DomainHub internal hub;
    DomainReceiverMock internal receiver;
    address internal sender = address(0x1234);

    function setUp() public {
        hub = new DomainHub();
        _registerDomain(hub, CHAIN_A, VALIDATOR_KEY);
        _registerDomain(hub, CHAIN_B, VALIDATOR_KEY);
        receiver = new DomainReceiverMock(hub);
    }

    function _message(uint256 nonce) internal view returns (MessageLib.DomainMessage memory) {
        return MessageLib.DomainMessage(
            MessageLib.MessageKind.Plain,
            CHAIN_A,
            uint64(block.chainid),
            sender,
            address(receiver),
            nonce,
            TEST_SALT,
            hex"123456"
        );
    }

    /// @dev Attests `anchor` for `chainId` at its next scheduled height.
    function _anchor(uint64 chainId, bytes32 anchor) internal {
        _attestNext(hub, chainId, bytes32(0), anchor, _keys(VALIDATOR_KEY));
    }

    function _relay(MessageLib.DomainMessage memory message) internal returns (bool) {
        return hub.relayDomainMessage(message, _hash(message), new bytes32[](0));
    }

    function test_permissionlessDeliveryAuthenticatesSourceAndPayload() public {
        MessageLib.DomainMessage memory message = _message(4);
        bytes32 hash = _hash(message);
        _anchor(CHAIN_A, hash);
        vm.expectEmit(address(hub));
        emit IDomainHub.DomainMessageRelayed(CHAIN_A, hash, sender, address(receiver), 4, true);
        vm.prank(makeAddr("relayer"));
        assertTrue(_relay(message));
        assertEq(receiver.calls(), 1);
        assertEq(receiver.sourceDomain(), CHAIN_A);
        assertEq(receiver.sourceSender(), sender);
        assertEq(receiver.payload(), message.data);
        assertTrue(hub.relayedDomainMessages(CHAIN_A, hash));
        assertFalse(hub.failedDomainMessages(CHAIN_A, hash));
    }

    function test_replayProtectionSurvivesReanchoring() public {
        MessageLib.DomainMessage memory message = _message(0);
        bytes32 hash = _hash(message);
        _anchor(CHAIN_A, hash);
        assertTrue(_relay(message));
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = hash;
        leaves[1] = bytes32(uint256(42));
        bytes32 root = MerkleTreeLib.root(leaves);
        _anchor(CHAIN_A, root);
        vm.expectRevert(DomainHub.MessageAlreadyRelayed.selector);
        hub.relayDomainMessage(message, root, MerkleTreeLib.getProof(leaves, 0));
        assertEq(receiver.calls(), 1);
    }

    function test_identicalMessagesFromDifferentDomainsAreIndependent() public {
        MessageLib.DomainMessage memory message = _message(0);
        bytes32 hash = _hash(message);
        _anchor(CHAIN_A, hash);
        assertTrue(_relay(message));
        message.sourceChainId = CHAIN_B;
        _anchor(CHAIN_B, _hash(message));
        assertTrue(_relay(message));
        assertEq(receiver.calls(), 2);
        assertEq(receiver.sourceDomain(), CHAIN_B);
    }

    function test_anchorCannotAuthenticateAnotherDomain() public {
        // CHAIN_A's validators attest the id of a message claiming CHAIN_B as its source:
        // anchors are scoped to the attesting domain, so it cannot authenticate the message.
        MessageLib.DomainMessage memory message = _message(0);
        message.sourceChainId = CHAIN_B;
        _anchor(CHAIN_A, _hash(message));
        vm.expectRevert(DomainHub.UnknownAnchor.selector);
        _relay(message);
        message.sourceChainId = 9999;
        vm.expectRevert(DomainHub.SourceNotRegistered.selector);
        _relay(message);
        assertEq(receiver.calls(), 0);
    }

    function test_multiLeafMessagesCanArriveOutOfOrder() public {
        bytes32[] memory leaves = new bytes32[](3);
        for (uint256 i; i < 3; ++i) {
            leaves[i] = _hash(_message(i));
        }
        bytes32 root = MerkleTreeLib.root(leaves);
        _anchor(CHAIN_A, root);
        for (uint256 i = 3; i > 0; --i) {
            assertTrue(hub.relayDomainMessage(_message(i - 1), root, MerkleTreeLib.getProof(leaves, i - 1)));
        }
        assertEq(receiver.calls(), 3);
    }

    function test_failedDeliveryAndRetryLifecycle() public {
        MessageLib.DomainMessage memory message = _message(0);
        bytes32 hash = _hash(message);
        _anchor(CHAIN_A, hash);
        receiver.setFailure(true);
        vm.expectEmit(address(hub));
        emit IDomainHub.DomainMessageRelayed(CHAIN_A, hash, sender, address(receiver), 0, false);
        assertFalse(_relay(message));
        assertTrue(hub.relayedDomainMessages(CHAIN_A, hash));
        assertTrue(hub.failedDomainMessages(CHAIN_A, hash));
        vm.expectRevert(DomainHub.MessageAlreadyRelayed.selector);
        _relay(message);
        vm.expectRevert(DomainHub.RetryFailed.selector);
        hub.retryDomainMessage(message);
        assertTrue(hub.failedDomainMessages(CHAIN_A, hash));
        receiver.setFailure(false);
        vm.expectEmit(address(hub));
        emit IDomainHub.DomainMessageRelayed(CHAIN_A, hash, sender, address(receiver), 0, true);
        vm.prank(makeAddr("another relayer"));
        hub.retryDomainMessage(message);
        assertEq(receiver.calls(), 1);
        assertFalse(hub.failedDomainMessages(CHAIN_A, hash));
        vm.expectRevert(DomainHub.NotFailedMessage.selector);
        hub.retryDomainMessage(message);
    }

    function test_retryRequiresExactAuthenticatedMessageAndDomain() public {
        MessageLib.DomainMessage memory message = _message(0);
        vm.expectRevert(DomainHub.NotFailedMessage.selector);
        hub.retryDomainMessage(message);
        _anchor(CHAIN_A, _hash(message));
        receiver.setFailure(true);
        assertFalse(_relay(message));
        message.salt = bytes32(0);
        vm.expectRevert(DomainHub.NotFailedMessage.selector);
        hub.retryDomainMessage(message);
        message.salt = TEST_SALT;
        message.sourceChainId = CHAIN_B;
        vm.expectRevert(DomainHub.NotFailedMessage.selector);
        hub.retryDomainMessage(message);
        message.sourceChainId = CHAIN_A;
        message.data = hex"ffff";
        vm.expectRevert(DomainHub.NotFailedMessage.selector);
        hub.retryDomainMessage(message);
    }

    function test_reentrantRelayCannotExecuteTwice() public {
        MessageLib.DomainMessage memory message = _message(0);
        bytes32 hash = _hash(message);
        _anchor(CHAIN_A, hash);
        receiver.setReentry(abi.encodeCall(hub.relayDomainMessage, (message, hash, new bytes32[](0))));
        assertTrue(_relay(message));
        assertFalse(receiver.reentrySucceeded());
        assertEq(receiver.calls(), 1);
    }

    function test_reentrantRetryCannotExecuteTwice() public {
        MessageLib.DomainMessage memory message = _message(0);
        _anchor(CHAIN_A, _hash(message));
        receiver.setFailure(true);
        assertFalse(_relay(message));
        receiver.setFailure(false);
        receiver.setReentry(abi.encodeCall(hub.retryDomainMessage, (message)));
        hub.retryDomainMessage(message);
        assertFalse(receiver.reentrySucceeded());
        assertEq(receiver.calls(), 1);
    }

    function test_deliveryToAddressWithoutCodeSucceeds() public {
        MessageLib.DomainMessage memory message = _message(0);
        message.to = makeAddr("future receiver");
        bytes32 hash = _hash(message);
        _anchor(CHAIN_A, hash);
        assertTrue(_relay(message));
        assertTrue(hub.relayedDomainMessages(CHAIN_A, hash));
        assertFalse(hub.failedDomainMessages(CHAIN_A, hash));
        vm.expectRevert(DomainHub.MessageAlreadyRelayed.selector);
        _relay(message);
        vm.expectRevert(DomainHub.NotFailedMessage.selector);
        hub.retryDomainMessage(message);
    }

    function test_deliveryForwardsAllAvailableGas() public {
        GasHungryDomainReceiver hungry = new GasHungryDomainReceiver();
        MessageLib.DomainMessage memory message = _message(0);
        message.to = address(hungry);
        bytes32 hash = _hash(message);
        _anchor(CHAIN_A, hash);
        assertTrue(hub.relayDomainMessage{gas: 3_000_000}(message, hash, new bytes32[](0)));
        assertEq(hungry.calls(), 1);
        assertFalse(hub.failedDomainMessages(CHAIN_A, hash));
    }

    function test_retryCanUseMoreGasThanInitialAttempt() public {
        GasHungryDomainReceiver hungry = new GasHungryDomainReceiver();
        MessageLib.DomainMessage memory message = _message(0);
        message.to = address(hungry);
        bytes32 hash = _hash(message);
        _anchor(CHAIN_A, hash);
        assertFalse(hub.relayDomainMessage{gas: 1_000_000}(message, hash, new bytes32[](0)));
        assertTrue(hub.failedDomainMessages(CHAIN_A, hash));
        hub.retryDomainMessage{gas: 3_000_000}(message);
        assertEq(hungry.calls(), 1);
        assertFalse(hub.failedDomainMessages(CHAIN_A, hash));
    }

    function _hash(MessageLib.DomainMessage memory message) internal view returns (bytes32) {
        return MessageLib.hashDomainMessage(message, block.chainid, address(hub));
    }
}
