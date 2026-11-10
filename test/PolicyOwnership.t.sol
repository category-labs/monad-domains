// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DomainSpoke} from "../src/DomainSpoke.sol";
import {IDomainAccessControl} from "../src/interfaces/IDomainAccessControl.sol";
import {DomainAccessRules} from "../src/access/DomainAccessRules.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

contract PolicyOwnerReceiver {
    function accept(IDomainAccessControl spoke, address target) external {
        spoke.acceptPolicyOwnership(target);
    }
}

contract PolicyOwnershipTest is Test {
    DomainSpoke internal spoke;
    DomainAccessRules internal rules;
    address internal target;
    address internal owner = makeAddr("owner");
    address internal nextOwner = makeAddr("nextOwner");
    address internal outsider = makeAddr("outsider");
    address internal reader = makeAddr("reader");
    address internal holder = makeAddr("holder");

    function setUp() public {
        spoke = new DomainSpoke(7777, block.chainid, address(0x1234));
        rules = new DomainAccessRules(spoke);
        target = spoke.deployContract(type(TestERC20).creationCode, owner);
        vm.startPrank(owner);
        spoke.setAccessPolicy(target, address(rules));
        rules.setAccessControl(target, IERC20.balanceOf.selector, DomainAccessRules.AccessMode.SubjectMatch, 1);
        rules.setReaderAllowed(target, IERC20.balanceOf.selector, reader, true);
        spoke.setLogReader(target, reader, true);
        spoke.setLogReader(target, owner, true);
        vm.stopPrank();
    }

    function _nominate(address nominee) internal {
        vm.prank(owner);
        spoke.transferPolicyOwnership(target, nominee);
    }

    function _accept(address nominee) internal {
        vm.prank(nominee);
        spoke.acceptPolicyOwnership(target);
    }

    function _assertCannotAdminister(address caller) internal {
        vm.startPrank(caller);
        vm.expectRevert(DomainSpoke.NotPolicyOwner.selector);
        spoke.transferPolicyOwnership(target, address(0));
        vm.expectRevert(DomainSpoke.NotPolicyOwner.selector);
        spoke.setAccessPolicy(target, address(0));
        vm.expectRevert(DomainSpoke.NotPolicyOwner.selector);
        spoke.setLogReader(target, outsider, true);
        vm.expectRevert(DomainAccessRules.NotPolicyOwner.selector);
        rules.setAccessControl(target, IERC20.balanceOf.selector, DomainAccessRules.AccessMode.Open, 0);
        vm.expectRevert(DomainAccessRules.NotPolicyOwner.selector);
        rules.setReaderAllowed(target, IERC20.balanceOf.selector, outsider, true);
        vm.stopPrank();
    }

    function test_nominationEmitsAndPreservesCurrentOwner() public {
        assertEq(spoke.pendingPolicyOwners(target), address(0));
        vm.expectEmit(address(spoke));
        emit IDomainAccessControl.PolicyOwnershipTransferStarted(target, owner, nextOwner);
        _nominate(nextOwner);
        assertEq(spoke.policyOwners(target), owner);
        assertEq(spoke.pendingPolicyOwners(target), nextOwner);
    }

    function testFuzz_onlyCurrentOwnerCanNominate(address caller, address nominee) public {
        vm.assume(caller != owner);
        _nominate(nextOwner);
        vm.prank(caller);
        vm.expectRevert(DomainSpoke.NotPolicyOwner.selector);
        spoke.transferPolicyOwnership(target, nominee);
        assertEq(spoke.policyOwners(target), owner);
        assertEq(spoke.pendingPolicyOwners(target), nextOwner);
    }

    function test_unregisteredTargetRejectsNominationAndAcceptance() public {
        address unregistered = address(new TestERC20());
        vm.prank(owner);
        vm.expectRevert(DomainSpoke.NotPolicyOwner.selector);
        spoke.transferPolicyOwnership(unregistered, nextOwner);
        vm.prank(nextOwner);
        vm.expectRevert(DomainSpoke.NotPendingPolicyOwner.selector);
        spoke.acceptPolicyOwnership(unregistered);
        assertEq(spoke.policyOwners(unregistered), address(0));
        assertEq(spoke.pendingPolicyOwners(unregistered), address(0));
    }

    function test_currentOwnerRetainsAdministrationUntilAcceptance() public {
        _nominate(nextOwner);
        _assertCannotAdminister(nextOwner);
        vm.startPrank(owner);
        spoke.setAccessPolicy(target, address(0));
        spoke.setAccessPolicy(target, address(rules));
        spoke.setLogReader(target, outsider, true);
        rules.setAccessControl(target, IERC20.allowance.selector, DomainAccessRules.AccessMode.SubjectMatch, 3);
        rules.setReaderAllowed(target, IERC20.balanceOf.selector, outsider, true);
        vm.stopPrank();
        assertEq(spoke.policyOwners(target), owner);
        assertTrue(spoke.logReaders(target, outsider));
        assertTrue(rules.approvedReaders(target, IERC20.balanceOf.selector, outsider));
    }

    function testFuzz_onlyPendingOwnerCanAccept(address caller) public {
        vm.assume(caller != nextOwner);
        _nominate(nextOwner);
        vm.prank(caller);
        vm.expectRevert(DomainSpoke.NotPendingPolicyOwner.selector);
        spoke.acceptPolicyOwnership(target);
        assertEq(spoke.policyOwners(target), owner);
        assertEq(spoke.pendingPolicyOwners(target), nextOwner);
    }

    function test_acceptanceEmitsClearsPendingOwnerAndTransfersAdministration() public {
        _nominate(nextOwner);
        vm.expectEmit(address(spoke));
        emit IDomainAccessControl.PolicyOwnershipTransferred(target, owner, nextOwner);
        _accept(nextOwner);
        assertEq(spoke.policyOwners(target), nextOwner);
        assertEq(spoke.pendingPolicyOwners(target), address(0));
        _assertCannotAdminister(owner);

        vm.startPrank(nextOwner);
        spoke.setAccessPolicy(target, address(0));
        spoke.setAccessPolicy(target, address(rules));
        spoke.setLogReader(target, outsider, true);
        rules.setAccessControl(target, IERC20.allowance.selector, DomainAccessRules.AccessMode.SubjectMatch, 3);
        rules.setReaderAllowed(target, IERC20.balanceOf.selector, outsider, true);
        vm.stopPrank();
        assertTrue(spoke.logReaders(target, outsider));
        assertTrue(rules.approvedReaders(target, IERC20.balanceOf.selector, outsider));
    }

    function test_acceptancePreservesPoliciesRulesAndExplicitReaderGrants() public {
        _nominate(nextOwner);
        _accept(nextOwner);
        assertEq(spoke.accessPolicies(target), address(rules));
        (DomainAccessRules.AccessMode mode, uint16 subjects) = rules.accessControl(target, IERC20.balanceOf.selector);
        assertEq(uint8(mode), uint8(DomainAccessRules.AccessMode.SubjectMatch));
        assertEq(subjects, 1);
        assertTrue(rules.approvedReaders(target, IERC20.balanceOf.selector, reader));
        assertTrue(spoke.logReaders(target, reader));
        assertTrue(spoke.logReaders(target, owner));
        bytes memory query = abi.encodeCall(IERC20.balanceOf, (holder));
        assertTrue(spoke.canCall(holder, target, query));
        assertTrue(spoke.canCall(reader, target, query));
        assertFalse(spoke.canCall(outsider, target, query));
        assertFalse(spoke.canCall(owner, target, query));
        assertFalse(spoke.canCall(nextOwner, target, query));
    }

    function test_currentOwnerCanReplaceNomination() public {
        _nominate(nextOwner);
        vm.expectEmit(address(spoke));
        emit IDomainAccessControl.PolicyOwnershipTransferStarted(target, owner, outsider);
        _nominate(outsider);
        assertEq(spoke.policyOwners(target), owner);
        assertEq(spoke.pendingPolicyOwners(target), outsider);
        vm.expectRevert(DomainSpoke.NotPendingPolicyOwner.selector);
        _accept(nextOwner);
        _accept(outsider);
        assertEq(spoke.policyOwners(target), outsider);
        assertEq(spoke.pendingPolicyOwners(target), address(0));
    }

    function test_zeroNominationCancelsWithoutRenouncingOwnership() public {
        _nominate(nextOwner);
        vm.expectEmit(address(spoke));
        emit IDomainAccessControl.PolicyOwnershipTransferStarted(target, owner, address(0));
        _nominate(address(0));
        assertEq(spoke.policyOwners(target), owner);
        assertEq(spoke.pendingPolicyOwners(target), address(0));
        vm.expectRevert(DomainSpoke.NotPendingPolicyOwner.selector);
        _accept(nextOwner);
        _nominate(outsider);
        _accept(outsider);
        assertEq(spoke.policyOwners(target), outsider);
    }

    function test_acceptanceRequiresAnActiveNonzeroNomination() public {
        vm.expectRevert(DomainSpoke.NotPendingPolicyOwner.selector);
        _accept(nextOwner);
        _nominate(address(0));
        vm.expectRevert(DomainSpoke.NotPendingPolicyOwner.selector);
        _accept(address(0));
        assertEq(spoke.policyOwners(target), owner);
    }

    function test_completedTransferCannotBeAcceptedAgain() public {
        _nominate(nextOwner);
        _accept(nextOwner);
        vm.expectRevert(DomainSpoke.NotPendingPolicyOwner.selector);
        _accept(nextOwner);
        vm.prank(nextOwner);
        spoke.transferPolicyOwnership(target, outsider);
        _accept(outsider);
        assertEq(spoke.policyOwners(target), outsider);
        assertEq(spoke.pendingPolicyOwners(target), address(0));
    }

    function test_transfersAreScopedToTheirTarget() public {
        address otherTarget = spoke.deployContract(type(TestERC20).creationCode, reader);
        _nominate(nextOwner);
        vm.prank(reader);
        spoke.transferPolicyOwnership(otherTarget, outsider);
        vm.prank(nextOwner);
        vm.expectRevert(DomainSpoke.NotPendingPolicyOwner.selector);
        spoke.acceptPolicyOwnership(otherTarget);
        _accept(nextOwner);
        assertEq(spoke.policyOwners(target), nextOwner);
        assertEq(spoke.pendingPolicyOwners(target), address(0));
        assertEq(spoke.policyOwners(otherTarget), reader);
        assertEq(spoke.pendingPolicyOwners(otherTarget), outsider);
        vm.prank(outsider);
        spoke.acceptPolicyOwnership(otherTarget);
        assertEq(spoke.policyOwners(otherTarget), outsider);
    }

    function test_contractNomineeAcceptsThroughItsOwnCall() public {
        PolicyOwnerReceiver receiver = new PolicyOwnerReceiver();
        _nominate(address(receiver));
        vm.expectRevert(DomainSpoke.NotPendingPolicyOwner.selector);
        spoke.acceptPolicyOwnership(target);
        receiver.accept(spoke, target);
        assertEq(spoke.policyOwners(target), address(receiver));
        assertEq(spoke.pendingPolicyOwners(target), address(0));
    }

    function test_currentOwnerMayNominateAndAcceptItself() public {
        _nominate(owner);
        _accept(owner);
        assertEq(spoke.policyOwners(target), owner);
        assertEq(spoke.pendingPolicyOwners(target), address(0));
    }

    function test_existingStorageSlotsStayPinnedAndPendingOwnerIsAppended() public {
        bytes32 ownerSlot = keccak256(abi.encode(target, uint256(2)));
        bytes32 policySlot = keccak256(abi.encode(target, uint256(3)));
        bytes32 readerSlot = keccak256(abi.encode(reader, keccak256(abi.encode(target, uint256(6)))));
        bytes32 pendingSlot = keccak256(abi.encode(target, uint256(7)));
        _nominate(nextOwner);
        assertEq(vm.load(address(spoke), ownerSlot), bytes32(uint256(uint160(owner))));
        assertEq(vm.load(address(spoke), pendingSlot), bytes32(uint256(uint160(nextOwner))));
        _accept(nextOwner);
        assertEq(vm.load(address(spoke), ownerSlot), bytes32(uint256(uint160(nextOwner))));
        assertEq(vm.load(address(spoke), pendingSlot), bytes32(0));
        assertEq(vm.load(address(spoke), policySlot), bytes32(uint256(uint160(address(rules)))));
        assertEq(vm.load(address(spoke), readerSlot), bytes32(uint256(1)));
    }
}
