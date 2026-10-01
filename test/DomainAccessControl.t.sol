// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DomainSpoke} from "../src/DomainSpoke.sol";
import {IDomainAccessControl} from "../src/interfaces/IDomainAccessControl.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

contract DeploymentOwnershipExample {
    address public immutable owner;
    address public immutable constructorSender;

    constructor(address initialOwner) {
        owner = initialOwner;
        constructorSender = msg.sender;
    }
}

contract DomainAccessControlTest is Test {
    DomainSpoke internal spoke;
    address internal token;
    address internal policyOwner = makeAddr("policyOwner");
    address internal deployer = makeAddr("deployer");
    address internal operator = makeAddr("operator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal reader = makeAddr("reader");
    bytes4 internal constant BALANCE_OF = IERC20.balanceOf.selector;

    function setUp() public {
        spoke = new DomainSpoke(7777, operator, block.chainid, address(0x1234));
        vm.prank(deployer);
        token = spoke.deployContract(type(TestERC20).creationCode, policyOwner);
    }

    function _restrict(address target, bytes4 selector, uint16 index) internal {
        vm.prank(policyOwner);
        spoke.setAccessControl(target, selector, true, index);
    }

    function _reader(address target, bytes4 selector, address subject, address account, bool allowed) internal {
        vm.prank(policyOwner);
        spoke.setReaderAllowed(target, selector, subject, account, allowed);
    }

    function _balance(address subject) internal pure returns (bytes memory) {
        return abi.encodeCall(IERC20.balanceOf, (subject));
    }

    function test_deploymentAssignsExplicitPolicyOwnerAndInstallsCode() public view {
        assertEq(spoke.policyOwners(token), policyOwner);
        assertTrue(token.code.length > 0);
        assertEq(TestERC20(token).name(), "Test Token");
        assertEq(TestERC20(token).symbol(), "TEST");
    }

    function test_deploymentEmitsCallerAndAssignedOwner() public {
        vm.expectEmit(false, true, true, true, address(spoke));
        emit IDomainAccessControl.ContractDeployed(address(0), deployer, bob);
        vm.prank(deployer);
        address deployed = spoke.deployContract(type(TestERC20).creationCode, bob);
        assertEq(spoke.policyOwners(deployed), bob);
    }

    function test_deploymentSeparatesPolicyOwnerFromConstructorOwner() public {
        bytes memory initCode = abi.encodePacked(type(DeploymentOwnershipExample).creationCode, abi.encode(alice));
        vm.prank(deployer);
        address deployed = spoke.deployContract(initCode, policyOwner);
        assertEq(spoke.policyOwners(deployed), policyOwner);
        assertEq(DeploymentOwnershipExample(deployed).owner(), alice);
        assertEq(DeploymentOwnershipExample(deployed).constructorSender(), address(spoke));
        vm.expectRevert("DomainSpoke: not policy owner");
        vm.prank(alice);
        spoke.setAccessControl(deployed, BALANCE_OF, true, 0);
    }

    function test_deploymentRejectsZeroPolicyOwnerBeforeCreatingContract() public {
        uint64 nonce = vm.getNonce(address(spoke));
        vm.expectRevert("DomainSpoke: zero policy owner");
        spoke.deployContract(type(TestERC20).creationCode, address(0));
        assertEq(vm.getNonce(address(spoke)), nonce);
    }

    function test_failedAndEmptyCodeDeploymentsRevertAndRestoreNonce() public {
        uint64 nonce = vm.getNonce(address(spoke));
        vm.expectRevert("DomainSpoke: deployment failed");
        spoke.deployContract(hex"60006000fd", policyOwner); // constructor reverts
        assertEq(vm.getNonce(address(spoke)), nonce);
        vm.expectRevert("DomainSpoke: deployment failed");
        spoke.deployContract(hex"", policyOwner);
        assertEq(vm.getNonce(address(spoke)), nonce);
        vm.expectRevert("DomainSpoke: deployment failed");
        spoke.deployContract(hex"60006000f3", policyOwner); // constructor returns no runtime code
        assertEq(vm.getNonce(address(spoke)), nonce);
    }

    function test_repeatedDeploymentsHaveIndependentOwners() public {
        vm.prank(deployer);
        address other = spoke.deployContract(type(TestERC20).creationCode, bob);
        assertTrue(other != token);
        assertEq(spoke.policyOwners(token), policyOwner);
        assertEq(spoke.policyOwners(other), bob);
        vm.prank(bob);
        spoke.setAccessControl(other, BALANCE_OF, true, 0);
        vm.expectRevert("DomainSpoke: not policy owner");
        vm.prank(bob);
        spoke.setAccessControl(token, BALANCE_OF, false, 0);
    }

    function test_deployerAndOperatorHaveNoImplicitConfigurationAuthority() public {
        vm.startPrank(deployer);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setAccessControl(token, BALANCE_OF, true, 0);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setReaderAllowed(token, BALANCE_OF, alice, reader, true);
        vm.stopPrank();
        vm.prank(operator);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setAccessControl(token, BALANCE_OF, true, 0);
    }

    function testFuzz_onlyPolicyOwnerCanConfigureRulesAndReaders(address stranger) public {
        vm.assume(stranger != policyOwner);
        _restrict(token, BALANCE_OF, 0);
        _reader(token, BALANCE_OF, alice, reader, true);
        vm.startPrank(stranger);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setAccessControl(token, BALANCE_OF, true, 1);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setAccessControl(token, BALANCE_OF, false, 0);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setReaderAllowed(token, BALANCE_OF, alice, stranger, true);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setReaderAllowed(token, BALANCE_OF, alice, reader, false);
        vm.stopPrank();
    }

    function test_cannotConfigureIndependentlyDeployedTarget() public {
        vm.prank(policyOwner);
        address independent = address(new TestERC20());
        assertEq(spoke.policyOwners(independent), address(0));
        vm.startPrank(policyOwner);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setAccessControl(independent, BALANCE_OF, true, 0);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setReaderAllowed(independent, BALANCE_OF, alice, reader, true);
        vm.stopPrank();
    }

    function test_unconfiguredCallsAreAllowed() public view {
        assertTrue(spoke.canCall(bob, token, _balance(alice)));
        assertTrue(spoke.canCall(bob, alice, hex""));
    }

    function test_ownerAndWhitelistedReaderCanReadBalance() public {
        _restrict(token, BALANCE_OF, 0);
        _reader(token, BALANCE_OF, alice, reader, true);
        (bool restricted, uint16 index) = spoke.accessControl(token, BALANCE_OF);
        assertTrue(restricted);
        assertEq(index, 0);
        assertTrue(spoke.approvedReaders(token, BALANCE_OF, alice, reader));
        assertTrue(spoke.canCall(alice, token, _balance(alice)));
        assertTrue(spoke.canCall(bob, token, _balance(bob)));
        assertTrue(spoke.canCall(reader, token, _balance(alice)));
        assertFalse(spoke.canCall(bob, token, _balance(alice)));
        assertFalse(spoke.canCall(reader, token, _balance(bob)));
        // Query sender cannot substitute for the explicit caller being evaluated.
        vm.prank(reader);
        assertFalse(spoke.canCall(bob, token, _balance(alice)));
        // Neither the policyOwner nor the operator gets an implicit reader grant.
        assertFalse(spoke.canCall(policyOwner, token, _balance(alice)));
        assertFalse(spoke.canCall(operator, token, _balance(alice)));
    }

    function test_rulesAndGrantsAreScopedToTargetSelectorAndSubject() public {
        address other = spoke.deployContract(type(TestERC20).creationCode, policyOwner);
        _restrict(token, BALANCE_OF, 0);
        _restrict(other, BALANCE_OF, 0);
        _restrict(token, IERC20.allowance.selector, 0);
        _reader(token, BALANCE_OF, alice, reader, true);
        assertTrue(spoke.canCall(reader, token, _balance(alice)));
        assertFalse(spoke.canCall(reader, other, _balance(alice)));
        assertFalse(spoke.canCall(reader, token, _balance(bob)));
        assertFalse(spoke.canCall(reader, token, abi.encodeCall(IERC20.allowance, (alice, bob))));
        assertTrue(spoke.canCall(reader, token, abi.encodeCall(IERC20.totalSupply, ())));
    }

    function test_policyOwnerCanRevokeReaderWithoutBlockingSubject() public {
        _restrict(token, BALANCE_OF, 0);
        _reader(token, BALANCE_OF, alice, reader, true);
        assertTrue(spoke.canCall(reader, token, _balance(alice)));
        _reader(token, BALANCE_OF, alice, reader, false);
        assertFalse(spoke.approvedReaders(token, BALANCE_OF, alice, reader));
        assertFalse(spoke.canCall(reader, token, _balance(alice)));
        assertTrue(spoke.canCall(alice, token, _balance(alice)));
    }

    function test_policyOwnerCanChangeArgumentAndDisableRestriction() public {
        bytes4 selector = IERC20.allowance.selector;
        bytes memory data = abi.encodeCall(IERC20.allowance, (alice, bob));
        _restrict(token, selector, 1);
        (bool restricted, uint16 index) = spoke.accessControl(token, selector);
        assertTrue(restricted);
        assertEq(index, 1);
        assertTrue(spoke.canCall(bob, token, data));
        assertFalse(spoke.canCall(alice, token, data));
        _restrict(token, selector, 0);
        assertTrue(spoke.canCall(alice, token, data));
        assertFalse(spoke.canCall(bob, token, data));
        vm.prank(policyOwner);
        spoke.setAccessControl(token, selector, false, 42);
        (restricted, index) = spoke.accessControl(token, selector);
        assertFalse(restricted);
        assertEq(index, 0);
        assertTrue(spoke.canCall(reader, token, data));
    }

    function test_readerGrantsPersistWhenRestrictionIsDisabledAndReenabled() public {
        _restrict(token, BALANCE_OF, 0);
        _reader(token, BALANCE_OF, alice, reader, true);
        vm.prank(policyOwner);
        spoke.setAccessControl(token, BALANCE_OF, false, 0);
        assertTrue(spoke.canCall(bob, token, _balance(alice)));
        _restrict(token, BALANCE_OF, 0);
        assertTrue(spoke.canCall(reader, token, _balance(alice)));
        assertFalse(spoke.canCall(bob, token, _balance(alice)));
    }

    function test_delegateCallChecksOnlyContextWhileDirectCallChecksImplementation() public {
        address implementation = spoke.deployContract(type(TestERC20).creationCode, policyOwner);
        bytes4 selector = IERC20.allowance.selector;
        bytes memory data = abi.encodeCall(IERC20.allowance, (alice, bob));
        _restrict(token, selector, 0);
        _restrict(implementation, selector, 1);

        // Delegated code uses the token's storage and its first-argument rule.
        assertTrue(spoke.canCall(alice, token, data));
        assertFalse(spoke.canCall(bob, token, data));
        // Calling the implementation directly uses its own second-argument rule.
        assertFalse(spoke.canCall(alice, implementation, data));
        assertTrue(spoke.canCall(bob, implementation, data));

        // Implementation reader grants have no effect on delegated execution.
        _reader(implementation, selector, bob, reader, true);
        assertTrue(spoke.canCall(reader, implementation, data));
        assertFalse(spoke.canCall(reader, token, data));
        _reader(token, selector, alice, reader, true);
        assertTrue(spoke.canCall(reader, token, data));

        // An unrestricted context stays open even if the implementation restricts access.
        vm.prank(policyOwner);
        spoke.setAccessControl(token, selector, false, 0);
        assertTrue(spoke.canCall(policyOwner, token, data));
        assertFalse(spoke.canCall(policyOwner, implementation, data));
    }

    function test_zeroSelectorRestrictionDeniesShortCalldata() public {
        _restrict(token, bytes4(0), 0);
        assertFalse(spoke.canCall(alice, token, hex""));
        assertFalse(spoke.canCall(alice, token, hex"12"));
        assertFalse(spoke.canCall(alice, token, hex"1234"));
        assertFalse(spoke.canCall(alice, token, hex"123456"));
        assertFalse(spoke.canCall(alice, token, hex"00000000"));
        assertTrue(spoke.canCall(alice, token, abi.encodePacked(bytes4(0), abi.encode(alice))));
        assertTrue(spoke.canCall(alice, token, hex"12345678"));
    }

    function testFuzz_malformedSubjectDeniesWithoutReverting(address subject, uint96 highBits, uint8 length) public {
        _restrict(token, BALANCE_OF, 0);
        _reader(token, BALANCE_OF, subject, reader, true);
        assertTrue(spoke.canCall(subject, token, _balance(subject)));
        uint256 word = (uint256(highBits) << 160) | uint160(subject);
        bytes memory encoded = abi.encodePacked(BALANCE_OF, word);
        assertEq(spoke.canCall(subject, token, encoded), highBits == 0);
        assertEq(spoke.canCall(reader, token, encoded), highBits == 0);
        bytes memory truncated = abi.encodePacked(BALANCE_OF, new bytes(uint256(length) % 32));
        assertFalse(spoke.canCall(subject, token, truncated));
        assertFalse(spoke.canCall(reader, token, truncated));
    }

    function test_maximumArgumentIndexDeniesShortInputWithoutOverflow() public {
        _restrict(token, BALANCE_OF, type(uint16).max);
        assertFalse(spoke.canCall(alice, token, _balance(alice)));
    }
}
