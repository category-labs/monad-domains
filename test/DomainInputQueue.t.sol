// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DomainHub} from "../src/DomainHub.sol";
import {InputQueue} from "../src/libraries/InputQueue.sol";
import {DomainTestBase} from "./helpers/DomainTestBase.sol";

contract DomainInputQueueTest is DomainTestBase {
    uint64 internal constant CHAIN_ID = 7777;
    uint256 internal constant VALIDATOR_KEY = 0xA11CE;

    /// @dev Payload bytes of a block record without a slot number.
    uint256 internal constant BLOCK_RECORD_LENGTH = 40;

    DomainHub internal hub;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        hub = new DomainHub();
        _registerDomain(hub, CHAIN_ID, VALIDATOR_KEY);
        vm.deal(alice, 1_000_000 ether);
        vm.roll(1);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _entries(uint64 chainId) internal view returns (InputQueue.Entry[] memory entries) {
        (uint64 head, uint64 tail) = hub.inputQueueBounds(chainId);
        uint256 count;
        for (uint64 i = tail; i < head; count++) {
            (, i) = hub.inputQueueEntry(chainId, i);
        }
        entries = new InputQueue.Entry[](count);
        uint64 index = tail;
        for (uint256 j = 0; j < count; j++) {
            (entries[j], index) = hub.inputQueueEntry(chainId, index);
        }
    }

    /// @dev The queue's entries without the block records.
    function _inputs(uint64 chainId) internal view returns (InputQueue.Entry[] memory inputs) {
        InputQueue.Entry[] memory entries = _entries(chainId);
        uint8 blockKind = hub.INPUT_BLOCK();
        uint256 count;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].kind != blockKind) count++;
        }
        inputs = new InputQueue.Entry[](count);
        uint256 j;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].kind != blockKind) inputs[j++] = entries[i];
        }
    }

    /// @dev Replaces the slot number probe's code: `runtime` that returns a word makes the L1
    /// block have that slot number, and one that fails makes it have none.
    function _etchSlotNumberProbe(bytes memory runtime) internal {
        vm.etch(hub.SLOT_NUMBER_PROBE(), runtime);
    }

    function _payload(uint256 length, uint256 seed) internal pure returns (bytes memory payload) {
        payload = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            // Mostly zero bytes with the odd nonzero one: the worst case for zero words.
            payload[i] = (i + seed) % 97 == 0 ? bytes1(uint8(seed + i)) : bytes1(0);
        }
    }

    /// @dev Makes every data word nonzero, as after the ring's first lap, so filling it does
    /// not pay for state growth.
    function _lapRing() internal {
        uint256 data = hub.inputQueueBase(CHAIN_ID) + 128;
        uint256 capacity = hub.INPUT_QUEUE_CAPACITY();
        for (uint256 i = 0; i < capacity; i++) {
            vm.store(address(hub), bytes32(data + i), bytes32(uint256(1)));
        }
    }

    /// @dev Empties the queue and puts its head and tail at `words`, as if that many had been
    /// written and released.
    function _advanceEmptyQueue(uint64 words) internal {
        vm.store(address(hub), bytes32(hub.inputQueueBase(CHAIN_ID)), bytes32((uint256(words) << 64) | words));
    }

    function _sequence(bytes memory rlpTx) internal {
        vm.prank(alice);
        hub.sequenceToDomain(CHAIN_ID, rlpTx);
    }

    function _attestAt(uint64 l1Block) internal {
        _attest(hub, CHAIN_ID, l1Block, bytes32(uint256(l1Block)), bytes32(0), _keys(VALIDATOR_KEY));
    }

    // ---------------------------------------------------------------------
    // Recording
    // ---------------------------------------------------------------------

    function test_recordsTransactionsAndMessagesInL1Order() public {
        uint256 fee = hub.minDeliveryFee(3);
        vm.warp(1_000);
        vm.prank(alice);
        hub.sequenceToDomain{value: 1 ether}(CHAIN_ID, hex"c0ffee");
        vm.roll(2);
        vm.warp(1_001);
        vm.prank(alice);
        hub.sendL1Message{value: fee}(CHAIN_ID, bob, hex"010203");
        vm.prank(alice);
        hub.sendEncryptedL1Message{value: fee}(CHAIN_ID, hex"aabbcc");

        InputQueue.Entry[] memory entries = _inputs(CHAIN_ID);
        assertEq(entries.length, 3);

        assertEq(entries[0].kind, hub.INPUT_TRANSACTION());
        assertEq(entries[0].l1BlockNumber, 1);
        assertEq(entries[0].l1Timestamp, 1_000);
        assertEq(entries[0].fee, 1 ether);
        assertEq(entries[0].payload, hex"c0ffee");

        assertEq(entries[1].kind, hub.INPUT_MESSAGE());
        assertEq(entries[1].l1BlockNumber, 2);
        assertEq(entries[1].l1Timestamp, 1_001);
        assertEq(entries[1].fee, fee);
        assertEq(entries[1].payload, abi.encodePacked(uint64(block.chainid), alice, bob, uint64(0), hex"010203"));

        assertEq(entries[2].kind, hub.INPUT_ENCRYPTED_MESSAGE());
        assertEq(entries[2].fee, fee);
        assertEq(entries[2].payload, abi.encodePacked(uint64(block.chainid), alice, uint64(1), hex"aabbcc"));
    }

    function test_registrationOpensBlockZero() public {
        vm.roll(7);
        vm.warp(2_000);
        vm.prevrandao(bytes32(uint256(0xbeef)));
        _registerDomain(hub, 8888, VALIDATOR_KEY);
        // Inputs of the registering L1 block belong to block 0.
        vm.prank(alice);
        hub.sequenceToDomain(8888, hex"01");

        InputQueue.Entry[] memory entries = _entries(8888);
        assertEq(entries.length, 2);
        assertEq(entries[0].kind, hub.INPUT_BLOCK());
        assertEq(entries[0].l1BlockNumber, 7);
        assertEq(entries[0].l1Timestamp, 2_000);
        assertEq(entries[0].fee, 0);
        assertEq(entries[0].payload, abi.encodePacked(bytes32(uint256(0xbeef)), uint64(0)));
        assertEq(entries[1].kind, hub.INPUT_TRANSACTION());

        (uint64 l1BlockNumber, uint64 domainBlockNumber) = hub.latestDomainBlock(8888);
        assertEq(l1BlockNumber, 7);
        assertEq(domainBlockNumber, 0);
    }

    function test_firstInputOfAnL1BlockOpensTheNextDomainBlock() public {
        uint256 fee = hub.minDeliveryFee(1);
        vm.roll(5);
        vm.prevrandao(bytes32(uint256(5)));
        _sequence(hex"05");
        vm.prank(alice);
        hub.sendL1Message{value: fee}(CHAIN_ID, bob, hex"01");
        (uint64 l1BlockNumber, uint64 domainBlockNumber) = hub.latestDomainBlock(CHAIN_ID);
        assertEq(l1BlockNumber, 5);
        assertEq(domainBlockNumber, 1);

        // L1 blocks without inputs open nothing.
        vm.roll(9);
        vm.prevrandao(bytes32(uint256(9)));
        vm.prank(alice);
        hub.sendEncryptedL1Message{value: fee}(CHAIN_ID, hex"02");
        (l1BlockNumber, domainBlockNumber) = hub.latestDomainBlock(CHAIN_ID);
        assertEq(l1BlockNumber, 9);
        assertEq(domainBlockNumber, 2);

        // Registration, then each block's record ahead of its inputs.
        InputQueue.Entry[] memory entries = _entries(CHAIN_ID);
        assertEq(entries.length, 6);
        uint8 blockKind = hub.INPUT_BLOCK();
        assertEq(entries[0].kind, blockKind);
        assertEq(entries[1].kind, blockKind);
        assertEq(entries[1].l1BlockNumber, 5);
        assertEq(entries[1].payload, abi.encodePacked(bytes32(uint256(5)), uint64(1)));
        assertEq(entries[2].kind, hub.INPUT_TRANSACTION());
        assertEq(entries[3].kind, hub.INPUT_MESSAGE());
        assertEq(entries[4].kind, blockKind);
        assertEq(entries[4].l1BlockNumber, 9);
        assertEq(entries[4].payload, abi.encodePacked(bytes32(uint256(9)), uint64(2)));
        assertEq(entries[5].kind, hub.INPUT_ENCRYPTED_MESSAGE());

        // The gas budget shares the word and still resets per L1 block.
        (uint64 gasBlock, uint192 gasSold) = hub.blockGas(CHAIN_ID);
        assertEq(gasBlock, 9);
        assertEq(gasSold, fee / hub.DOMAIN_GAS_PRICE());
    }

    function test_blockRecordCarriesTheSlotNumberWhenTheL1HasOne() public {
        // SLOTNUM PUSH0 MSTORE PUSH1 32 PUSH0 RETURN
        assertEq(hub.SLOT_NUMBER_PROBE().code, hex"4b5f5260205ff3");

        // An L1 revision without the opcode: the probe fails.
        _etchSlotNumberProbe(hex"fe");
        vm.roll(5);
        vm.prevrandao(bytes32(uint256(5)));
        _sequence(hex"05");
        // One with it: PUSH1 42 PUSH0 MSTORE PUSH1 32 PUSH0 RETURN.
        _etchSlotNumberProbe(hex"602a5f5260205ff3");
        vm.roll(6);
        vm.prevrandao(bytes32(uint256(6)));
        _sequence(hex"06");

        InputQueue.Entry[] memory entries = _entries(CHAIN_ID);
        assertEq(entries.length, 5);
        assertEq(entries[1].payload, abi.encodePacked(bytes32(uint256(5)), uint64(1)));
        assertEq(entries[1].payload.length, BLOCK_RECORD_LENGTH);
        assertEq(entries[3].payload, abi.encodePacked(bytes32(uint256(6)), uint64(2), uint64(42)));
    }

    function test_queuesAreSeparatePerDomain() public {
        _registerDomain(hub, 8888, VALIDATOR_KEY);
        _sequence(hex"01");
        vm.prank(alice);
        hub.sequenceToDomain(8888, hex"02");

        assertEq(_inputs(CHAIN_ID).length, 1);
        assertEq(_inputs(CHAIN_ID)[0].payload, hex"01");
        assertEq(_inputs(8888)[0].payload, hex"02");
    }

    function test_revertedCallRecordsNothing() public {
        (uint64 head, uint64 tail) = hub.inputQueueBounds(CHAIN_ID);
        vm.roll(2);
        vm.prank(alice);
        vm.expectRevert("DomainHub: delivery fee too low");
        hub.sendL1Message(CHAIN_ID, bob, hex"01");
        (uint64 headAfter, uint64 tailAfter) = hub.inputQueueBounds(CHAIN_ID);
        assertEq(headAfter, head);
        assertEq(tailAfter, tail);
        (uint64 l1BlockNumber, uint64 domainBlockNumber) = hub.latestDomainBlock(CHAIN_ID);
        assertEq(l1BlockNumber, 1);
        assertEq(domainBlockNumber, 0);
    }

    function testFuzz_payloadRoundTrips(uint16 length, uint256 seed) public {
        bytes memory payload = _payload(bound(length, 0, 4_000), seed % 1_000);
        _sequence(hex"ff");
        _sequence(payload);
        _sequence(hex"ee");

        InputQueue.Entry[] memory entries = _inputs(CHAIN_ID);
        assertEq(entries.length, 3);
        assertEq(entries[0].payload, hex"ff");
        assertEq(entries[1].payload, payload);
        assertEq(entries[2].payload, hex"ee");
    }

    // ---------------------------------------------------------------------
    // Layout
    // ---------------------------------------------------------------------

    function test_layoutIsPageAlignedAndNeverStoresAZeroWord() public {
        uint256 base = hub.inputQueueBase(CHAIN_ID);
        assertEq(base % 128, 0);

        // An all-zero payload still stores no zero word, and neither does a block record.
        (uint64 start,) = hub.inputQueueBounds(CHAIN_ID);
        assertGt(start, 0);
        _sequence(new bytes(31 * 40));
        (uint64 head,) = hub.inputQueueBounds(CHAIN_ID);
        assertEq(head - start, 41);
        assertEq(head - start, InputQueue.wordsFor(31 * 40));
        for (uint256 i = 0; i < head; i++) {
            assertTrue(vm.load(address(hub), bytes32(base + 128 + i)) != bytes32(0));
        }
        // Meta, the domain's schedule and its per-block gas budget share the queue's first page.
        assertTrue(vm.load(address(hub), bytes32(base)) != bytes32(0));
        assertTrue(vm.load(address(hub), bytes32(base + 1)) != bytes32(0));
        assertTrue(vm.load(address(hub), bytes32(base + 2)) != bytes32(0));
    }

    // ---------------------------------------------------------------------
    // Release
    // ---------------------------------------------------------------------

    function test_attestationReleasesInputsUpToItsHeight() public {
        vm.roll(5);
        _sequence(hex"05");
        vm.roll(10);
        _sequence(hex"10");
        vm.roll(11);
        _sequence(hex"11");
        vm.roll(25);
        _sequence(hex"25");

        // Height 10 covers L1 blocks 5 and 10, not 11.
        _attestAt(10);
        InputQueue.Entry[] memory entries = _inputs(CHAIN_ID);
        assertEq(entries.length, 2);
        assertEq(entries[0].payload, hex"11");
        assertEq(entries[1].payload, hex"25");

        // Skipping the checkpoint at 20 releases through 30.
        _attestAt(30);
        (uint64 head, uint64 tail) = hub.inputQueueBounds(CHAIN_ID);
        assertEq(tail, head);

        // The queue keeps working after it has been emptied.
        vm.roll(35);
        _sequence(hex"35");
        assertEq(_inputs(CHAIN_ID)[0].payload, hex"35");
    }

    function test_attestationWithNothingToReleaseLeavesTheQueue() public {
        vm.roll(15);
        _sequence(hex"15");
        _attestAt(10);
        assertEq(_inputs(CHAIN_ID).length, 1);
    }

    function test_votesBelowQuorumReleaseNothing() public {
        _registerDomain(hub, 8888, _keys(0xB0B, 0xCA11), 2);
        vm.roll(5);
        vm.prank(alice);
        hub.sequenceToDomain(8888, hex"05");
        vm.roll(11);
        hub.submitStateSignature(8888, 10, bytes32(0), bytes32(0), _signTransition(hub, 8888, 10, 0, 0, 0xB0B));
        assertEq(_inputs(8888).length, 1);
        hub.submitStateSignature(8888, 10, bytes32(0), bytes32(0), _signTransition(hub, 8888, 10, 0, 0, 0xCA11));
        assertEq(_inputs(8888).length, 0);
    }

    // ---------------------------------------------------------------------
    // Bounds
    // ---------------------------------------------------------------------

    function test_fullQueueRevertsUntilAnAttestationReleasesIt() public {
        uint256 capacity = hub.INPUT_QUEUE_CAPACITY();
        uint256 chunk = hub.INPUT_QUEUE_CHUNK();
        _lapRing();
        vm.roll(5);
        // The registration's block record and this L1 block's, one header word plus
        // `capacity - 2` chunks less those, then a one-word entry: exactly full.
        uint256 blockRecords = 2 * InputQueue.wordsFor(BLOCK_RECORD_LENGTH);
        bytes memory large = new bytes((capacity - 2 - blockRecords) * chunk);
        large[large.length - 1] = 0x42;
        _sequence(large);
        _sequence("");
        (uint64 head, uint64 tail) = hub.inputQueueBounds(CHAIN_ID);
        assertEq(head - tail, capacity);
        (InputQueue.Entry memory entry,) = hub.inputQueueEntry(CHAIN_ID, uint64(blockRecords));
        assertEq(keccak256(entry.payload), keccak256(large));

        vm.prank(alice);
        vm.expectRevert(InputQueue.InputQueueFull.selector);
        hub.sequenceToDomain(CHAIN_ID, "");
        vm.prank(alice);
        vm.expectRevert(InputQueue.InputQueueFull.selector);
        hub.sendL1Message{value: 1 ether}(CHAIN_ID, bob, hex"01");

        _attestAt(10);
        _sequence(hex"aa");
        assertEq(_inputs(CHAIN_ID).length, 1);
    }

    function test_entriesWrapAroundTheRing() public {
        uint64 capacity = uint64(hub.INPUT_QUEUE_CAPACITY());
        uint256 chunk = hub.INPUT_QUEUE_CHUNK();
        _advanceEmptyQueue(capacity - 19);

        // Starts 19 words before the end of the ring and runs past it.
        bytes memory wrapping = _payload(100 * chunk + 7, 2);
        _sequence(wrapping);
        _sequence(hex"bb");
        InputQueue.Entry[] memory entries = _inputs(CHAIN_ID);
        assertEq(entries.length, 2);
        assertEq(entries[0].payload, wrapping);
        assertEq(entries[1].payload, hex"bb");

        // The entry's tail landed at the start of the ring.
        (uint64 head,) = hub.inputQueueBounds(CHAIN_ID);
        assertEq(head, capacity + 85);
        uint256 base = hub.inputQueueBase(CHAIN_ID);
        assertEq(uint256(vm.load(address(hub), bytes32(base + 128))) >> 248, 1);
        assertEq(vm.load(address(hub), bytes32(base + 128 + 85)), bytes32(0));
    }

    function test_entryLargerThanTheRingReverts() public {
        bytes memory tooLarge = new bytes(hub.INPUT_QUEUE_CAPACITY() * hub.INPUT_QUEUE_CHUNK());
        vm.prank(alice);
        vm.expectRevert(InputQueue.InputQueueFull.selector);
        hub.sequenceToDomain(CHAIN_ID, tooLarge);
    }

    function test_entryIndexMustBeLive() public {
        vm.roll(5);
        _sequence(hex"05");
        (uint64 head,) = hub.inputQueueBounds(CHAIN_ID);
        vm.expectRevert(InputQueue.InputQueueBadIndex.selector);
        hub.inputQueueEntry(CHAIN_ID, head);
        _attestAt(10);
        vm.expectRevert(InputQueue.InputQueueBadIndex.selector);
        hub.inputQueueEntry(CHAIN_ID, 0);
    }

    // ---------------------------------------------------------------------
    // Priming
    // ---------------------------------------------------------------------

    function test_primingFillsOnlyWordsNoInputHasReached() public {
        (uint64 start,) = hub.inputQueueBounds(CHAIN_ID);
        uint256 data = hub.inputQueueBase(CHAIN_ID) + 128 + start;
        _sequence(hex"c0ffee");
        bytes32 header = vm.load(address(hub), bytes32(data));
        bytes32 chunk = vm.load(address(hub), bytes32(data + 1));

        // The range starts inside the recorded entries: their words are left alone.
        hub.primeInputQueue(CHAIN_ID, 0, 300);
        assertEq(vm.load(address(hub), bytes32(data)), header);
        assertEq(vm.load(address(hub), bytes32(data + 1)), chunk);
        data -= start;
        for (uint256 i = start + 2; i < 300; i++) {
            assertEq(vm.load(address(hub), bytes32(data + i)), bytes32(uint256(1)));
        }
        assertEq(vm.load(address(hub), bytes32(data + 300)), bytes32(0));
        assertEq(_inputs(CHAIN_ID).length, 1);

        // Inputs recorded over primed words read back as usual.
        bytes memory payload = _payload(1_000, 3);
        _sequence(payload);
        InputQueue.Entry[] memory entries = _inputs(CHAIN_ID);
        assertEq(entries.length, 2);
        assertEq(entries[0].payload, hex"c0ffee");
        assertEq(entries[1].payload, payload);
    }

    function test_primingIsBoundedByTheRingAndRegistration() public {
        uint256 capacity = hub.INPUT_QUEUE_CAPACITY();
        hub.primeInputQueue(CHAIN_ID, capacity - 10, 10);
        vm.expectRevert(InputQueue.InputQueueBadIndex.selector);
        hub.primeInputQueue(CHAIN_ID, capacity - 10, 11);
        vm.expectRevert("DomainHub: domain not registered");
        hub.primeInputQueue(9999, 0, 10);
    }

    function test_primingALappedRingWritesNothing() public {
        uint64 capacity = uint64(hub.INPUT_QUEUE_CAPACITY());
        _advanceEmptyQueue(capacity + 5);
        vm.record();
        hub.primeInputQueue(CHAIN_ID, 0, capacity);
        (, bytes32[] memory writes) = vm.accesses(address(hub));
        assertEq(writes.length, 0);
    }

    // ---------------------------------------------------------------------
    // Checkpoint index
    // ---------------------------------------------------------------------

    function test_moreOutstandingCheckpointsThanTheIndexHolds() public {
        uint256 checkpoints = InputQueue.CHECKPOINTS;
        // One input in each of `checkpoints + 4` checkpoint periods: the last five share the
        // newest index item.
        uint256 periods = checkpoints + 4;
        for (uint256 i = 1; i <= periods; i++) {
            vm.roll(i * CHECKPOINT_INTERVAL);
            _sequence(abi.encodePacked(uint16(i)));
        }
        assertEq(_inputs(CHAIN_ID).length, periods);

        // Releasing the first two periods works as usual.
        _attestAt(2 * CHECKPOINT_INTERVAL);
        InputQueue.Entry[] memory entries = _inputs(CHAIN_ID);
        assertEq(entries.length, periods - 2);
        assertEq(entries[0].payload, abi.encodePacked(uint16(3)));

        // The shared item is held until its last period is attested.
        _attestAt(uint64((periods - 1) * CHECKPOINT_INTERVAL));
        entries = _inputs(CHAIN_ID);
        assertEq(entries.length, 5);
        assertEq(entries[0].payload, abi.encodePacked(uint16(checkpoints)));

        _attestAt(uint64(periods * CHECKPOINT_INTERVAL));
        assertEq(_inputs(CHAIN_ID).length, 0);

        // The index ring wraps and keeps releasing exactly.
        for (uint256 i = periods + 1; i <= periods + 3; i++) {
            vm.roll(i * CHECKPOINT_INTERVAL);
            _sequence(abi.encodePacked(uint16(i)));
        }
        _attestAt(uint64((periods + 2) * CHECKPOINT_INTERVAL));
        entries = _inputs(CHAIN_ID);
        assertEq(entries.length, 1);
        assertEq(entries[0].payload, abi.encodePacked(uint16(periods + 3)));
    }

    function testFuzz_releaseMatchesAttestedHeight(uint8[12] memory gaps, uint8 attestAfter) public {
        uint64[] memory blocks = new uint64[](gaps.length);
        uint64 height = 1;
        for (uint256 i = 0; i < gaps.length; i++) {
            height += gaps[i] % 25;
            blocks[i] = height;
            vm.roll(height);
            _sequence(abi.encodePacked(uint16(i)));
        }
        uint64 attested = uint64(bound(attestAfter, 1, 40)) * CHECKPOINT_INTERVAL;
        _attestAt(attested);

        uint256 expected;
        for (uint256 i = 0; i < blocks.length; i++) {
            if (blocks[i] > attested) expected++;
        }
        InputQueue.Entry[] memory entries = _inputs(CHAIN_ID);
        assertEq(entries.length, expected);
        for (uint256 i = 0; i < entries.length; i++) {
            assertGt(entries[i].l1BlockNumber, attested);
            assertEq(entries[i].payload, abi.encodePacked(uint16(blocks.length - expected + i)));
        }
    }
}
