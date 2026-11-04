// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DomainHub} from "../src/DomainHub.sol";
import {MessageLib} from "../src/libraries/MessageLib.sol";
import {DomainTestBase} from "./helpers/DomainTestBase.sol";

/// @notice Backpressure on the hub. The first sale after a quorum opens a domain's attestation
/// backlog; once it has waited more than the domain's attestation timeout for the next quorum,
/// every paying path refuses the domain, and any quorum reopens it. CHAIN_ID is registered with
/// the smallest timeout the hub accepts; OTHER_CHAIN_ID with the shared, generous one.
contract DomainLivenessTest is DomainTestBase {
    uint64 internal constant CHAIN_ID = 7777;
    uint64 internal constant OTHER_CHAIN_ID = 8888;
    uint64 internal constant TIMEOUT = 2 * CHECKPOINT_INTERVAL;
    uint256 internal constant K1 = 0xA11CE;
    uint256 internal constant K2 = 0xB0B;
    bytes internal constant PAYLOAD = hex"c0ffee";

    DomainHub internal hub;
    address internal alice = makeAddr("alice");
    address internal target = makeAddr("target");

    function setUp() public {
        hub = new DomainHub();
        _registerTight(CHAIN_ID, _keys(K1), 1);
        _registerDomain(hub, OTHER_CHAIN_ID, K1);
        vm.deal(alice, 100 ether);
    }

    /// @dev Registers `chainId` with the smallest attestation timeout the hub accepts.
    function _registerTight(uint64 chainId, uint256[] memory keys, uint256 quorum) internal {
        hub.registerDomain(chainId, _addresses(keys), quorum, address(this), "", CHECKPOINT_INTERVAL, TIMEOUT);
    }

    function _sequence(uint64 chainId, uint256 fee) internal {
        vm.prank(alice);
        hub.sequenceToDomain{value: fee}(chainId, PAYLOAD);
    }

    function _backlogSince(uint64 chainId) internal view returns (uint64 since) {
        (,, since) = hub.blockGasSales(chainId);
    }

    /// @dev Attests CHAIN_ID at its next scheduled height, rolling past it if needed.
    function _attest() internal {
        _attestNext(hub, CHAIN_ID, keccak256("root"), bytes32(0), _keys(K1));
    }

    /// @dev One validator's vote for `chainId` at `height`.
    function _vote(uint64 chainId, uint64 height, uint256 key) internal {
        bytes32 root = keccak256("root");
        hub.submitStateSignature(
            chainId, height, root, bytes32(0), _signTransition(hub, chainId, height, root, bytes32(0), key)
        );
    }

    /// @dev A single-leaf batch: the message hash is its own anchor and the proof is empty.
    function _message(uint64 source, uint64 destination) internal view returns (MessageLib.DomainMessage memory) {
        return MessageLib.DomainMessage(source, destination, alice, target, 0, PAYLOAD);
    }

    function _anchor(MessageLib.DomainMessage memory message) internal view returns (bytes32) {
        return MessageLib.hashDomainMessage(message, block.chainid, address(hub));
    }

    // ---------------------------------------------------------------------
    // Opening a backlog
    // ---------------------------------------------------------------------

    function test_idleDomainNeverStalls() public {
        vm.roll(block.number + 1_000_000);
        assertTrue(hub.isDomainLive(CHAIN_ID));
        assertEq(_backlogSince(CHAIN_ID), 0);

        _sequence(CHAIN_ID, 1 ether);
        assertEq(_backlogSince(CHAIN_ID), block.number);
    }

    function test_unregisteredDomainIsNotLive() public view {
        assertFalse(hub.isDomainLive(9999));
    }

    function test_everySaleOpensTheBacklogAndLaterSalesKeepIt() public {
        // The smallest sale the hub accepts buys the gas a transaction needs to execute, so it
        // is work the validators must attest.
        uint64 opened = uint64(block.number);
        _sequence(CHAIN_ID, hub.minSequencingFee());
        assertEq(_backlogSince(CHAIN_ID), opened);

        vm.roll(opened + 5);
        _sequence(CHAIN_ID, 1 ether);
        vm.prank(alice);
        hub.sendL1Message{value: DELIVERY_FEE}(CHAIN_ID, target, PAYLOAD);
        assertEq(_backlogSince(CHAIN_ID), opened);

        // Messages open one too, and domains have independent backlogs.
        assertEq(_backlogSince(OTHER_CHAIN_ID), 0);
        vm.prank(alice);
        hub.sendL1Message{value: DELIVERY_FEE}(OTHER_CHAIN_ID, target, PAYLOAD);
        assertEq(_backlogSince(OTHER_CHAIN_ID), opened + 5);
        assertEq(_backlogSince(CHAIN_ID), opened);
    }

    function test_attestedDomainStaysLiveWhileIdle() public {
        _sequence(CHAIN_ID, 1 ether);
        _attest();
        assertEq(_backlogSince(CHAIN_ID), 0);

        vm.roll(block.number + 1_000_000);
        assertTrue(hub.isDomainLive(CHAIN_ID));
        vm.prank(alice);
        hub.sendEncryptedL1Message{value: DELIVERY_FEE}(CHAIN_ID, PAYLOAD);
        assertEq(_backlogSince(CHAIN_ID), block.number);
    }

    // ---------------------------------------------------------------------
    // Stalling
    // ---------------------------------------------------------------------

    function test_everyPayingPathStallsOncePastTheTimeout() public {
        uint64 opened = uint64(block.number);
        _sequence(CHAIN_ID, 1 ether);

        // The last block the backlog may wait in still sells.
        vm.roll(opened + TIMEOUT);
        assertTrue(hub.isDomainLive(CHAIN_ID));
        _sequence(CHAIN_ID, 1 ether);

        vm.roll(opened + TIMEOUT + 1);
        assertFalse(hub.isDomainLive(CHAIN_ID));
        vm.startPrank(alice);
        vm.expectRevert("DomainHub: domain attestation stalled");
        hub.sequenceToDomain{value: 1 ether}(CHAIN_ID, PAYLOAD);
        vm.expectRevert("DomainHub: domain attestation stalled");
        hub.sendL1Message{value: DELIVERY_FEE}(CHAIN_ID, target, PAYLOAD);
        vm.expectRevert("DomainHub: domain attestation stalled");
        hub.sendEncryptedL1Message{value: DELIVERY_FEE}(CHAIN_ID, PAYLOAD);
        vm.stopPrank();

        // Other domains are unaffected.
        assertTrue(hub.isDomainLive(OTHER_CHAIN_ID));
        _sequence(OTHER_CHAIN_ID, 1 ether);
    }

    function testFuzz_backlogAgeDecidesLiveness(uint64 age) public {
        age = uint64(bound(age, 0, 3 * TIMEOUT));
        uint64 opened = uint64(block.number);
        _sequence(CHAIN_ID, 1 ether);

        vm.roll(opened + age);
        assertEq(hub.isDomainLive(CHAIN_ID), age <= TIMEOUT);
        if (age > TIMEOUT) vm.expectRevert("DomainHub: domain attestation stalled");
        _sequence(CHAIN_ID, 1 ether);
    }

    function test_stalledDestinationRefusesAForwardedMessageWithoutConsumingIt() public {
        _sequence(CHAIN_ID, 1 ether);
        vm.roll(block.number + TIMEOUT + 1);
        assertFalse(hub.isDomainLive(CHAIN_ID));

        MessageLib.DomainMessage memory message = _message(OTHER_CHAIN_ID, CHAIN_ID);
        bytes32 anchor = _anchor(message);
        _attestNext(hub, OTHER_CHAIN_ID, keccak256("root"), anchor, _keys(K1));

        vm.expectRevert("DomainHub: domain attestation stalled");
        hub.relayDomainMessage{value: DELIVERY_FEE}(message, anchor, new bytes32[](0));
        assertFalse(hub.relayedDomainMessages(OTHER_CHAIN_ID, anchor));

        // Once the destination's validators reach quorum the same relay goes through.
        _attest();
        assertTrue(hub.relayDomainMessage{value: DELIVERY_FEE}(message, anchor, new bytes32[](0)));
        assertTrue(hub.relayedDomainMessages(OTHER_CHAIN_ID, anchor));
        assertEq(_backlogSince(CHAIN_ID), block.number);
    }

    function test_stalledSourceStillRelaysToL1() public {
        MessageLib.DomainMessage memory message = _message(CHAIN_ID, uint64(block.chainid));
        bytes32 anchor = _anchor(message);
        _attestNext(hub, CHAIN_ID, keccak256("root"), anchor, _keys(K1));

        _sequence(CHAIN_ID, 1 ether);
        vm.roll(block.number + TIMEOUT + 1);
        assertFalse(hub.isDomainLive(CHAIN_ID));

        // An L1 callback sells the source domain nothing, so its backlog is irrelevant.
        assertTrue(hub.relayDomainMessage(message, anchor, new bytes32[](0)));
    }

    // ---------------------------------------------------------------------
    // Recovering
    // ---------------------------------------------------------------------

    function test_aQuorumClearsTheBacklogAndTheNextSaleOpensANewOne() public {
        uint64 opened = uint64(block.number);
        _sequence(CHAIN_ID, 1 ether);
        vm.roll(opened + TIMEOUT + 1);
        assertFalse(hub.isDomainLive(CHAIN_ID));

        // Attestation is never blocked, and the quorum reopens the domain at once.
        _attest();
        assertTrue(hub.isDomainLive(CHAIN_ID));
        assertEq(_backlogSince(CHAIN_ID), 0);

        uint64 reopened = uint64(block.number);
        _sequence(CHAIN_ID, 1 ether);
        assertEq(_backlogSince(CHAIN_ID), reopened);
        vm.roll(reopened + TIMEOUT);
        _sequence(CHAIN_ID, 1 ether);
        vm.roll(reopened + TIMEOUT + 1);
        assertFalse(hub.isDomainLive(CHAIN_ID));
    }

    function test_subQuorumVotesLeaveTheBacklogOpen() public {
        uint64 chainId = 9999;
        _registerTight(chainId, _keys(K1, K2), 2);
        uint64 opened = uint64(block.number);
        _sequence(chainId, 1 ether);
        vm.roll(opened + TIMEOUT + 1);
        assertFalse(hub.isDomainLive(chainId));

        uint64 height = _nextCheckpointHeight(hub, chainId);
        _vote(chainId, height, K1);
        assertEq(hub.domainBlockNumbers(chainId), 0);
        assertEq(_backlogSince(chainId), opened);
        assertFalse(hub.isDomainLive(chainId));

        _vote(chainId, height, K2);
        assertEq(hub.domainBlockNumbers(chainId), height);
        assertEq(_backlogSince(chainId), 0);
        assertTrue(hub.isDomainLive(chainId));
    }

    function test_aQuorumWithNothingPendingChangesNothing() public {
        _attest();
        assertEq(_backlogSince(CHAIN_ID), 0);
        assertTrue(hub.isDomainLive(CHAIN_ID));
    }

    function test_quorumAndSaleInTheSameBlock() public {
        // A sale before the quorum in its block is cleared by it, although the attested height
        // lies below the block.
        vm.roll(CHECKPOINT_INTERVAL + 1);
        _sequence(CHAIN_ID, 1 ether);
        _attest();
        assertEq(hub.domainBlockNumbers(CHAIN_ID), CHECKPOINT_INTERVAL);
        assertEq(_backlogSince(CHAIN_ID), 0);

        // A sale after the quorum in the same block opens the next backlog there.
        _sequence(CHAIN_ID, 1 ether);
        assertEq(_backlogSince(CHAIN_ID), block.number);
    }

    function test_quorumAtAnyHeightClearsTheBacklog() public {
        // Validators far behind the tip still keep the domain live with every quorum they reach.
        uint64 opened = uint64(block.number);
        _sequence(CHAIN_ID, 1 ether);
        vm.roll(opened + 10 * CHECKPOINT_INTERVAL);
        assertFalse(hub.isDomainLive(CHAIN_ID));

        _attest();
        assertEq(hub.domainBlockNumbers(CHAIN_ID), CHECKPOINT_INTERVAL);
        assertTrue(hub.isDomainLive(CHAIN_ID));
    }
}
