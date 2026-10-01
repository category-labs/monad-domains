// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BridgedERC20} from "../../src/bridge/BridgedERC20.sol";

contract BridgedERC20Test is Test {
    address internal constant L1_TOKEN = address(0x70CE2);

    BridgedERC20 internal token;
    address internal alice = makeAddr("alice");

    function setUp() public {
        // The test contract plays the bridge (deployer = bridge).
        token = new BridgedERC20(L1_TOKEN, "Bridged Test", "BRG", 6);
    }

    function test_metadata() public view {
        assertEq(token.BRIDGE(), address(this));
        assertEq(token.L1_TOKEN(), L1_TOKEN);
        assertEq(token.name(), "Bridged Test");
        assertEq(token.symbol(), "BRG");
        assertEq(token.decimals(), 6);
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
        vm.expectRevert("BridgedERC20: not bridge");
        token.mint(alice, 1);
    }

    function test_burn_rejectsNonBridge() public {
        token.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert("BridgedERC20: not bridge");
        token.burn(alice, 1);
    }
}
