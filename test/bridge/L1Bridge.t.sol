// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IDomainHub} from "../../src/interfaces/IDomain.sol";
import {L1Bridge} from "../../src/bridge/L1Bridge.sol";
import {MessageLib} from "../../src/libraries/MessageLib.sol";
import {DomainHub} from "../../src/DomainHub.sol";
import {TestERC20, FeeOnTransferERC20} from "../mocks/TestERC20.sol";
import {DomainTestBase} from "../helpers/DomainTestBase.sol";

contract L1BridgeTest is DomainTestBase {
    uint64 internal constant CHAIN_ID = 7777;
    address internal constant DOMAIN_BRIDGE = address(0xB41D6E);
    uint256 internal constant VALIDATOR_KEY = 0xA11CE;

    DomainHub internal hub;
    L1Bridge internal bridge;
    TestERC20 internal token;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        hub = new DomainHub();
        _registerDomain(hub, CHAIN_ID, VALIDATOR_KEY);

        bridge = new L1Bridge(hub, CHAIN_ID);
        bridge.registerDomainBridge(DOMAIN_BRIDGE);

        token = new TestERC20();
        bridge.setTokenAllowed(address(token), true);
        token.mint(alice, 1000 ether);
        vm.prank(alice);
        token.approve(address(bridge), type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // Registry
    // ---------------------------------------------------------------------

    function test_register_onlyOwner() public {
        L1Bridge fresh = new L1Bridge(hub, CHAIN_ID);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.registerDomainBridge(DOMAIN_BRIDGE);
    }

    function test_register_oneShot() public {
        vm.expectRevert("L1Bridge: already registered");
        bridge.registerDomainBridge(address(0xDEAD));
    }

    function test_register_rejectsZeroBridge() public {
        L1Bridge fresh = new L1Bridge(hub, CHAIN_ID);
        vm.expectRevert("L1Bridge: zero bridge");
        fresh.registerDomainBridge(address(0));
    }

    // ---------------------------------------------------------------------
    // bridgeToDomain
    // ---------------------------------------------------------------------

    function test_bridge_locksTokensAndSendsMessage() public {
        // The recorded message: from the bridge, to the counterpart, transfer payload.
        bytes memory data = MessageLib.encodeTransfer(bob, address(token), 100 ether);
        bytes32 expectedHash = MessageLib.hashMessage(
            MessageLib.Message({
                sourceChainId: uint64(block.chainid), from: address(bridge), to: DOMAIN_BRIDGE, data: data, nonce: 0
            })
        );
        vm.expectEmit(address(hub));
        emit IDomainHub.L1MessageRecorded(
            CHAIN_ID, uint64(block.chainid), address(bridge), DOMAIN_BRIDGE, data, 0, expectedHash
        );
        vm.expectEmit(address(bridge));
        emit L1Bridge.BridgeInitiated(alice, bob, address(token), 100 ether);
        vm.prank(alice);
        bridge.bridgeToDomain(bob, address(token), 100 ether);

        assertEq(token.balanceOf(address(bridge)), 100 ether);
        assertEq(token.balanceOf(alice), 900 ether);
        assertEq(hub.l1MessageCounts(CHAIN_ID), 1);
    }

    function test_bridge_rejectsUnregisteredCounterpart() public {
        L1Bridge fresh = new L1Bridge(hub, CHAIN_ID);
        vm.prank(alice);
        vm.expectRevert("L1Bridge: counterpart not registered");
        fresh.bridgeToDomain(bob, address(token), 100 ether);
    }

    function test_bridge_rejectsZeroRecipient() public {
        vm.prank(alice);
        vm.expectRevert("L1Bridge: zero recipient");
        bridge.bridgeToDomain(address(0), address(token), 100 ether);
    }

    function test_bridge_rejectsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("L1Bridge: zero amount");
        bridge.bridgeToDomain(bob, address(token), 0);
    }

    function test_bridge_rejectsFeeOnTransferToken() public {
        FeeOnTransferERC20 feeToken = new FeeOnTransferERC20();
        bridge.setTokenAllowed(address(feeToken), true);
        feeToken.mint(alice, 1000 ether);
        vm.startPrank(alice);
        feeToken.approve(address(bridge), type(uint256).max);
        vm.expectRevert("L1Bridge: fee-on-transfer token not supported");
        bridge.bridgeToDomain(bob, address(feeToken), 100 ether);
        vm.stopPrank();
    }

    function test_bridge_rejectsInsufficientBalance() public {
        vm.prank(bob); // bob has no tokens
        token.approve(address(bridge), type(uint256).max);
        vm.prank(bob);
        vm.expectRevert();
        bridge.bridgeToDomain(alice, address(token), 1 ether);
    }

    // ---------------------------------------------------------------------
    // Token allowlist
    // ---------------------------------------------------------------------

    function test_setTokenAllowed_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        bridge.setTokenAllowed(address(token), false);
    }

    function test_bridge_rejectsDisallowedToken() public {
        TestERC20 other = new TestERC20();
        other.mint(alice, 100 ether);
        vm.startPrank(alice);
        other.approve(address(bridge), type(uint256).max);
        vm.expectRevert("L1Bridge: token not allowed");
        bridge.bridgeToDomain(bob, address(other), 100 ether);
        vm.stopPrank();
    }

    function test_disallow_stopsNewDepositsOnly() public {
        // Lock collateral while the token is allowed.
        vm.prank(alice);
        bridge.bridgeToDomain(bob, address(token), 100 ether);

        // Owner disallows the token: new deposits revert...
        bridge.setTokenAllowed(address(token), false);
        vm.prank(alice);
        vm.expectRevert("L1Bridge: token not allowed");
        bridge.bridgeToDomain(bob, address(token), 1 ether);

        // ...but withdrawals of the already-locked collateral still finalize.
        MessageLib.DomainMessage memory message = _anchoredWithdrawal(bob, 100 ether, 0);
        hub.relayDomainMessage(message, _hash(message), new bytes32[](0));
        assertEq(token.balanceOf(bob), 100 ether);
    }

    // ---------------------------------------------------------------------
    // Domain -> L1 delivery
    // ---------------------------------------------------------------------

    /// @dev The single validator (quorum 1) attests `anchor` under `chainId` at its next
    /// checkpoint height, recording it on the hub. These unit tests post hand-made anchors
    /// for a counterpart that is only an address, so no spoke batch is involved.
    function _anchor(uint64 chainId, bytes32 anchor) internal {
        _attestNext(hub, chainId, bytes32(0), anchor, _keys(VALIDATOR_KEY));
    }

    /// @dev Builds a withdrawal message from the counterpart and records its hash as a
    /// single-leaf anchor under CHAIN_ID (single leaf = own root, empty proof).
    function _anchoredWithdrawal(address recipient, uint256 amount, uint256 nonce)
        internal
        returns (MessageLib.DomainMessage memory message)
    {
        message = MessageLib.DomainMessage({
            kind: MessageLib.MessageKind.Plain,
            sourceChainId: CHAIN_ID,
            destinationChainId: uint64(block.chainid),
            from: DOMAIN_BRIDGE,
            to: address(bridge),
            data: MessageLib.encodeTransfer(recipient, address(token), amount),
            sourceNonce: nonce
        });
        _anchor(CHAIN_ID, _hash(message));
    }

    function test_withdraw_releasesTokens() public {
        token.mint(address(bridge), 100 ether); // locked collateral
        MessageLib.DomainMessage memory message = _anchoredWithdrawal(bob, 40 ether, 0);
        bytes32 messageHash = _hash(message);

        vm.expectEmit(address(bridge));
        emit L1Bridge.WithdrawalFinalized(bob, address(token), 40 ether);
        hub.relayDomainMessage(message, messageHash, new bytes32[](0));

        assertEq(token.balanceOf(bob), 40 ether);
        assertEq(token.balanceOf(address(bridge)), 60 ether);
        assertTrue(hub.relayedDomainMessages(CHAIN_ID, messageHash));
    }

    function test_withdraw_rejectsReplay() public {
        token.mint(address(bridge), 100 ether);
        MessageLib.DomainMessage memory message = _anchoredWithdrawal(bob, 40 ether, 0);
        bytes32 messageHash = _hash(message);
        hub.relayDomainMessage(message, messageHash, new bytes32[](0));

        vm.expectRevert("DomainHub: message already relayed");
        hub.relayDomainMessage(message, messageHash, new bytes32[](0));
    }

    function test_withdraw_rejectsForgedSender() public {
        token.mint(address(bridge), 100 ether);
        // Anchored message whose `from` is not the counterpart: rejected even though
        // the proof itself is valid.
        MessageLib.DomainMessage memory message = MessageLib.DomainMessage({
            kind: MessageLib.MessageKind.Plain,
            sourceChainId: CHAIN_ID,
            destinationChainId: uint64(block.chainid),
            from: makeAddr("attacker"),
            to: address(bridge),
            data: MessageLib.encodeTransfer(bob, address(token), 40 ether),
            sourceNonce: 0
        });
        bytes32 messageHash = _hash(message);
        _anchor(CHAIN_ID, messageHash);

        assertFalse(hub.relayDomainMessage(message, messageHash, new bytes32[](0)));
        assertTrue(hub.failedDomainMessages(CHAIN_ID, messageHash));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_messageToOtherDestinationDoesNotReleaseCollateral() public {
        token.mint(address(bridge), 40 ether);
        MessageLib.DomainMessage memory message = MessageLib.DomainMessage({
            kind: MessageLib.MessageKind.Plain,
            sourceChainId: CHAIN_ID,
            destinationChainId: uint64(block.chainid),
            from: DOMAIN_BRIDGE,
            to: makeAddr("someOtherContract"),
            data: MessageLib.encodeTransfer(bob, address(token), 40 ether),
            sourceNonce: 0
        });
        bytes32 messageHash = _hash(message);
        _anchor(CHAIN_ID, messageHash);

        assertTrue(hub.relayDomainMessage(message, messageHash, new bytes32[](0)));
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(bridge)), 40 ether);
    }

    function test_withdraw_rejectsUnknownAnchor() public {
        MessageLib.DomainMessage memory message = MessageLib.DomainMessage({
            kind: MessageLib.MessageKind.Plain,
            sourceChainId: CHAIN_ID,
            destinationChainId: uint64(block.chainid),
            from: DOMAIN_BRIDGE,
            to: address(bridge),
            data: MessageLib.encodeTransfer(bob, address(token), 40 ether),
            sourceNonce: 0
        });
        vm.expectRevert("DomainHub: unknown anchor");
        hub.relayDomainMessage(message, _hash(message), new bytes32[](0));
    }

    function test_withdraw_rejectsAnchorFromOtherDomain() public {
        // Anchor recorded under a different chain id: this bridge must not accept it,
        // even with a valid proof — this is the asset-isolation property.
        MessageLib.DomainMessage memory message = MessageLib.DomainMessage({
            kind: MessageLib.MessageKind.Plain,
            sourceChainId: CHAIN_ID,
            destinationChainId: uint64(block.chainid),
            from: DOMAIN_BRIDGE,
            to: address(bridge),
            data: MessageLib.encodeTransfer(bob, address(token), 40 ether),
            sourceNonce: 0
        });
        bytes32 messageHash = _hash(message);
        _registerDomain(hub, 8888, VALIDATOR_KEY); // 8888's validator attests the anchor there
        _anchor(8888, messageHash);

        vm.expectRevert("DomainHub: unknown anchor");
        hub.relayDomainMessage(message, messageHash, new bytes32[](0));
    }

    function test_withdraw_rejectsInvalidProof() public {
        MessageLib.DomainMessage memory message = _anchoredWithdrawal(bob, 40 ether, 0);
        bytes32 anchor = _hash(message);

        // Valid anchor, but the altered message no longer hashes into it.
        message.sourceNonce = 999;
        vm.expectRevert("DomainHub: invalid proof");
        hub.relayDomainMessage(message, anchor, new bytes32[](0));
    }

    function test_withdraw_rejectsUnregisteredCounterpart() public {
        L1Bridge fresh = new L1Bridge(hub, CHAIN_ID);
        MessageLib.DomainMessage memory message = MessageLib.DomainMessage({
            kind: MessageLib.MessageKind.Plain,
            sourceChainId: CHAIN_ID,
            destinationChainId: uint64(block.chainid),
            from: address(0),
            to: address(fresh),
            data: MessageLib.encodeTransfer(bob, address(token), 40 ether),
            sourceNonce: 0
        });
        vm.prank(address(hub));
        vm.expectRevert("L1Bridge: counterpart not registered");
        fresh.onDomainMessage(CHAIN_ID, message.from, message.data);
    }

    function test_callback_rejectsDirectCaller() public {
        vm.expectRevert("L1Bridge: not hub");
        bridge.onDomainMessage(CHAIN_ID, DOMAIN_BRIDGE, MessageLib.encodeTransfer(bob, address(token), 40 ether));
    }

    function test_callback_rejectsWrongDomain() public {
        vm.prank(address(hub));
        vm.expectRevert("L1Bridge: wrong domain");
        bridge.onDomainMessage(8888, DOMAIN_BRIDGE, MessageLib.encodeTransfer(bob, address(token), 40 ether));
    }

    function test_callback_rejectsWrongSender() public {
        vm.prank(address(hub));
        vm.expectRevert("L1Bridge: not from domain bridge");
        bridge.onDomainMessage(CHAIN_ID, alice, MessageLib.encodeTransfer(bob, address(token), 40 ether));
    }

    function test_withdraw_otherDomainCannotReleaseCollateral() public {
        token.mint(address(bridge), 100 ether);
        MessageLib.DomainMessage memory message = _anchoredWithdrawal(bob, 40 ether, 0);
        _registerDomain(hub, 8888, VALIDATOR_KEY);
        message.sourceChainId = 8888;
        bytes32 otherHash = _hash(message);
        _anchor(8888, otherHash);
        assertFalse(hub.relayDomainMessage(message, otherHash, new bytes32[](0)));
        assertTrue(hub.failedDomainMessages(8888, otherHash));
        assertEq(token.balanceOf(bob), 0);
        message.sourceChainId = CHAIN_ID;
        assertTrue(hub.relayDomainMessage(message, _hash(message), new bytes32[](0)));
        assertEq(token.balanceOf(bob), 40 ether);
    }

    function test_withdraw_failedTransferCanRetry() public {
        MessageLib.DomainMessage memory message = _anchoredWithdrawal(bob, 40 ether, 0);
        bytes32 messageHash = _hash(message);
        assertFalse(hub.relayDomainMessage(message, messageHash, new bytes32[](0)));
        assertTrue(hub.failedDomainMessages(CHAIN_ID, messageHash));
        token.mint(address(bridge), 40 ether);
        hub.retryDomainMessage(message);
        assertFalse(hub.failedDomainMessages(CHAIN_ID, messageHash));
        assertEq(token.balanceOf(bob), 40 ether);
        vm.expectRevert("DomainHub: not a failed message");
        hub.retryDomainMessage(message);
    }

    function _hash(MessageLib.DomainMessage memory message) internal view returns (bytes32) {
        return MessageLib.hashDomainMessage(message, block.chainid, address(hub));
    }
}
