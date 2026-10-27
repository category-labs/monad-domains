// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DomainSpoke} from "../src/DomainSpoke.sol";
import {DomainAccessRules} from "../src/access/DomainAccessRules.sol";
import {IDomainAccessControl} from "../src/interfaces/IDomainAccessControl.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {DomainTestBase} from "./helpers/DomainTestBase.sol";

/// @dev The stock rule table, exercised through the spoke's `canCall` the way the client reaches it.
contract DomainAccessRulesTest is DomainTestBase {
    DomainSpoke internal spoke;
    DomainAccessRules internal rules;
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
    DomainAccessRules.AccessMode internal constant OPEN = DomainAccessRules.AccessMode.Open;
    DomainAccessRules.AccessMode internal constant SUBJECT_MATCH = DomainAccessRules.AccessMode.SubjectMatch;
    DomainAccessRules.AccessMode internal constant READERS_ONLY = DomainAccessRules.AccessMode.ReadersOnly;

    function setUp() public {
        spoke = new DomainSpoke(7777, block.chainid, address(0x1234));
        rules = new DomainAccessRules(spoke);
        token = _governed(policyOwner);
    }

    /// @dev Deploys a token through the spoke and names the rule table as its policy.
    function _governed(address owner) internal returns (address target) {
        vm.prank(deployer);
        target = spoke.deployContract(type(TestERC20).creationCode, owner);
        vm.prank(owner);
        spoke.setAccessPolicy(target, address(rules));
    }

    /// @dev `subjects` is the SubjectMatch bit mask: bit i admits the address in argument word i.
    function _rule(address target, bytes4 selector, DomainAccessRules.AccessMode mode, uint16 subjects) internal {
        vm.prank(policyOwner);
        rules.setAccessControl(target, selector, mode, subjects);
    }

    function _reader(address target, bytes4 selector, address account, bool allowed) internal {
        vm.prank(policyOwner);
        rules.setReaderAllowed(target, selector, account, allowed);
    }

    function _balance(address subject) internal pure returns (bytes memory) {
        return abi.encodeCall(IERC20.balanceOf, (subject));
    }

    function _assertRule(bytes4 selector, DomainAccessRules.AccessMode mode, uint16 subjects) internal view {
        (DomainAccessRules.AccessMode storedMode, uint16 storedSubjects) = rules.accessControl(token, selector);
        assertEq(uint8(storedMode), uint8(mode));
        assertEq(storedSubjects, subjects);
    }

    function test_constructorRecordsTheSpokeAndRejectsZero() public {
        assertEq(address(rules.SPOKE()), address(spoke));
        vm.expectRevert("DomainAccessRules: zero spoke");
        new DomainAccessRules(IDomainAccessControl(address(0)));
    }

    function test_rulesApplyOnlyOnceNamedAsThePolicy() public {
        vm.prank(deployer);
        address unnamed = spoke.deployContract(type(TestERC20).creationCode, policyOwner);
        _rule(unnamed, BALANCE_OF, READERS_ONLY, 0);
        assertFalse(rules.canCall(alice, unnamed, _balance(alice)));
        assertTrue(spoke.canCall(alice, unnamed, _balance(alice)));
        vm.prank(policyOwner);
        spoke.setAccessPolicy(unnamed, address(rules));
        assertFalse(spoke.canCall(alice, unnamed, _balance(alice)));
    }

    function test_rulesBuiltForAnotherSpokeIgnoreThisSpokesOwners() public {
        DomainSpoke otherSpoke = new DomainSpoke(7778, block.chainid, address(0x1234));
        DomainAccessRules foreign = new DomainAccessRules(otherSpoke);
        vm.prank(policyOwner);
        vm.expectRevert("DomainAccessRules: not policy owner");
        foreign.setAccessControl(token, BALANCE_OF, READERS_ONLY, 0);
        // Naming it anyway is the owner's choice: the foreign table has no row, so it admits.
        vm.prank(policyOwner);
        spoke.setAccessPolicy(token, address(foreign));
        assertTrue(spoke.canCall(bob, token, _balance(alice)));
    }

    function test_rowsSurviveClearingAndRenamingThePolicy() public {
        _rule(token, BALANCE_OF, SUBJECT_MATCH, 1);
        _reader(token, BALANCE_OF, reader, true);
        vm.prank(policyOwner);
        spoke.setAccessPolicy(token, address(0));
        assertTrue(spoke.canCall(bob, token, _balance(alice)));
        vm.prank(policyOwner);
        spoke.setAccessPolicy(token, address(rules));
        assertFalse(spoke.canCall(bob, token, _balance(alice)));
        assertTrue(spoke.canCall(reader, token, _balance(alice)));
    }

    function test_deployerAndOutsiderHaveNoImplicitConfigurationAuthority() public {
        vm.startPrank(deployer);
        vm.expectRevert("DomainAccessRules: not policy owner");
        rules.setAccessControl(token, BALANCE_OF, SUBJECT_MATCH, 1);
        vm.expectRevert("DomainAccessRules: not policy owner");
        rules.setReaderAllowed(token, BALANCE_OF, reader, true);
        vm.stopPrank();
        vm.prank(outsider);
        vm.expectRevert("DomainAccessRules: not policy owner");
        rules.setAccessControl(token, BALANCE_OF, SUBJECT_MATCH, 1);
    }

    function testFuzz_onlyPolicyOwnerCanConfigureRulesAndReaders(address stranger) public {
        vm.assume(stranger != policyOwner);
        _rule(token, BALANCE_OF, SUBJECT_MATCH, 1);
        _reader(token, BALANCE_OF, reader, true);
        vm.startPrank(stranger);
        vm.expectRevert("DomainAccessRules: not policy owner");
        rules.setAccessControl(token, BALANCE_OF, SUBJECT_MATCH, 2);
        vm.expectRevert("DomainAccessRules: not policy owner");
        rules.setAccessControl(token, BALANCE_OF, OPEN, 0);
        vm.expectRevert("DomainAccessRules: not policy owner");
        rules.setReaderAllowed(token, BALANCE_OF, stranger, true);
        vm.expectRevert("DomainAccessRules: not policy owner");
        rules.setReaderAllowed(token, BALANCE_OF, reader, false);
        vm.stopPrank();
    }

    function test_ownersConfigureOnlyTheirOwnTargets() public {
        address other = _governed(bob);
        vm.prank(bob);
        rules.setAccessControl(other, BALANCE_OF, SUBJECT_MATCH, 1);
        vm.expectRevert("DomainAccessRules: not policy owner");
        vm.prank(bob);
        rules.setAccessControl(token, BALANCE_OF, SUBJECT_MATCH, 1);
        assertFalse(spoke.canCall(alice, other, _balance(bob)));
        assertTrue(spoke.canCall(alice, token, _balance(bob)));
    }

    function test_cannotConfigureIndependentlyDeployedTarget() public {
        vm.prank(policyOwner);
        address independent = address(new TestERC20());
        assertEq(spoke.policyOwners(independent), address(0));
        vm.startPrank(policyOwner);
        vm.expectRevert("DomainAccessRules: not policy owner");
        rules.setAccessControl(independent, BALANCE_OF, SUBJECT_MATCH, 1);
        vm.expectRevert("DomainAccessRules: not policy owner");
        rules.setReaderAllowed(independent, BALANCE_OF, reader, true);
        vm.stopPrank();
    }

    function test_unconfiguredSelectorsAreAllowed() public view {
        assertTrue(spoke.canCall(bob, token, _balance(alice)));
        assertTrue(rules.canCall(bob, token, _balance(alice)));
        assertTrue(spoke.canCall(bob, token, hex""));
    }

    function test_subjectMatchAllowsSubjectAndApprovedReaders() public {
        _rule(token, BALANCE_OF, SUBJECT_MATCH, 1);
        _reader(token, BALANCE_OF, reader, true);
        _assertRule(BALANCE_OF, SUBJECT_MATCH, 1);
        assertTrue(rules.approvedReaders(token, BALANCE_OF, reader));
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
        address other = _governed(policyOwner);
        _rule(token, BALANCE_OF, SUBJECT_MATCH, 1);
        _rule(other, BALANCE_OF, SUBJECT_MATCH, 1);
        _rule(token, ALLOWANCE, SUBJECT_MATCH, 1);
        _reader(token, BALANCE_OF, reader, true);
        assertTrue(spoke.canCall(reader, token, _balance(alice)));
        assertFalse(spoke.canCall(reader, other, _balance(alice)));
        assertFalse(spoke.canCall(reader, token, abi.encodeCall(IERC20.allowance, (alice, bob))));
        assertTrue(spoke.canCall(reader, token, abi.encodeCall(IERC20.totalSupply, ())));
    }

    function test_policyOwnerCanRevokeReaderWithoutBlockingSubject() public {
        _rule(token, BALANCE_OF, SUBJECT_MATCH, 1);
        vm.expectEmit(true, true, true, true, address(rules));
        emit DomainAccessRules.ReaderAllowedSet(token, BALANCE_OF, reader, true);
        _reader(token, BALANCE_OF, reader, true);
        assertTrue(spoke.canCall(reader, token, _balance(alice)));
        vm.expectEmit(true, true, true, true, address(rules));
        emit DomainAccessRules.ReaderAllowedSet(token, BALANCE_OF, reader, false);
        _reader(token, BALANCE_OF, reader, false);
        assertFalse(rules.approvedReaders(token, BALANCE_OF, reader));
        assertFalse(spoke.canCall(reader, token, _balance(alice)));
        assertTrue(spoke.canCall(alice, token, _balance(alice)));
    }

    function test_policyOwnerCanChangeArgumentAndDisableRestriction() public {
        bytes memory data = abi.encodeCall(IERC20.allowance, (alice, bob));
        _rule(token, ALLOWANCE, SUBJECT_MATCH, 2);
        _assertRule(ALLOWANCE, SUBJECT_MATCH, 2);
        assertTrue(spoke.canCall(bob, token, data));
        assertFalse(spoke.canCall(alice, token, data));
        _rule(token, ALLOWANCE, SUBJECT_MATCH, 1);
        assertTrue(spoke.canCall(alice, token, data));
        assertFalse(spoke.canCall(bob, token, data));
        _rule(token, ALLOWANCE, OPEN, 42);
        _assertRule(ALLOWANCE, OPEN, 0);
        assertTrue(spoke.canCall(reader, token, data));
    }

    function test_subjectMatchAdmitsAnyListedArgument() public {
        // allowance(owner, spender): readable by the owner (word 0) or the spender (word 1).
        bytes memory data = abi.encodeCall(IERC20.allowance, (alice, bob));
        vm.expectEmit(true, true, false, true, address(rules));
        emit DomainAccessRules.AccessControlSet(token, ALLOWANCE, SUBJECT_MATCH, 3);
        _rule(token, ALLOWANCE, SUBJECT_MATCH, 3);
        _assertRule(ALLOWANCE, SUBJECT_MATCH, 3);
        assertTrue(spoke.canCall(alice, token, data));
        assertTrue(spoke.canCall(bob, token, data));
        assertFalse(spoke.canCall(outsider, token, data));
        assertFalse(spoke.canCall(policyOwner, token, data));
        _reader(token, ALLOWANCE, reader, true);
        assertTrue(spoke.canCall(reader, token, data));

        // A listed word the calldata does not reach cannot match; the others still can.
        bytes memory ownerOnly = abi.encodePacked(ALLOWANCE, abi.encode(alice));
        assertTrue(spoke.canCall(alice, token, ownerOnly));
        assertFalse(spoke.canCall(bob, token, ownerOnly));

        // A malformed listed word denies even when another listed word matches the caller,
        // whichever of the two comes first.
        bytes memory malformedSpender = abi.encodePacked(ALLOWANCE, abi.encode(alice), uint256(1) << 160 | uint160(bob));
        assertFalse(spoke.canCall(alice, token, malformedSpender));
        assertTrue(spoke.canCall(reader, token, malformedSpender));
        bytes memory malformedOwner = abi.encodePacked(ALLOWANCE, uint256(1) << 160 | uint160(alice), abi.encode(bob));
        assertFalse(spoke.canCall(bob, token, malformedOwner));
    }

    function test_malformedWordOutsideTheMaskIsIgnored() public {
        _rule(token, ALLOWANCE, SUBJECT_MATCH, 1);
        bytes memory malformedSpender = abi.encodePacked(ALLOWANCE, abi.encode(alice), uint256(1) << 160 | uint160(bob));
        assertTrue(spoke.canCall(alice, token, malformedSpender));
        assertFalse(spoke.canCall(bob, token, malformedSpender));
    }

    function test_subjectMatchRequiresASubjectArgument() public {
        _rule(token, ALLOWANCE, SUBJECT_MATCH, 3);
        vm.prank(policyOwner);
        vm.expectRevert("DomainAccessRules: no subject arguments");
        rules.setAccessControl(token, ALLOWANCE, SUBJECT_MATCH, 0);
        _assertRule(ALLOWANCE, SUBJECT_MATCH, 3);
    }

    function test_canCallFitsTheClientStipend() public {
        // The widest rule with the caller in the last listed word must stay well inside the
        // client's 50,000 gas stipend; a node charges more for cold access than Forge does.
        _rule(token, ALLOWANCE, SUBJECT_MATCH, type(uint16).max);
        bytes memory data = abi.encodePacked(ALLOWANCE);
        for (uint256 i = 0; i < 15; i++) {
            data = abi.encodePacked(data, abi.encode(bob));
        }
        data = abi.encodePacked(data, abi.encode(alice));
        assertTrue(spoke.canCall{gas: 50_000}(alice, token, data));
        assertFalse(spoke.canCall{gas: 50_000}(outsider, token, data));
    }

    function test_readerGrantsPersistAcrossModeChanges() public {
        _rule(token, BALANCE_OF, SUBJECT_MATCH, 1);
        _reader(token, BALANCE_OF, reader, true);
        _rule(token, BALANCE_OF, OPEN, 0);
        assertTrue(spoke.canCall(bob, token, _balance(alice)));
        _rule(token, BALANCE_OF, READERS_ONLY, 0);
        assertTrue(spoke.canCall(reader, token, _balance(alice)));
        assertFalse(spoke.canCall(alice, token, _balance(alice)));
    }

    function test_delegateCallChecksOnlyContextWhileDirectCallChecksImplementation() public {
        address implementation = _governed(policyOwner);
        bytes memory data = abi.encodeCall(IERC20.allowance, (alice, bob));
        _rule(token, ALLOWANCE, SUBJECT_MATCH, 1);
        _rule(implementation, ALLOWANCE, SUBJECT_MATCH, 2);

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
        _rule(token, bytes4(0), SUBJECT_MATCH, 1);
        assertFalse(spoke.canCall(alice, token, hex""));
        assertFalse(spoke.canCall(alice, token, hex"12"));
        assertFalse(spoke.canCall(alice, token, hex"1234"));
        assertFalse(spoke.canCall(alice, token, hex"123456"));
        assertFalse(spoke.canCall(alice, token, hex"00000000"));
        assertTrue(spoke.canCall(alice, token, abi.encodePacked(bytes4(0), abi.encode(alice))));
        assertTrue(spoke.canCall(alice, token, hex"12345678"));
    }

    function testFuzz_malformedSubjectDeniesWithoutReverting(address subject, uint96 highBits, uint8 length) public {
        _rule(token, BALANCE_OF, SUBJECT_MATCH, 1);
        assertTrue(spoke.canCall(subject, token, _balance(subject)));
        uint256 word = (uint256(highBits) << 160) | uint160(subject);
        bytes memory encoded = abi.encodePacked(BALANCE_OF, word);
        assertEq(spoke.canCall(subject, token, encoded), highBits == 0);
        bytes memory truncated = abi.encodePacked(BALANCE_OF, new bytes(uint256(length) % 32));
        assertFalse(spoke.canCall(subject, token, truncated));
    }

    function test_subjectBitsBeyondCalldataCannotMatch() public {
        _rule(token, BALANCE_OF, SUBJECT_MATCH, uint16(1) << 15);
        assertFalse(spoke.canCall(alice, token, _balance(alice)));
        _rule(token, BALANCE_OF, SUBJECT_MATCH, type(uint16).max);
        assertTrue(spoke.canCall(alice, token, _balance(alice)));
        assertFalse(spoke.canCall(bob, token, _balance(alice)));
    }

    function test_unknownAccessModeReverts() public {
        bytes memory data =
            abi.encodeWithSelector(rules.setAccessControl.selector, token, BALANCE_OF, uint8(3), uint16(0));
        vm.prank(policyOwner);
        (bool ok,) = address(rules).call(data);
        assertFalse(ok);
    }
}
