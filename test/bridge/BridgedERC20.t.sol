// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BridgedERC20} from "../../src/bridge/BridgedERC20.sol";
import {DomainSpoke} from "../../src/DomainSpoke.sol";
import {DomainAccessRules} from "../../src/access/DomainAccessRules.sol";

contract BridgedERC20Test is Test {
    address internal constant L1_TOKEN = address(0x70CE2);

    BridgedERC20 internal token;
    DomainSpoke internal spoke;
    address internal initialPolicy;
    address internal alice = makeAddr("alice");

    function setUp() public {
        // The test contract plays the bridge (deployer = bridge).
        spoke = new DomainSpoke(7777, block.chainid, address(0x1234));
        initialPolicy = address(new DomainAccessRules(spoke));
        token = new BridgedERC20(L1_TOKEN, "Bridged Test", "BRG", 6, spoke, alice, initialPolicy);
    }

    function test_metadata() public view {
        assertEq(token.BRIDGE(), address(this));
        assertEq(token.L1_TOKEN(), L1_TOKEN);
        assertEq(token.name(), "Bridged Test");
        assertEq(token.symbol(), "BRG");
        assertEq(token.decimals(), 6);
        assertEq(spoke.policyOwners(address(token)), alice);
        assertEq(spoke.accessPolicies(address(token)), initialPolicy);
    }

    function test_mintAndBurn_asBridge() public {
        token.mint(alice, 100e6);
        assertEq(token.balanceOf(alice), 100e6);
        token.burn(alice, 40e6);
        assertEq(token.balanceOf(alice), 60e6);
        assertEq(token.totalSupply(), 60e6);
    }

    function test_mint_rejectsNonBridge() public {
        vm.prank(alice);
        vm.expectRevert(BridgedERC20.NotBridge.selector);
        token.mint(alice, 1);
    }

    function test_burn_rejectsNonBridge() public {
        token.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(BridgedERC20.NotBridge.selector);
        token.burn(alice, 1);
    }
}
