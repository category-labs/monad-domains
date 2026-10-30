// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DomainSpoke} from "../src/DomainSpoke.sol";
import {IDomainAccessControl} from "../src/interfaces/IDomainAccessControl.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {BrokenPolicy, ConstantPolicy, ExpectingPolicy} from "./mocks/AccessPolicies.sol";
import {DomainTestBase} from "./helpers/DomainTestBase.sol";

contract DeploymentOwnershipExample {
    address public immutable owner;
    address public immutable constructorSender;

    constructor(address initialOwner) {
        owner = initialOwner;
        constructorSender = msg.sender;
    }
}

/// @dev The spoke's side of access control: deployment with a policy owner, naming a policy and
/// forwarding `canCall` to it. The stock rule table is covered by DomainAccessRules.t.sol.
contract DomainAccessControlTest is DomainTestBase {
    DomainSpoke internal spoke;
    address internal token;
    address internal allowAll;
    address internal denyAll;
    address internal policyOwner = makeAddr("policyOwner");
    address internal deployer = makeAddr("deployer");
    address internal outsider = makeAddr("outsider");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        spoke = new DomainSpoke(7777, block.chainid, address(0x1234));
        vm.prank(deployer);
        token = spoke.deployContract(type(TestERC20).creationCode, policyOwner);
        allowAll = address(new ConstantPolicy(true));
        denyAll = address(new ConstantPolicy(false));
    }

    function _policy(address target, address policy) internal {
        vm.prank(policyOwner);
        spoke.setAccessPolicy(target, policy);
    }

    function _balance(address subject) internal pure returns (bytes memory) {
        return abi.encodeCall(IERC20.balanceOf, (subject));
    }

    // ----- deployment -----

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
        spoke.setAccessPolicy(deployed, denyAll);
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
        spoke.setAccessPolicy(other, denyAll);
        vm.expectRevert("DomainSpoke: not policy owner");
        vm.prank(bob);
        spoke.setAccessPolicy(token, denyAll);
        assertFalse(spoke.canCall(alice, other, _balance(alice)));
        assertTrue(spoke.canCall(alice, token, _balance(alice)));
    }

    // ----- naming a policy -----

    function test_deployerAndOutsiderCannotNameAPolicy() public {
        vm.prank(deployer);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setAccessPolicy(token, denyAll);
        vm.prank(outsider);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setAccessPolicy(token, denyAll);
        assertEq(spoke.accessPolicies(token), address(0));
    }

    function testFuzz_onlyThePolicyOwnerNamesThePolicy(address stranger) public {
        vm.assume(stranger != policyOwner);
        _policy(token, denyAll);
        vm.startPrank(stranger);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setAccessPolicy(token, allowAll);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setAccessPolicy(token, address(0));
        vm.stopPrank();
        assertEq(spoke.accessPolicies(token), denyAll);
    }

    function test_cannotNameAPolicyForAnIndependentlyDeployedTarget() public {
        vm.prank(policyOwner);
        address independent = address(new TestERC20());
        assertEq(spoke.policyOwners(independent), address(0));
        vm.prank(policyOwner);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setAccessPolicy(independent, denyAll);
        assertTrue(spoke.canCall(bob, independent, _balance(alice)));
    }

    function test_namingAPolicyStoresAndEmitsIt() public {
        vm.expectEmit(true, true, false, true, address(spoke));
        emit IDomainAccessControl.AccessPolicySet(token, denyAll);
        _policy(token, denyAll);
        assertEq(spoke.accessPolicies(token), denyAll);
    }

    function test_policyMustBeAContractOtherThanTheSpoke() public {
        vm.startPrank(policyOwner);
        vm.expectRevert("DomainSpoke: policy has no code");
        spoke.setAccessPolicy(token, outsider);
        vm.expectRevert("DomainSpoke: spoke cannot be its own policy");
        spoke.setAccessPolicy(token, address(spoke));
        spoke.setAccessPolicy(token, address(0));
        vm.stopPrank();
        assertEq(spoke.accessPolicies(token), address(0));
    }

    function test_aContractMayBeItsOwnPolicy() public {
        bytes memory initCode = abi.encodePacked(type(ConstantPolicy).creationCode, abi.encode(false));
        vm.prank(deployer);
        address selfGoverned = spoke.deployContract(initCode, policyOwner);
        _policy(selfGoverned, selfGoverned);
        assertFalse(spoke.canCall(alice, selfGoverned, hex""));
    }

    // ----- verdicts -----

    function test_unconfiguredCallsAreAllowed() public view {
        assertTrue(spoke.canCall(bob, token, _balance(alice)));
        assertTrue(spoke.canCall(bob, alice, hex""));
        assertTrue(spoke.canCall(bob, address(spoke), hex""));
    }

    function test_policyVerdictDecidesEveryCallIntoItsTarget() public {
        _policy(token, denyAll);
        assertFalse(spoke.canCall(alice, token, _balance(alice)));
        assertFalse(spoke.canCall(policyOwner, token, _balance(alice)));
        assertFalse(spoke.canCall(alice, token, hex""));
        // Other contexts are untouched.
        assertTrue(spoke.canCall(alice, alice, _balance(alice)));
        _policy(token, allowAll);
        assertTrue(spoke.canCall(outsider, token, _balance(alice)));
    }

    function test_policyReceivesCallerContextAndCalldata() public {
        bytes memory data = _balance(bob);
        address expecting = address(new ExpectingPolicy(alice, token, data));
        _policy(token, expecting);
        assertTrue(spoke.canCall(alice, token, data));
        assertFalse(spoke.canCall(bob, token, data));
        assertFalse(spoke.canCall(alice, token, _balance(alice)));
        assertFalse(spoke.canCall(alice, token, abi.encodePacked(data, uint8(0))));
        // The query sender is not an input.
        vm.prank(bob);
        assertTrue(spoke.canCall(alice, token, data));
        // The same policy named for another target sees that target as the context.
        vm.prank(deployer);
        address other = spoke.deployContract(type(TestERC20).creationCode, policyOwner);
        _policy(other, expecting);
        assertFalse(spoke.canCall(alice, other, data));
    }

    function test_policyIsLookedUpByContextNotByCode() public {
        vm.prank(deployer);
        address implementation = spoke.deployContract(type(TestERC20).creationCode, policyOwner);
        bytes memory data = abi.encodeCall(IERC20.allowance, (alice, bob));
        _policy(implementation, denyAll);
        // Delegated execution in the token's context is governed by the token's policy alone.
        assertTrue(spoke.canCall(alice, token, data));
        assertFalse(spoke.canCall(alice, implementation, data));
        _policy(token, allowAll);
        assertTrue(spoke.canCall(alice, token, data));
        assertFalse(spoke.canCall(alice, implementation, data));
    }

    function test_clearingThePolicyReopensTheTarget() public {
        _policy(token, denyAll);
        assertFalse(spoke.canCall(alice, token, _balance(alice)));
        vm.expectEmit(true, true, false, true, address(spoke));
        emit IDomainAccessControl.AccessPolicySet(token, address(0));
        _policy(token, address(0));
        assertEq(spoke.accessPolicies(token), address(0));
        assertTrue(spoke.canCall(alice, token, _balance(alice)));
    }

    function test_brokenPoliciesDenyWithoutReverting() public {
        for (uint8 i = 0; i <= uint8(type(BrokenPolicy.Fault).max); i++) {
            BrokenPolicy broken = new BrokenPolicy(BrokenPolicy.Fault(i));
            _policy(token, address(broken));
            // Bounded like the client's stipend, so the gas-burning variant ends.
            assertFalse(spoke.canCall{gas: 50_000}(alice, token, _balance(alice)));
            assertEq(broken.writes(), 0);
        }
    }

    function test_policyThatLostItsCodeDenies() public {
        _policy(token, allowAll);
        assertTrue(spoke.canCall(alice, token, _balance(alice)));
        vm.etch(allowAll, hex"");
        assertFalse(spoke.canCall(alice, token, _balance(alice)));
    }

    // ----- log readers -----

    function test_policyOwnerGrantsAndRevokesLogReaders() public {
        vm.expectEmit(true, true, false, true, address(spoke));
        emit IDomainAccessControl.LogReaderSet(token, alice, true);
        vm.prank(policyOwner);
        spoke.setLogReader(token, alice, true);
        assertTrue(spoke.logReaders(token, alice));
        assertFalse(spoke.logReaders(token, bob));

        vm.expectEmit(true, true, false, true, address(spoke));
        emit IDomainAccessControl.LogReaderSet(token, alice, false);
        vm.prank(policyOwner);
        spoke.setLogReader(token, alice, false);
        assertFalse(spoke.logReaders(token, alice));
    }

    function testFuzz_onlyThePolicyOwnerSetsLogReaders(address stranger, bool allowed) public {
        vm.assume(stranger != policyOwner);
        vm.prank(policyOwner);
        spoke.setLogReader(token, alice, true);
        vm.startPrank(stranger);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setLogReader(token, stranger, allowed);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setLogReader(token, alice, allowed);
        vm.stopPrank();
        assertFalse(spoke.logReaders(token, stranger));
        assertTrue(spoke.logReaders(token, alice));
    }

    function test_logReaderGrantIsScopedToItsTarget() public {
        vm.prank(deployer);
        address other = spoke.deployContract(type(TestERC20).creationCode, policyOwner);
        vm.prank(policyOwner);
        spoke.setLogReader(token, alice, true);
        assertTrue(spoke.logReaders(token, alice));
        assertFalse(spoke.logReaders(other, alice));
    }

    function test_cannotSetLogReadersForAnIndependentlyDeployedTarget() public {
        address independent = address(new TestERC20());
        vm.prank(policyOwner);
        vm.expectRevert("DomainSpoke: not policy owner");
        spoke.setLogReader(independent, alice, true);
    }

    function test_logAccessStorageSlots() public {
        vm.prank(policyOwner);
        spoke.setLogReader(token, alice, true);
        bytes32 ownerSlot = keccak256(abi.encode(token, uint256(2)));
        bytes32 readerSlot = keccak256(abi.encode(alice, keccak256(abi.encode(token, uint256(6)))));
        assertEq(vm.load(address(spoke), ownerSlot), bytes32(uint256(uint160(policyOwner))));
        assertEq(vm.load(address(spoke), readerSlot), bytes32(uint256(1)));
    }
}
