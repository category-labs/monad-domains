// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {DomainSpoke} from "../src/DomainSpoke.sol";
import {IDomainSpoke} from "../src/interfaces/IDomain.sol";
import {DomainTestBase} from "./helpers/DomainTestBase.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

/// @notice Exercises the domain access lists (Deploy, SendTx, ReadData) the spoke keeps: the
/// starting lists and admin its constructor takes, the admin's changes and two-step handover,
/// `deployContract` gating, and the raw storage layout the client reads.
/// @dev Each test expects at most one constructor revert, as its last call: with dynamic test
/// linking, `new` runs through `vm.deployCode` and a reverting constructor ends the test there.
contract DomainAccessListsTest is DomainTestBase {
    uint64 internal constant CHAIN_ID = 7777;
    IDomainSpoke.AccessList internal constant DEPLOY = IDomainSpoke.AccessList.Deploy;
    IDomainSpoke.AccessList internal constant SEND_TX = IDomainSpoke.AccessList.SendTx;
    IDomainSpoke.AccessList internal constant READ_DATA = IDomainSpoke.AccessList.ReadData;
    IDomainSpoke.AccessListMode internal constant CLOSED = IDomainSpoke.AccessListMode.Closed;
    IDomainSpoke.AccessListMode internal constant ALLOWLIST = IDomainSpoke.AccessListMode.Allowlist;
    IDomainSpoke.AccessListMode internal constant OPEN = IDomainSpoke.AccessListMode.Open;

    DomainSpoke internal spoke;

    address internal admin = makeAddr("admin");
    address internal nextAdmin = makeAddr("nextAdmin");
    address internal stranger = makeAddr("stranger");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        spoke = new DomainSpoke(CHAIN_ID, block.chainid, address(0x1234), admin, _closedAccess());
    }

    function _list1(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _list2(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = a;
        out[1] = b;
    }

    // ---------------------------------------------------------------------
    // Construction & defaults
    // ---------------------------------------------------------------------

    function test_defaultsFailClosed() public view {
        assertEq(spoke.admin(), admin);
        assertEq(spoke.pendingAdmin(), address(0));
        for (uint256 i = 0; i < 3; i++) {
            IDomainSpoke.AccessList list = IDomainSpoke.AccessList(i);
            assertEq(uint8(spoke.accessListModes(list)), uint8(CLOSED));
            assertFalse(spoke.isAllowed(list, alice));
        }
    }

    function test_constructorSetsAdminAndStartingLists() public {
        IDomainSpoke.DomainAccessConfig memory initial;
        initial.deploy = IDomainSpoke.AccessListConfig({mode: ALLOWLIST, members: _list1(alice)});
        initial.sendTx.mode = OPEN;
        // A list that is not an allowlist keeps its members for when it becomes one.
        initial.readData.members = _list1(bob);

        vm.expectEmit(true, true, false, false);
        emit IDomainSpoke.AdminTransferred(address(0), admin);
        vm.expectEmit(true, false, false, true);
        emit IDomainSpoke.AccessListModeSet(DEPLOY, ALLOWLIST);
        vm.expectEmit(true, true, false, true);
        emit IDomainSpoke.AccessListMemberSet(DEPLOY, alice, true);
        vm.expectEmit(true, false, false, true);
        emit IDomainSpoke.AccessListModeSet(SEND_TX, OPEN);
        vm.expectEmit(true, false, false, true);
        emit IDomainSpoke.AccessListModeSet(READ_DATA, CLOSED);
        vm.expectEmit(true, true, false, true);
        emit IDomainSpoke.AccessListMemberSet(READ_DATA, bob, true);
        DomainSpoke seeded = new DomainSpoke(CHAIN_ID, block.chainid, address(0x1234), admin, initial);

        assertEq(seeded.admin(), admin);
        // Deploy: an allowlist holding only alice.
        assertEq(uint8(seeded.accessListModes(DEPLOY)), uint8(ALLOWLIST));
        assertTrue(seeded.isAllowed(DEPLOY, alice));
        assertFalse(seeded.isAllowed(DEPLOY, bob));
        // SendTx: open to everyone.
        assertTrue(seeded.isAllowed(SEND_TX, stranger));
        // ReadData: closed, with bob kept until the admin makes it an allowlist.
        assertTrue(seeded.accessListMembers(READ_DATA, bob));
        assertFalse(seeded.isAllowed(READ_DATA, bob));
        vm.prank(admin);
        seeded.setAccessListMode(READ_DATA, ALLOWLIST);
        assertTrue(seeded.isAllowed(READ_DATA, bob));
    }

    function test_constructorRejectsZeroAdmin() public {
        vm.expectRevert(DomainSpoke.ZeroAdmin.selector);
        new DomainSpoke(CHAIN_ID, block.chainid, address(0x1234), address(0), _closedAccess());
    }

    // ---------------------------------------------------------------------
    // Authorization & two-step admin transfer
    // ---------------------------------------------------------------------

    function testFuzz_onlyAdminChangesAccessLists(address caller) public {
        vm.assume(caller != admin);
        vm.startPrank(caller);

        vm.expectRevert(DomainSpoke.NotAdmin.selector);
        spoke.setAccessListMode(DEPLOY, OPEN);

        vm.expectRevert(DomainSpoke.NotAdmin.selector);
        spoke.setAccessListMembers(DEPLOY, _list1(alice), true);

        vm.expectRevert(DomainSpoke.NotAdmin.selector);
        spoke.transferAdmin(caller);

        vm.stopPrank();
    }

    /// @dev The protocol's system transactions have no say over the lists either.
    function test_systemRelayerCannotChangeAccessLists() public {
        vm.prank(spoke.SYSTEM_RELAYER());
        vm.expectRevert(DomainSpoke.NotAdmin.selector);
        spoke.setAccessListMode(SEND_TX, OPEN);
    }

    function test_twoStepAdminTransferOverwriteAndCancel() public {
        // Nobody can accept while no transfer is pending.
        vm.prank(stranger);
        vm.expectRevert(DomainSpoke.NotPendingAdmin.selector);
        spoke.acceptAdmin();

        // Propose nextAdmin; admin stays active until accepted.
        vm.expectEmit(true, true, false, false, address(spoke));
        emit IDomainSpoke.AdminTransferStarted(admin, nextAdmin);
        vm.prank(admin);
        spoke.transferAdmin(nextAdmin);
        assertEq(spoke.admin(), admin);
        assertEq(spoke.pendingAdmin(), nextAdmin);

        // Stranger cannot accept.
        vm.prank(stranger);
        vm.expectRevert(DomainSpoke.NotPendingAdmin.selector);
        spoke.acceptAdmin();

        // Overwrite pending admin; previous nominee can no longer accept.
        vm.prank(admin);
        spoke.transferAdmin(bob);
        assertEq(spoke.pendingAdmin(), bob);
        vm.prank(nextAdmin);
        vm.expectRevert(DomainSpoke.NotPendingAdmin.selector);
        spoke.acceptAdmin();

        // Cancel by proposing address(0).
        vm.expectEmit(true, true, false, false, address(spoke));
        emit IDomainSpoke.AdminTransferStarted(admin, address(0));
        vm.prank(admin);
        spoke.transferAdmin(address(0));
        assertEq(spoke.pendingAdmin(), address(0));
        vm.prank(bob);
        vm.expectRevert(DomainSpoke.NotPendingAdmin.selector);
        spoke.acceptAdmin();

        // Re-propose and complete transfer.
        vm.prank(admin);
        spoke.transferAdmin(nextAdmin);
        vm.expectEmit(true, true, false, false, address(spoke));
        emit IDomainSpoke.AdminTransferred(admin, nextAdmin);
        vm.prank(nextAdmin);
        spoke.acceptAdmin();

        assertEq(spoke.admin(), nextAdmin);
        assertEq(spoke.pendingAdmin(), address(0));

        // Acceptance clears pendingAdmin so it cannot be replayed.
        vm.prank(nextAdmin);
        vm.expectRevert(DomainSpoke.NotPendingAdmin.selector);
        spoke.acceptAdmin();

        // Old admin loses permissions; new admin gains them.
        vm.prank(admin);
        vm.expectRevert(DomainSpoke.NotAdmin.selector);
        spoke.setAccessListMode(DEPLOY, OPEN);

        vm.prank(nextAdmin);
        spoke.setAccessListMode(DEPLOY, OPEN);
        assertTrue(spoke.isAllowed(DEPLOY, alice));
    }

    // ---------------------------------------------------------------------
    // Modes and members
    // ---------------------------------------------------------------------

    function test_modeTransitionsKeepMembers() public {
        vm.startPrank(admin);
        // Stage an allowlist while Closed.
        spoke.setAccessListMembers(DEPLOY, _list2(alice, bob), true);
        assertFalse(spoke.isAllowed(DEPLOY, alice));

        // Allowlist: the staged members take effect.
        spoke.setAccessListMode(DEPLOY, ALLOWLIST);
        assertTrue(spoke.isAllowed(DEPLOY, alice));
        assertTrue(spoke.isAllowed(DEPLOY, bob));
        assertFalse(spoke.isAllowed(DEPLOY, carol));

        // Open: every account, with the members kept.
        spoke.setAccessListMode(DEPLOY, OPEN);
        assertTrue(spoke.isAllowed(DEPLOY, carol));

        // Closed: nobody, with the members still kept.
        spoke.setAccessListMode(DEPLOY, CLOSED);
        assertFalse(spoke.isAllowed(DEPLOY, alice));

        // Allowlist again: the same members. Other lists stay closed throughout.
        spoke.setAccessListMode(DEPLOY, ALLOWLIST);
        vm.stopPrank();
        assertTrue(spoke.isAllowed(DEPLOY, alice));
        assertTrue(spoke.isAllowed(DEPLOY, bob));
        assertFalse(spoke.isAllowed(DEPLOY, carol));
        assertFalse(spoke.isAllowed(SEND_TX, alice));
        assertFalse(spoke.isAllowed(READ_DATA, alice));
    }

    /// @dev As with `setLogReader`, every change is written and logged, even one that changes
    /// nothing.
    function test_setAccessListMembersLogsEveryAccount() public {
        vm.startPrank(admin);
        spoke.setAccessListMode(READ_DATA, ALLOWLIST);

        vm.expectEmit(true, true, false, true, address(spoke));
        emit IDomainSpoke.AccessListMemberSet(READ_DATA, alice, true);
        vm.expectEmit(true, true, false, true, address(spoke));
        emit IDomainSpoke.AccessListMemberSet(READ_DATA, bob, true);
        spoke.setAccessListMembers(READ_DATA, _list2(alice, bob), true);

        // Removing bob and a stranger who was never listed logs both.
        vm.expectEmit(true, true, false, true, address(spoke));
        emit IDomainSpoke.AccessListMemberSet(READ_DATA, bob, false);
        vm.expectEmit(true, true, false, true, address(spoke));
        emit IDomainSpoke.AccessListMemberSet(READ_DATA, stranger, false);
        spoke.setAccessListMembers(READ_DATA, _list2(bob, stranger), false);

        // Setting the mode the list already has logs it again.
        vm.expectEmit(true, false, false, true, address(spoke));
        emit IDomainSpoke.AccessListModeSet(READ_DATA, ALLOWLIST);
        spoke.setAccessListMode(READ_DATA, ALLOWLIST);

        // An empty batch logs nothing.
        vm.recordLogs();
        spoke.setAccessListMembers(READ_DATA, new address[](0), true);
        assertEq(vm.getRecordedLogs().length, 0);
        vm.stopPrank();

        assertTrue(spoke.accessListMembers(READ_DATA, alice));
        assertFalse(spoke.accessListMembers(READ_DATA, bob));
        assertTrue(spoke.isAllowed(READ_DATA, alice));
        assertFalse(spoke.isAllowed(READ_DATA, bob));
        assertFalse(spoke.isAllowed(READ_DATA, stranger));
    }

    /// @dev The zero address can be listed, but no list admits it, open or not.
    function test_noListAdmitsTheZeroAddress() public {
        vm.startPrank(admin);
        spoke.setAccessListMembers(SEND_TX, _list1(address(0)), true);
        spoke.setAccessListMode(SEND_TX, ALLOWLIST);
        assertTrue(spoke.accessListMembers(SEND_TX, address(0)));
        assertFalse(spoke.isAllowed(SEND_TX, address(0)));

        spoke.setAccessListMode(SEND_TX, OPEN);
        vm.stopPrank();
        assertFalse(spoke.isAllowed(SEND_TX, address(0)));
        assertTrue(spoke.isAllowed(SEND_TX, alice));
    }

    // ---------------------------------------------------------------------
    // `deployContract` gating & storage layout
    // ---------------------------------------------------------------------

    function test_deployContractEnforcesDeployAccessList() public {
        // Closed by default: deployContract reverts without advancing the spoke's nonce.
        uint64 nonce = vm.getNonce(address(spoke));
        vm.prank(alice);
        vm.expectRevert(DomainSpoke.DeployNotAllowed.selector);
        spoke.deployContract(type(TestERC20).creationCode, alice);
        assertEq(vm.getNonce(address(spoke)), nonce);

        // Opening SendTx and ReadData does not grant Deploy access.
        vm.startPrank(admin);
        spoke.setAccessListMode(SEND_TX, OPEN);
        spoke.setAccessListMode(READ_DATA, OPEN);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(DomainSpoke.DeployNotAllowed.selector);
        spoke.deployContract(type(TestERC20).creationCode, alice);

        // Allowlist: only listed deployers succeed.
        vm.startPrank(admin);
        spoke.setAccessListMode(DEPLOY, ALLOWLIST);
        spoke.setAccessListMembers(DEPLOY, _list1(alice), true);
        vm.stopPrank();

        vm.prank(alice);
        address deployed = spoke.deployContract(type(TestERC20).creationCode, alice);
        assertTrue(deployed.code.length > 0);

        nonce = vm.getNonce(address(spoke));
        vm.prank(bob);
        vm.expectRevert(DomainSpoke.DeployNotAllowed.selector);
        spoke.deployContract(type(TestERC20).creationCode, bob);
        assertEq(vm.getNonce(address(spoke)), nonce);

        // Removing alice blocks her again.
        vm.prank(admin);
        spoke.setAccessListMembers(DEPLOY, _list1(alice), false);
        vm.prank(alice);
        vm.expectRevert(DomainSpoke.DeployNotAllowed.selector);
        spoke.deployContract(type(TestERC20).creationCode, alice);

        // Open: any caller can deploy.
        vm.prank(admin);
        spoke.setAccessListMode(DEPLOY, OPEN);
        vm.prank(stranger);
        address openDeployed = spoke.deployContract(type(TestERC20).creationCode, stranger);
        assertTrue(openDeployed.code.length > 0);
    }

    /// @dev The client reads these two slots directly from state, as the RPC reads the log
    /// access slots.
    function test_accessListStorageSlots() public {
        vm.startPrank(admin);
        spoke.setAccessListMode(READ_DATA, ALLOWLIST);
        spoke.setAccessListMembers(READ_DATA, _list1(carol), true);
        vm.stopPrank();
        bytes32 modeSlot = keccak256(abi.encode(READ_DATA, uint256(7)));
        bytes32 memberSlot = keccak256(abi.encode(carol, keccak256(abi.encode(READ_DATA, uint256(8)))));
        assertEq(vm.load(address(spoke), modeSlot), bytes32(uint256(ALLOWLIST)));
        assertEq(vm.load(address(spoke), memberSlot), bytes32(uint256(1)));
    }

    // ---------------------------------------------------------------------
    // Model-based fuzz test
    // ---------------------------------------------------------------------

    function testFuzz_accessListsMatchModel(uint256 seed) public {
        IDomainSpoke.AccessListMode[3] memory modes;
        uint8[3] memory members;

        vm.startPrank(admin);
        for (uint256 step = 0; step < 40; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 k = seed % 3;
            IDomainSpoke.AccessList list = IDomainSpoke.AccessList(k);
            uint256 n = (seed >> 8) % 4;
            address[] memory batch = new address[](n);
            uint8 bits;
            for (uint256 i = 0; i < n; i++) {
                uint256 index = (seed >> (16 + i * 4)) & 7;
                batch[i] = address(uint160(0x101 + index));
                bits |= uint8(1 << index);
            }

            uint256 op = (seed >> 2) % 3;
            if (op == 0) {
                IDomainSpoke.AccessListMode mode = IDomainSpoke.AccessListMode((seed >> 32) % 3);
                spoke.setAccessListMode(list, mode);
                modes[k] = mode;
            } else if (op == 1) {
                spoke.setAccessListMembers(list, batch, true);
                members[k] |= bits;
            } else {
                spoke.setAccessListMembers(list, batch, false);
                members[k] &= ~bits;
            }
            _assertMatchesModel(modes, members);
        }
        vm.stopPrank();
    }

    /// @dev Checks every list's mode, and the membership and verdict of the model's eight
    /// accounts, against the model: `members[list]` holds one bit per account.
    function _assertMatchesModel(IDomainSpoke.AccessListMode[3] memory modes, uint8[3] memory members) internal view {
        for (uint256 j = 0; j < 3; j++) {
            IDomainSpoke.AccessList list = IDomainSpoke.AccessList(j);
            assertEq(uint8(spoke.accessListModes(list)), uint8(modes[j]));
            assertFalse(spoke.isAllowed(list, address(0)));
            for (uint256 index = 0; index < 8; index++) {
                address account = address(uint160(0x101 + index));
                bool member = (members[j] >> index) & 1 == 1;
                assertEq(spoke.accessListMembers(list, account), member);
                assertEq(spoke.isAllowed(list, account), modes[j] == OPEN || (modes[j] == ALLOWLIST && member));
            }
        }
    }
}
