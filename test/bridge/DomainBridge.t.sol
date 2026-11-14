// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BridgedERC20} from "../../src/bridge/BridgedERC20.sol";
import {DomainBridge} from "../../src/bridge/DomainBridge.sol";
import {MessageLib} from "../../src/libraries/MessageLib.sol";
import {DomainSpoke} from "../../src/DomainSpoke.sol";
import {DomainTestBase} from "../helpers/DomainTestBase.sol";
import {DomainAccessRules} from "../../src/access/DomainAccessRules.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract DomainBridgeTest is DomainTestBase {
    address internal constant L1_BRIDGE = address(0x11B41D6E);
    address internal constant L1_TOKEN = address(0x70CE2);
    uint64 internal constant CHAIN_ID = 7777;

    DomainSpoke internal spoke;
    DomainBridge internal bridge;
    address internal policyOwner = makeAddr("policyOwner");
    address internal initialPolicy;

    address internal bob = makeAddr("bob");

    function setUp() public {
        spoke = new DomainSpoke(CHAIN_ID, block.chainid, address(0x1234));
        initialPolicy = address(new DomainAccessRules(spoke));
        bridge = new DomainBridge(spoke, L1_BRIDGE, policyOwner, initialPolicy);
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
        assertEq(token.BRIDGE(), address(bridge));
        assertEq(spoke.policyOwners(address(token)), policyOwner);
        assertEq(spoke.accessPolicies(address(token)), initialPolicy);
        assertTrue(spoke.canCall(bob, address(token), abi.encodeCall(IERC20.balanceOf, (bob))));
        assertTrue(spoke.canCall(policyOwner, address(token), abi.encodeCall(IERC20.balanceOf, (bob))));
    }

    function test_deposit_reusesDeployedToken() public {
        _deliverDeposit(L1_BRIDGE, bob, L1_TOKEN, 100 ether);
        BridgedERC20 token = bridge.bridgedTokens(L1_TOKEN);

        address replacementPolicy = address(new DomainAccessRules(spoke));
        vm.prank(policyOwner);
        spoke.setAccessPolicy(address(token), replacementPolicy);
        bytes32 messageHash = _deliverDeposit(L1_BRIDGE, policyOwner, L1_TOKEN, 50 ether);

        assertFalse(spoke.failedL1Messages(messageHash));
        assertEq(address(bridge.bridgedTokens(L1_TOKEN)), address(token));
        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.balanceOf(policyOwner), 50 ether);
        assertEq(spoke.policyOwners(address(token)), policyOwner);
        assertEq(spoke.accessPolicies(address(token)), replacementPolicy);
    }

    function test_onDomainMessage_onlySpoke() public {
        vm.expectRevert(DomainBridge.NotSpoke.selector);
        bridge.onDomainMessage(uint64(block.chainid), L1_BRIDGE, MessageLib.encodeTransfer(bob, L1_TOKEN, 100 ether));
    }

    function test_onDomainMessage_rejectsForgedFrom() public {
        vm.prank(address(spoke));
        vm.expectRevert(DomainBridge.NotL1Bridge.selector);
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
        vm.expectRevert(DomainBridge.ZeroL1Bridge.selector);
        new DomainBridge(spoke, address(0), policyOwner, initialPolicy);
    }

    function test_constructor_rejectsInvalidPolicyConfiguration() public {
        vm.expectRevert(DomainBridge.ZeroPolicyOwner.selector);
        new DomainBridge(spoke, L1_BRIDGE, address(0), initialPolicy);
        vm.expectRevert(DomainBridge.PolicyHasNoCode.selector);
        new DomainBridge(spoke, L1_BRIDGE, policyOwner, address(0));
        vm.expectRevert(DomainBridge.PolicyHasNoCode.selector);
        new DomainBridge(spoke, L1_BRIDGE, policyOwner, bob);
        vm.expectRevert(DomainBridge.InvalidTokenPolicy.selector);
        new DomainBridge(spoke, L1_BRIDGE, policyOwner, address(spoke));
        vm.expectRevert(DomainBridge.SpokeHasNoCode.selector);
        new DomainBridge(DomainSpoke(address(0)), L1_BRIDGE, policyOwner, initialPolicy);
    }

    function test_deposit_registersDifferentAssetsWithConfiguredOwnerAndPolicy() public {
        address otherAsset = makeAddr("otherAsset");
        _deliverDeposit(L1_BRIDGE, bob, L1_TOKEN, 100 ether);
        _deliverDeposit(L1_BRIDGE, bob, otherAsset, 10 ether);
        address first = address(bridge.bridgedTokens(L1_TOKEN));
        address second = address(bridge.bridgedTokens(otherAsset));
        assertTrue(first != second);
        assertEq(spoke.policyOwners(first), policyOwner);
        assertEq(spoke.policyOwners(second), policyOwner);
        assertEq(spoke.accessPolicies(first), initialPolicy);
        assertEq(spoke.accessPolicies(second), initialPolicy);
    }

    function test_deposit_deploysAtPredictedCreate2Address() public {
        bytes memory initCode = abi.encodePacked(
            type(BridgedERC20).creationCode,
            abi.encode(
                L1_TOKEN,
                string.concat("Bridged ", Strings.toHexString(L1_TOKEN)),
                "BRG",
                uint8(18),
                spoke,
                policyOwner,
                initialPolicy
            )
        );
        address predicted =
            vm.computeCreate2Address(bytes32(uint256(uint160(L1_TOKEN))), keccak256(initCode), address(bridge));
        _deliverDeposit(L1_BRIDGE, bob, L1_TOKEN, 100 ether);
        assertEq(address(bridge.bridgedTokens(L1_TOKEN)), predicted);
        assertEq(spoke.policyOwners(predicted), policyOwner);
    }

    function test_deposit_registrationFailureRollsBackAndCanBeRetried() public {
        bytes memory policyCode = initialPolicy.code;
        vm.etch(initialPolicy, hex"");
        bytes32 messageHash = _deliverDeposit(L1_BRIDGE, bob, L1_TOKEN, 100 ether);
        assertTrue(spoke.failedL1Messages(messageHash));
        assertEq(address(bridge.bridgedTokens(L1_TOKEN)), address(0));

        vm.etch(initialPolicy, policyCode);
        spoke.retryL1Message(
            MessageLib.Message(
                uint64(block.chainid),
                L1_BRIDGE,
                address(bridge),
                MessageLib.encodeTransfer(bob, L1_TOKEN, 100 ether),
                0
            )
        );
        assertFalse(spoke.failedL1Messages(messageHash));
        BridgedERC20 token = bridge.bridgedTokens(L1_TOKEN);
        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(spoke.policyOwners(address(token)), policyOwner);
        assertEq(spoke.accessPolicies(address(token)), initialPolicy);
    }

    function test_policyOwnerCanConfigureRulesAndLogReadersForBridgedToken() public {
        BridgedERC20 token = _depositedToken();
        DomainAccessRules rules = DomainAccessRules(initialPolicy);
        address reader = makeAddr("reader");
        bytes memory query = abi.encodeCall(IERC20.balanceOf, (bob));

        vm.startPrank(bob);
        vm.expectRevert(DomainSpoke.NotPolicyOwner.selector);
        spoke.setAccessPolicy(address(token), address(rules));
        vm.expectRevert(DomainSpoke.NotPolicyOwner.selector);
        spoke.setLogReader(address(token), bob, true);
        vm.expectRevert(DomainAccessRules.NotPolicyOwner.selector);
        rules.setAccessControl(address(token), IERC20.balanceOf.selector, DomainAccessRules.AccessMode.Open, 0);
        vm.stopPrank();

        vm.startPrank(policyOwner);
        rules.setAccessControl(address(token), IERC20.balanceOf.selector, DomainAccessRules.AccessMode.SubjectMatch, 1);
        rules.setAccessControl(address(token), IERC20.allowance.selector, DomainAccessRules.AccessMode.SubjectMatch, 3);
        spoke.setAccessPolicy(address(token), address(rules));
        assertFalse(spoke.canCall(policyOwner, address(token), query));
        rules.setReaderAllowed(address(token), IERC20.balanceOf.selector, reader, true);
        spoke.setLogReader(address(token), reader, true);
        vm.stopPrank();
        assertTrue(spoke.canCall(reader, address(token), query));
        assertTrue(spoke.logReaders(address(token), reader));
        assertFalse(spoke.canCall(policyOwner, address(token), query));
    }

    function test_configuredPolicyAllowsTransfersAndBridgeCallsButRestrictsReads() public {
        BridgedERC20 token = _depositedToken();
        DomainAccessRules rules = DomainAccessRules(initialPolicy);
        vm.startPrank(policyOwner);
        rules.setAccessControl(address(token), IERC20.balanceOf.selector, DomainAccessRules.AccessMode.SubjectMatch, 1);
        rules.setAccessControl(address(token), IERC20.allowance.selector, DomainAccessRules.AccessMode.SubjectMatch, 3);
        vm.stopPrank();
        assertTrue(spoke.canCall(bob, address(token), abi.encodeCall(IERC20.balanceOf, (bob))));
        assertFalse(spoke.canCall(policyOwner, address(token), abi.encodeCall(IERC20.balanceOf, (bob))));
        address spender = makeAddr("spender");
        bytes memory allowanceQuery = abi.encodeCall(IERC20.allowance, (bob, spender));
        assertTrue(spoke.canCall(bob, address(token), allowanceQuery));
        assertTrue(spoke.canCall(spender, address(token), allowanceQuery));
        assertFalse(spoke.canCall(policyOwner, address(token), allowanceQuery));
        assertTrue(spoke.canCall(address(bridge), address(token), abi.encodeCall(token.mint, (bob, 1))));
        assertTrue(spoke.canCall(address(bridge), address(token), abi.encodeCall(token.burn, (bob, 1))));

        bytes memory transfer = abi.encodeCall(IERC20.transfer, (spender, 10 ether));
        assertTrue(spoke.canCall(bob, address(token), transfer));
        vm.prank(bob);
        token.transfer(spender, 10 ether);
        vm.prank(bob);
        token.approve(spender, 5 ether);
        assertTrue(spoke.canCall(spender, address(token), abi.encodeCall(IERC20.transferFrom, (bob, spender, 5 ether))));
        vm.prank(spender);
        token.transferFrom(bob, spender, 5 ether);
        assertEq(token.balanceOf(spender), 15 ether);
        vm.prank(spender);
        vm.expectRevert(BridgedERC20.NotBridge.selector);
        token.mint(spender, 1);
        vm.prank(spender);
        vm.expectRevert(BridgedERC20.NotBridge.selector);
        token.burn(bob, 1);
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
        bridge.bridgeToL1(bob, L1_TOKEN, 40 ether, TEST_SALT);

        assertEq(token.balanceOf(bob), 60 ether);
        assertEq(token.totalSupply(), 60 ether);

        // The recorded message: from this bridge, to the L1 bridge, transfer payload.
        bytes32 expectedHash = MessageLib.hashDomainMessage(
            MessageLib.DomainMessage({
                kind: MessageLib.MessageKind.Plain,
                sourceChainId: CHAIN_ID,
                destinationChainId: uint64(block.chainid),
                from: address(bridge),
                to: L1_BRIDGE,
                data: MessageLib.encodeTransfer(bob, L1_TOKEN, 40 ether),
                salt: TEST_SALT,
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
        vm.expectRevert(DomainBridge.UnknownToken.selector);
        bridge.bridgeToL1(bob, makeAddr("neverBridged"), 1 ether, TEST_SALT);
    }

    function test_bridgeToL1_zeroSaltDoesNotBurn() public {
        BridgedERC20 token = _depositedToken();
        vm.prank(bob);
        vm.expectRevert(DomainSpoke.ZeroSalt.selector);
        bridge.bridgeToL1(bob, L1_TOKEN, 40 ether, bytes32(0));
        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.totalSupply(), 100 ether);
        assertEq(spoke.domainMessageCount(), 0);
    }

    function test_bridgeToL1_rejectsZeroRecipient() public {
        _depositedToken();
        vm.prank(bob);
        vm.expectRevert(DomainBridge.ZeroRecipient.selector);
        bridge.bridgeToL1(address(0), L1_TOKEN, 1 ether, TEST_SALT);
    }

    function test_bridgeToL1_rejectsZeroAmount() public {
        _depositedToken();
        vm.prank(bob);
        vm.expectRevert(DomainBridge.ZeroAmount.selector);
        bridge.bridgeToL1(bob, L1_TOKEN, 0, TEST_SALT);
    }

    function test_bridgeToL1_rejectsInsufficientBalance() public {
        _depositedToken();
        vm.prank(bob);
        vm.expectRevert(); // ERC20InsufficientBalance
        bridge.bridgeToL1(bob, L1_TOKEN, 101 ether, TEST_SALT);
    }
}
