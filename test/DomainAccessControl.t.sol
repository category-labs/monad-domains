// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DomainSpoke} from "../src/DomainSpoke.sol";
import {IDomainAccessControl} from "../src/interfaces/IDomainAccessControl.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {DomainTestBase} from "./helpers/DomainTestBase.sol";

contract DeploymentOwnershipExample {
    address public immutable owner;
    address public immutable constructorSender;

    constructor(address initialOwner) {
        owner = initialOwner;
        constructorSender = msg.sender;
    }
}

contract DomainAccessControlTest is DomainTestBase {
    DomainSpoke internal spoke;
    address internal token;
    address internal policyOwner = makeAddr("policyOwner");
    address internal deployer = makeAddr("deployer");
    address internal outsider = makeAddr("outsider");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal reader = makeAddr("reader");
    bytes4 internal constant BALANCE_OF = IERC20.balanceOf.selector;
    bytes4 internal constant ALLOWANCE = IERC20.allowance.selector;
    bytes4 internal constant TOTAL_SUPPLY = IERC20.totalSupply.selector;
    IDomainAccessControl.AccessMode internal constant OPEN = IDomainAccessControl.AccessMode.Open;
    IDomainAccessControl.AccessMode internal constant SUBJECT_MATCH = IDomainAccessControl.AccessMode.SubjectMatch;
    IDomainAccessControl.AccessMode internal constant READERS_ONLY = IDomainAccessControl.AccessMode.ReadersOnly;

    function setUp() public {
        spoke = new DomainSpoke(7777, block.chainid, address(0x1234));
        vm.prank(deployer);
        token = spoke.deployContract(type(TestERC20).creationCode, policyOwner);
    }

    function _rule(address target, bytes4 selector, IDomainAccessControl.AccessMode mode, uint16 index) internal {
        vm.prank(policyOwner);
        spoke.setAccessControl(target, selector, mode, index);
    }

    function _reader(address target, bytes4 selector, address account, bool allowed) internal {
        vm.prank(policyOwner);
        spoke.setReaderAllowed(target, selector, account, allowed);
    }

    function _balance(address subject) internal pure returns (bytes memory) {
        return abi.encodeCall(IERC20.balanceOf, (subject));
    }

    function _assertRule(bytes4 selector, IDomainAccessControl.AccessMode mode, uint16 index) internal view {
        (IDomainAccessControl.AccessMode storedMode, uint16 storedIndex) = spoke.accessControl(token, selector);
        assertEq(uint8(storedMode), uint8(mode));
        assertEq(storedIndex, index);
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
        spoke.setAccessControl(deployed, BALANCE_OF, SUBJECT_MATCH, 0);
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
        spoke.setAccessControl(other, BALANCE_OF, SUBJECT_MATCH, 0);
        vm.expectRevert("DomainSpoke: not policy owner");
        vm.prank(bob);
        spoke.setAccessControl(token, BALANCE_OF, OPEN, 0);
    }

    function test_deployerAndOutsiderHaveNoImplicitConfigurationAuthority() public {
        vm.startPrank(deployer);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setAccessControl(token, BALANCE_OF, SUBJECT_MATCH, 0);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setReaderAllowed(token, BALANCE_OF, reader, true);
        vm.stopPrank();
        vm.prank(outsider);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setAccessControl(token, BALANCE_OF, SUBJECT_MATCH, 0);
    }

    function testFuzz_onlyPolicyOwnerCanConfigureRulesAndReaders(address stranger) public {
        vm.assume(stranger != policyOwner);
        _rule(token, BALANCE_OF, SUBJECT_MATCH, 0);
        _reader(token, BALANCE_OF, reader, true);
        vm.startPrank(stranger);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setAccessControl(token, BALANCE_OF, SUBJECT_MATCH, 1);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setAccessControl(token, BALANCE_OF, OPEN, 0);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setReaderAllowed(token, BALANCE_OF, stranger, true);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setReaderAllowed(token, BALANCE_OF, reader, false);
        vm.stopPrank();
    }

    function test_cannotConfigureIndependentlyDeployedTarget() public {
        vm.prank(policyOwner);
        address independent = address(new TestERC20());
        assertEq(spoke.policyOwners(independent), address(0));
        vm.startPrank(policyOwner);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setAccessControl(independent, BALANCE_OF, SUBJECT_MATCH, 0);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setReaderAllowed(independent, BALANCE_OF, reader, true);
        vm.stopPrank();
    }

    function test_unconfiguredCallsAreAllowed() public view {
        assertTrue(spoke.canCall(bob, token, _balance(alice)));
        assertTrue(spoke.canCall(bob, alice, hex""));
    }

    function test_subjectMatchAllowsSubjectAndApprovedReaders() public {
        _rule(token, BALANCE_OF, SUBJECT_MATCH, 0);
        _reader(token, BALANCE_OF, reader, true);
        _assertRule(BALANCE_OF, SUBJECT_MATCH, 0);
        assertTrue(spoke.approvedReaders(token, BALANCE_OF, reader));
        assertTrue(spoke.canCall(alice, token, _balance(alice)));
        assertTrue(spoke.canCall(bob, token, _balance(bob)));
        assertTrue(spoke.canCall(reader, token, _balance(alice)));
        assertTrue(spoke.canCall(reader, token, _balance(bob)));
        assertTrue(spoke.canCall(reader, token, abi.encodePacked(BALANCE_OF)));
        assertFalse(spoke.canCall(bob, token, _balance(alice)));
        // Query sender cannot substitute for the explicit caller being evaluated.
        vm.prank(reader);
        assertFalse(spoke.canCall(bob, token, _balance(alice)));
        // Neither the policyOwner nor an unrelated account gets an implicit reader grant.
        assertFalse(spoke.canCall(policyOwner, token, _balance(alice)));
        assertFalse(spoke.canCall(outsider, token, _balance(alice)));
    }

    function test_readersOnlyAllowsOnlyApprovedReaders() public {
        bytes memory data = abi.encodeCall(IERC20.totalSupply, ());
        _rule(token, TOTAL_SUPPLY, READERS_ONLY, 7);
        _assertRule(TOTAL_SUPPLY, READERS_ONLY, 0);
        assertFalse(spoke.canCall(alice, token, data));
        assertFalse(spoke.canCall(alice, token, abi.encodePacked(TOTAL_SUPPLY, abi.encode(alice))));
        assertFalse(spoke.canCall(policyOwner, token, data));
        _reader(token, TOTAL_SUPPLY, reader, true);
        assertTrue(spoke.canCall(reader, token, data));
        // The subject argument is ignored, so even the subject is denied.
        _rule(token, BALANCE_OF, READERS_ONLY, 0);
        assertFalse(spoke.canCall(alice, token, _balance(alice)));
    }

    function test_rulesAndGrantsAreScopedToTargetAndSelector() public {
        address other = spoke.deployContract(type(TestERC20).creationCode, policyOwner);
        _rule(token, BALANCE_OF, SUBJECT_MATCH, 0);
        _rule(other, BALANCE_OF, SUBJECT_MATCH, 0);
        _rule(token, ALLOWANCE, SUBJECT_MATCH, 0);
        _reader(token, BALANCE_OF, reader, true);
        assertTrue(spoke.canCall(reader, token, _balance(alice)));
        assertFalse(spoke.canCall(reader, other, _balance(alice)));
        assertFalse(spoke.canCall(reader, token, abi.encodeCall(IERC20.allowance, (alice, bob))));
        assertTrue(spoke.canCall(reader, token, abi.encodeCall(IERC20.totalSupply, ())));
    }

    function test_policyOwnerCanRevokeReaderWithoutBlockingSubject() public {
        _rule(token, BALANCE_OF, SUBJECT_MATCH, 0);
        _reader(token, BALANCE_OF, reader, true);
        assertTrue(spoke.canCall(reader, token, _balance(alice)));
        _reader(token, BALANCE_OF, reader, false);
        assertFalse(spoke.approvedReaders(token, BALANCE_OF, reader));
        assertFalse(spoke.canCall(reader, token, _balance(alice)));
        assertTrue(spoke.canCall(alice, token, _balance(alice)));
    }

    function test_policyOwnerCanChangeArgumentAndDisableRestriction() public {
        bytes memory data = abi.encodeCall(IERC20.allowance, (alice, bob));
        _rule(token, ALLOWANCE, SUBJECT_MATCH, 1);
        _assertRule(ALLOWANCE, SUBJECT_MATCH, 1);
        assertTrue(spoke.canCall(bob, token, data));
        assertFalse(spoke.canCall(alice, token, data));
        _rule(token, ALLOWANCE, SUBJECT_MATCH, 0);
        assertTrue(spoke.canCall(alice, token, data));
        assertFalse(spoke.canCall(bob, token, data));
        _rule(token, ALLOWANCE, OPEN, 42);
        _assertRule(ALLOWANCE, OPEN, 0);
        assertTrue(spoke.canCall(reader, token, data));
    }

    function test_readerGrantsPersistAcrossModeChanges() public {
        _rule(token, BALANCE_OF, SUBJECT_MATCH, 0);
        _reader(token, BALANCE_OF, reader, true);
        _rule(token, BALANCE_OF, OPEN, 0);
        assertTrue(spoke.canCall(bob, token, _balance(alice)));
        _rule(token, BALANCE_OF, READERS_ONLY, 0);
        assertTrue(spoke.canCall(reader, token, _balance(alice)));
        assertFalse(spoke.canCall(alice, token, _balance(alice)));
    }

    function test_delegateCallChecksOnlyContextWhileDirectCallChecksImplementation() public {
        address implementation = spoke.deployContract(type(TestERC20).creationCode, policyOwner);
        bytes memory data = abi.encodeCall(IERC20.allowance, (alice, bob));
        _rule(token, ALLOWANCE, SUBJECT_MATCH, 0);
        _rule(implementation, ALLOWANCE, SUBJECT_MATCH, 1);

        // Delegated code uses the token's storage and its first-argument rule.
        assertTrue(spoke.canCall(alice, token, data));
        assertFalse(spoke.canCall(bob, token, data));
        // Calling the implementation directly uses its own second-argument rule.
        assertFalse(spoke.canCall(alice, implementation, data));
        assertTrue(spoke.canCall(bob, implementation, data));

        // Implementation reader grants have no effect on delegated execution.
        _reader(implementation, ALLOWANCE, reader, true);
        assertTrue(spoke.canCall(reader, implementation, data));
        assertFalse(spoke.canCall(reader, token, data));
        _reader(token, ALLOWANCE, reader, true);
        assertTrue(spoke.canCall(reader, token, data));

        // An unrestricted context stays open even if the implementation restricts access.
        _rule(token, ALLOWANCE, OPEN, 0);
        assertTrue(spoke.canCall(policyOwner, token, data));
        assertFalse(spoke.canCall(policyOwner, implementation, data));
    }

    function test_zeroSelectorRestrictionDeniesShortCalldata() public {
        _rule(token, bytes4(0), SUBJECT_MATCH, 0);
        assertFalse(spoke.canCall(alice, token, hex""));
        assertFalse(spoke.canCall(alice, token, hex"12"));
        assertFalse(spoke.canCall(alice, token, hex"1234"));
        assertFalse(spoke.canCall(alice, token, hex"123456"));
        assertFalse(spoke.canCall(alice, token, hex"00000000"));
        assertTrue(spoke.canCall(alice, token, abi.encodePacked(bytes4(0), abi.encode(alice))));
        assertTrue(spoke.canCall(alice, token, hex"12345678"));
    }

    function testFuzz_malformedSubjectDeniesWithoutReverting(address subject, uint96 highBits, uint8 length) public {
        _rule(token, BALANCE_OF, SUBJECT_MATCH, 0);
        assertTrue(spoke.canCall(subject, token, _balance(subject)));
        uint256 word = (uint256(highBits) << 160) | uint160(subject);
        bytes memory encoded = abi.encodePacked(BALANCE_OF, word);
        assertEq(spoke.canCall(subject, token, encoded), highBits == 0);
        bytes memory truncated = abi.encodePacked(BALANCE_OF, new bytes(uint256(length) % 32));
        assertFalse(spoke.canCall(subject, token, truncated));
    }

    function test_maximumArgumentIndexDeniesShortInputWithoutOverflow() public {
        _rule(token, BALANCE_OF, SUBJECT_MATCH, type(uint16).max);
        assertFalse(spoke.canCall(alice, token, _balance(alice)));
    }

    function test_unknownAccessModeReverts() public {
        bytes memory data =
            abi.encodeWithSelector(spoke.setAccessControl.selector, token, BALANCE_OF, uint8(3), uint16(0));
        vm.prank(policyOwner);
        (bool ok,) = address(spoke).call(data);
        assertFalse(ok);
    }
}
