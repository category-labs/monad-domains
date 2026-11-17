// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {DomainHub} from "../src/DomainHub.sol";
import {DomainSpoke} from "../src/DomainSpoke.sol";
import {DomainTestBase} from "./helpers/DomainTestBase.sol";
import {DomainHubV2} from "./mocks/DomainHubV2.sol";

/// @notice The hub behind its proxy: who may upgrade it, what an upgrade must keep (address,
/// state, input queue and the digest validators sign) and what it may replace.
contract DomainHubUpgradeTest is DomainTestBase {
    uint64 internal constant CHAIN_ID = 7777;
    uint256 internal constant VALIDATOR_KEY = 0xA11CE;
    address internal constant L1_SYSTEM_SENDER = 0x6f49a8F621353f12378d0046E7d7e4b9B249DC9e;

    DomainHub internal hub;
    address internal implementation;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        hub = _deployHub(owner);
        implementation = _implementation();
        _registerDomain(hub, CHAIN_ID, VALIDATOR_KEY);
        vm.deal(alice, 100 ether);
        vm.roll(100);
    }

    /// @dev The implementation the proxy delegates to, from its ERC-1967 slot.
    function _implementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(hub), ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    function _upgrade(address newImplementation, bytes memory data) internal {
        vm.prank(owner);
        hub.upgradeToAndCall(newImplementation, data);
    }

    // ---------------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------------

    function test_proxyIsInitializedWithItsOwner() public view {
        assertEq(hub.owner(), owner);
        assertTrue(implementation != address(hub));
        assertTrue(implementation.code.length > 0);
    }

    function test_hubCannotBeInitializedAgain() public {
        vm.prank(owner);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        hub.initialize(stranger);
    }

    function test_implementationCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        DomainHub(implementation).initialize(stranger);
        assertEq(DomainHub(implementation).owner(), address(0));
    }

    function test_proxyRejectsZeroOwner() public {
        address fresh = address(new DomainHub());
        bytes memory initialization = abi.encodeCall(DomainHub.initialize, (address(0)));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
        new ERC1967Proxy(fresh, initialization);
    }

    // ---------------------------------------------------------------------
    // Authorization
    // ---------------------------------------------------------------------

    function testFuzz_onlyTheOwnerUpgrades(address caller) public {
        vm.assume(caller != owner);
        vm.assume(caller != L1_SYSTEM_SENDER);
        address next = address(new DomainHubV2());
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, caller));
        hub.upgradeToAndCall(next, "");
        assertEq(_implementation(), implementation);
    }

    function test_newOwnerUpgradesAndOldOneDoesNot() public {
        address next = address(new DomainHubV2());
        vm.prank(owner);
        hub.transferOwnership(stranger);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        hub.upgradeToAndCall(next, "");

        vm.prank(stranger);
        hub.upgradeToAndCall(next, "");
        assertEq(_implementation(), next);
    }

    function test_renouncingOwnershipEndsUpgrades() public {
        address next = address(new DomainHubV2());
        vm.prank(owner);
        hub.renounceOwnership();
        assertEq(hub.owner(), address(0));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        hub.upgradeToAndCall(next, "");
        // The hub itself keeps working.
        vm.prank(alice);
        hub.sequenceToDomain{value: _sequencingFee(3)}(CHAIN_ID, hex"010203");
    }

    function test_implementationCannotBeUpgradedDirectly() public {
        address next = address(new DomainHubV2());
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        DomainHub(implementation).upgradeToAndCall(next, "");
    }

    /// @dev A contract without the upgrade function would leave the hub stuck on it.
    function test_rejectsImplementationThatCannotUpgrade() public {
        address notAHub = address(new DomainSpoke(CHAIN_ID, block.chainid, address(hub)));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, notAHub));
        hub.upgradeToAndCall(notAHub, "");
        assertEq(_implementation(), implementation);
    }

    // ---------------------------------------------------------------------
    // What an upgrade keeps and replaces
    // ---------------------------------------------------------------------

    function test_upgradeEmitsUpgradedAndRunsTheMigration() public {
        address next = address(new DomainHubV2());
        vm.expectEmit(address(hub));
        emit IERC1967.Upgraded(next);
        _upgrade(next, abi.encodeCall(DomainHubV2.migrate, (42)));

        assertEq(_implementation(), next);
        assertEq(DomainHubV2(address(hub)).version(), 2);
        assertEq(DomainHubV2(address(hub)).migrated(), 42);
        // A migration runs once.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        DomainHubV2(address(hub)).migrate(43);
    }

    function test_upgradeKeepsRegistrationsStateAndInputQueue() public {
        vm.startPrank(alice);
        hub.sequenceToDomain{value: _sequencingFee(64)}(CHAIN_ID, new bytes(64));
        hub.sendL1Message{value: DELIVERY_FEE}(CHAIN_ID, bob, hex"c0ffee");
        vm.stopPrank();
        bytes32 root = keccak256("state root");
        bytes32 anchor = keccak256("anchor");
        _attest(hub, CHAIN_ID, 100, root, anchor, _keys(VALIDATOR_KEY));
        vm.prank(alice);
        hub.sequenceToDomain{value: _sequencingFee(3)}(CHAIN_ID, hex"010203");

        (uint64 head, uint64 tail) = _queueBounds(hub, CHAIN_ID);
        assertGt(head, tail);
        bytes32[] memory queueWords = new bytes32[](128 + head);
        for (uint256 i = 0; i < queueWords.length; i++) {
            queueWords[i] = bytes32(_queueWord(hub, CHAIN_ID, i));
        }

        _upgrade(address(new DomainHubV2()), "");

        assertEq(hub.owner(), owner);
        assertTrue(hub.isDomainRegistered(CHAIN_ID));
        assertEq(hub.getValidators(CHAIN_ID), _addresses(_keys(VALIDATOR_KEY)));
        assertEq(hub.quorums(CHAIN_ID), 1);
        assertEq(hub.feeRecipients(CHAIN_ID), address(this));
        assertEq(hub.checkpointIntervals(CHAIN_ID), CHECKPOINT_INTERVAL);
        assertEq(hub.stateRoots(CHAIN_ID), root);
        assertTrue(hub.domainAnchors(CHAIN_ID, anchor));
        assertEq(hub.stateNonces(CHAIN_ID), 1);
        assertEq(hub.domainBlockNumbers(CHAIN_ID), 100);
        assertEq(hub.l1MessageCounts(CHAIN_ID), 1);
        for (uint256 i = 0; i < queueWords.length; i++) {
            assertEq(bytes32(_queueWord(hub, CHAIN_ID, i)), queueWords[i], "queue word");
        }

        // The upgraded hub carries on from that state: the next message takes the next nonce.
        vm.roll(block.number + 1);
        vm.prank(alice);
        hub.sendL1Message{value: DELIVERY_FEE}(CHAIN_ID, bob, hex"");
        assertEq(hub.l1MessageCounts(CHAIN_ID), 2);
    }

    /// @dev The EIP-712 domain names the proxy, so validators sign the same digest whichever
    /// implementation is behind it.
    function test_signatureMadeBeforeAnUpgradeIsAcceptedAfter() public {
        bytes32 root = keccak256("state root");
        bytes32 digest = hub.stateTransitionDigest(CHAIN_ID, 90, root, bytes32(0));
        bytes memory signature = _signTransition(hub, CHAIN_ID, 90, root, bytes32(0), VALIDATOR_KEY);
        (,,,, address verifyingContract,,) = hub.eip712Domain();
        assertEq(verifyingContract, address(hub));

        _upgrade(address(new DomainHubV2()), "");

        assertEq(hub.stateTransitionDigest(CHAIN_ID, 90, root, bytes32(0)), digest);
        hub.submitStateSignature(CHAIN_ID, 90, root, bytes32(0), signature);
        assertEq(hub.stateRoots(CHAIN_ID), root);
    }

    /// @dev Each implementation deploys its own slot number probe.
    function test_upgradeReplacesTheSlotNumberProbe() public {
        address probe = hub.SLOT_NUMBER_PROBE();
        assertEq(probe, DomainHub(implementation).SLOT_NUMBER_PROBE());
        DomainHubV2 next = new DomainHubV2();
        _upgrade(address(next), "");
        assertEq(hub.SLOT_NUMBER_PROBE(), next.SLOT_NUMBER_PROBE());
        assertTrue(hub.SLOT_NUMBER_PROBE() != probe);
    }
}
