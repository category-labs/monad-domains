// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BridgedERC20} from "../../src/bridge/BridgedERC20.sol";
import {DomainBridge} from "../../src/bridge/DomainBridge.sol";
import {MessageLib} from "../../src/libraries/MessageLib.sol";
import {DomainSpoke} from "../../src/DomainSpoke.sol";
import {DomainTestBase} from "../helpers/DomainTestBase.sol";

contract DomainBridgeTest is DomainTestBase {
    address internal constant L1_BRIDGE = address(0x11B41D6E);
    address internal constant L1_TOKEN = address(0x70CE2);
    uint64 internal constant CHAIN_ID = 7777;

    DomainSpoke internal spoke;
    DomainBridge internal bridge;

    address internal bob = makeAddr("bob");

    function setUp() public {
        spoke = new DomainSpoke(CHAIN_ID, block.chainid, address(0x1234));
        bridge = new DomainBridge(spoke, L1_BRIDGE);
    }

    /// @dev Delivers a deposit message through the spoke at its next expected nonce.
    function _deliverDeposit(address from, address recipient, address l1Token, uint256 amount)
        internal
        returns (bytes32 messageHash)
    {
        uint256 nonce = spoke.nextL1Nonce();
        bytes memory data = MessageLib.encodeTransfer(recipient, l1Token, amount);
        messageHash =
            MessageLib.hashMessage(MessageLib.Message(uint64(block.chainid), from, address(bridge), data, nonce));
        vm.prank(spoke.SYSTEM_RELAYER());
        spoke.relayL1Message(uint64(block.chainid), from, address(bridge), data, nonce);
    }

    // ---------------------------------------------------------------------
    // onDomainMessage (deposits)
    // ---------------------------------------------------------------------

    function test_deposit_mintsToRecipient() public {
        vm.expectEmit(address(bridge));
        emit DomainBridge.DepositFinalized(bob, L1_TOKEN, 100 ether);
        bytes32 messageHash = _deliverDeposit(L1_BRIDGE, bob, L1_TOKEN, 100 ether);

        // Delivery succeeded within the gas stipend, first-use token deployment included.
        assertFalse(spoke.failedL1Messages(messageHash));
        BridgedERC20 token = bridge.bridgedTokens(L1_TOKEN);
        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.L1_TOKEN(), L1_TOKEN);
    }

    function test_deposit_reusesDeployedToken() public {
        _deliverDeposit(L1_BRIDGE, bob, L1_TOKEN, 100 ether);
        BridgedERC20 token = bridge.bridgedTokens(L1_TOKEN);

        _deliverDeposit(L1_BRIDGE, bob, L1_TOKEN, 50 ether);

        assertEq(address(bridge.bridgedTokens(L1_TOKEN)), address(token));
        assertEq(token.balanceOf(bob), 150 ether);
    }

    function test_onDomainMessage_onlySpoke() public {
        vm.expectRevert("DomainBridge: not spoke");
        bridge.onDomainMessage(uint64(block.chainid), L1_BRIDGE, MessageLib.encodeTransfer(bob, L1_TOKEN, 100 ether));
    }

    function test_onDomainMessage_rejectsForgedFrom() public {
        vm.prank(address(spoke));
        vm.expectRevert("DomainBridge: not from L1 bridge");
        bridge.onDomainMessage(
            uint64(block.chainid), makeAddr("attacker"), MessageLib.encodeTransfer(bob, L1_TOKEN, 100 ether)
        );
    }

    function test_deposit_fromForgedSenderFailsDelivery() public {
        // A message from anyone but the counterpart L1Bridge is marked failed, nothing minted.
        bytes32 messageHash = _deliverDeposit(makeAddr("attacker"), bob, L1_TOKEN, 100 ether);

        assertTrue(spoke.failedL1Messages(messageHash));
        assertEq(address(bridge.bridgedTokens(L1_TOKEN)), address(0));
    }

    function test_constructor_rejectsZeroL1Bridge() public {
        vm.expectRevert("DomainBridge: zero L1 bridge");
        new DomainBridge(spoke, address(0));
    }

    // ---------------------------------------------------------------------
    // bridgeToL1
    // ---------------------------------------------------------------------

    /// @dev Delivers a 100-token deposit to bob and returns the bridged token.
    function _depositedToken() internal returns (BridgedERC20 token) {
        _deliverDeposit(L1_BRIDGE, bob, L1_TOKEN, 100 ether);
        token = bridge.bridgedTokens(L1_TOKEN);
    }

    function test_bridgeToL1_burnsAndSendsMessage() public {
        BridgedERC20 token = _depositedToken();

        vm.expectEmit(address(bridge));
        emit DomainBridge.WithdrawalInitiated(bob, bob, L1_TOKEN, 40 ether);
        vm.prank(bob);
        bridge.bridgeToL1(bob, L1_TOKEN, 40 ether);

        assertEq(token.balanceOf(bob), 60 ether);
        assertEq(token.totalSupply(), 60 ether);

        // The recorded message: from this bridge, to the L1 bridge, transfer payload.
        bytes32 expectedHash = MessageLib.hashDomainMessage(
            MessageLib.DomainMessage({
                sourceChainId: CHAIN_ID,
                destinationChainId: uint64(block.chainid),
                from: address(bridge),
                to: L1_BRIDGE,
                data: MessageLib.encodeTransfer(bob, L1_TOKEN, 40 ether),
                sourceNonce: 0
            }),
            block.chainid,
            spoke.HUB()
        );
        assertEq(spoke.domainMessageIds(0), expectedHash);
        assertEq(spoke.domainMessageCount(), 1);
    }

    function test_bridgeToL1_rejectsUnknownToken() public {
        vm.prank(bob);
        vm.expectRevert("DomainBridge: unknown token");
        bridge.bridgeToL1(bob, makeAddr("neverBridged"), 1 ether);
    }

    function test_bridgeToL1_rejectsZeroRecipient() public {
        _depositedToken();
        vm.prank(bob);
        vm.expectRevert("DomainBridge: zero recipient");
        bridge.bridgeToL1(address(0), L1_TOKEN, 1 ether);
    }

    function test_bridgeToL1_rejectsZeroAmount() public {
        _depositedToken();
        vm.prank(bob);
        vm.expectRevert("DomainBridge: zero amount");
        bridge.bridgeToL1(bob, L1_TOKEN, 0);
    }

    function test_bridgeToL1_rejectsInsufficientBalance() public {
        _depositedToken();
        vm.prank(bob);
        vm.expectRevert(); // ERC20InsufficientBalance
        bridge.bridgeToL1(bob, L1_TOKEN, 101 ether);
    }
}
