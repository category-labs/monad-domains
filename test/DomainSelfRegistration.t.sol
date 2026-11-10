// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DomainSpoke} from "../src/DomainSpoke.sol";
import {IDomainAccessControl} from "../src/interfaces/IDomainAccessControl.sol";
import {ConstantPolicy} from "./mocks/AccessPolicies.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

contract SelfRegisteringContract {
    bool public immutable deniedDuringConstruction;

    constructor(IDomainAccessControl spoke, address owner, address policy) {
        spoke.selfRegisterPolicy(owner, policy);
        deniedDuringConstruction = !spoke.canCall(owner, address(this), hex"");
    }
}

contract DomainSelfRegistrationTest is Test {
    DomainSpoke internal spoke;
    address internal policy;
    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        spoke = new DomainSpoke(7777, block.chainid, address(0x1234));
        policy = address(new ConstantPolicy(false));
    }

    function _initCode(address policyOwner) internal view returns (bytes memory) {
        return abi.encodePacked(type(SelfRegisteringContract).creationCode, abi.encode(spoke, policyOwner, policy));
    }

    function test_registrationDuringConstructionInstallsOwnerAndPolicyImmediately() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectEmit(address(spoke));
        emit IDomainAccessControl.ContractRegistered(predicted, owner);
        vm.expectEmit(address(spoke));
        emit IDomainAccessControl.AccessPolicySet(predicted, policy);
        SelfRegisteringContract target = new SelfRegisteringContract(spoke, owner, policy);
        assertEq(address(target), predicted);
        assertEq(spoke.policyOwners(predicted), owner);
        assertEq(spoke.accessPolicies(predicted), policy);
        assertTrue(target.deniedDuringConstruction());
        vm.prank(owner);
        spoke.setLogReader(predicted, stranger, true);
        assertTrue(spoke.logReaders(predicted, stranger));
        vm.prank(owner);
        spoke.setAccessPolicy(predicted, address(0));
        assertTrue(spoke.canCall(stranger, predicted, hex""));
    }

    function test_callerCannotRegisterAnUnrelatedContract() public {
        address unrelated = address(new TestERC20());
        vm.prank(stranger);
        spoke.selfRegisterPolicy(owner, policy);
        assertEq(spoke.policyOwners(stranger), owner);
        assertEq(spoke.policyOwners(unrelated), address(0));
        assertEq(spoke.accessPolicies(unrelated), address(0));
        vm.prank(owner);
        vm.expectRevert(DomainSpoke.NotPolicyOwner.selector);
        spoke.setAccessPolicy(unrelated, policy);
    }

    function test_registrationCannotOverwriteAnExistingOwnerOrPolicy() public {
        address target = address(new SelfRegisteringContract(spoke, owner, policy));
        vm.prank(target);
        vm.expectRevert(DomainSpoke.AlreadyRegistered.selector);
        spoke.selfRegisterPolicy(stranger, address(0));
        assertEq(spoke.policyOwners(target), owner);
        assertEq(spoke.accessPolicies(target), policy);

        address deployed = spoke.deployContract(type(TestERC20).creationCode, owner);
        vm.prank(deployed);
        vm.expectRevert(DomainSpoke.AlreadyRegistered.selector);
        spoke.selfRegisterPolicy(stranger, policy);
        assertEq(spoke.policyOwners(deployed), owner);
        assertEq(spoke.accessPolicies(deployed), address(0));
    }

    function test_registrationRejectsZeroOwner() public {
        vm.expectRevert(DomainSpoke.ZeroPolicyOwner.selector);
        spoke.selfRegisterPolicy(address(0), policy);
        assertEq(spoke.policyOwners(address(this)), address(0));
    }

    function test_invalidPolicyRollsBackRegistrationAndAllowsRetry() public {
        vm.startPrank(stranger);
        vm.expectRevert(DomainSpoke.PolicyHasNoCode.selector);
        spoke.selfRegisterPolicy(owner, owner);
        assertEq(spoke.policyOwners(stranger), address(0));
        assertEq(spoke.accessPolicies(stranger), address(0));
        vm.expectRevert(DomainSpoke.InvalidSelfPolicy.selector);
        spoke.selfRegisterPolicy(owner, address(spoke));
        assertEq(spoke.policyOwners(stranger), address(0));
        spoke.selfRegisterPolicy(owner, policy);
        vm.stopPrank();
        assertEq(spoke.policyOwners(stranger), owner);
        assertEq(spoke.accessPolicies(stranger), policy);
    }

    function test_genericRegistrationCanExplicitlyChooseOpenAccess() public {
        SelfRegisteringContract target = new SelfRegisteringContract(spoke, owner, address(0));
        assertEq(spoke.policyOwners(address(target)), owner);
        assertEq(spoke.accessPolicies(address(target)), address(0));
        assertFalse(target.deniedDuringConstruction());
    }

    function test_deployContractPreservesMatchingConstructorRegistration() public {
        address deployed = spoke.deployContract(_initCode(owner), owner);
        assertEq(spoke.policyOwners(deployed), owner);
        assertEq(spoke.accessPolicies(deployed), policy);
        assertTrue(SelfRegisteringContract(deployed).deniedDuringConstruction());
    }

    function test_deployContractRejectsConflictingConstructorOwnerAndRollsBack() public {
        uint64 nonce = vm.getNonce(address(spoke));
        address predicted = vm.computeCreateAddress(address(spoke), nonce);
        vm.expectRevert(DomainSpoke.PolicyOwnerMismatch.selector);
        spoke.deployContract(_initCode(owner), stranger);
        assertEq(predicted.code.length, 0);
        assertEq(spoke.policyOwners(predicted), address(0));
        assertEq(spoke.accessPolicies(predicted), address(0));
        assertEq(vm.getNonce(address(spoke)), nonce);
    }
}
