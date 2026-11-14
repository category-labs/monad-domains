// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {DomainHub} from "../src/DomainHub.sol";
import {IDomainHub} from "../src/interfaces/IDomain.sol";
import {InputQueue} from "../src/libraries/InputQueue.sol";
import {MessageLib} from "../src/libraries/MessageLib.sol";
import {DomainTestBase} from "./helpers/DomainTestBase.sol";

/// @dev A fee recipient that records one more input while it is being paid.
contract ReenteringRecipient {
    DomainHub internal immutable HUB;
    uint64 internal immutable CHAIN_ID;
    bool internal entered;

    constructor(DomainHub hub, uint64 chainId) {
        HUB = hub;
        CHAIN_ID = chainId;
    }

    receive() external payable {
        if (entered) return;
        entered = true;
        HUB.sequenceToDomain{value: HUB.minSequencingFee(1)}(CHAIN_ID, hex"1e");
        HUB.sendL1Message{value: HUB.minDeliveryFee(1)}(CHAIN_ID, address(this), hex"1e");
    }
}

contract DomainInputQueueTest is DomainTestBase {
    uint64 internal constant CHAIN_ID = 7777;
    /// @dev The domain forwarded encrypted messages come from.
    uint64 internal constant SOURCE_CHAIN_ID = 5555;
    uint256 internal constant VALIDATOR_KEY = 0xA11CE;

    /// @dev Words of a block entry: its header and prevrandao.
    uint64 internal constant BLOCK_WORDS = 2;
    uint256 internal constant TABLE = 3;
    uint256 internal constant DATA = 128;

    DomainHub internal hub;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        hub = new DomainHub();
        vm.prevrandao(keccak256("prevrandao"));
        _registerDomain(hub, CHAIN_ID, VALIDATOR_KEY);
        _registerDomain(hub, SOURCE_CHAIN_ID, VALIDATOR_KEY);
        vm.deal(alice, 1_000_000 ether);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _register(uint64 chainId, uint8 maxUnattestedPeriods) internal {
        hub.registerDomain(
            chainId, _addresses(_keys(VALIDATOR_KEY)), 1, address(this), "", CHECKPOINT_INTERVAL, maxUnattestedPeriods
        );
    }

    function _word(uint64 chainId, uint256 slot) internal view returns (uint256) {
        return _queueWord(hub, chainId, slot);
    }

    function _firstPeriod(uint64 chainId) internal view returns (uint64) {
        return uint64(_word(chainId, 1) >> 128);
    }

    function _period(uint256 l1Block) internal pure returns (uint64) {
        return uint64((l1Block + CHECKPOINT_INTERVAL - 1) / CHECKPOINT_INTERVAL);
    }

    function _entries(uint64 chainId) internal view returns (QueueEntry[] memory entries) {
        (uint64 head, uint64 tail) = _queueBounds(hub, chainId);
        uint256 count;
        for (uint64 i = tail; i < head; count++) {
            (, i) = _queueEntry(hub, chainId, i);
        }
        entries = new QueueEntry[](count);
        uint64 index = tail;
        for (uint256 j = 0; j < count; j++) {
            (entries[j], index) = _queueEntry(hub, chainId, index);
        }
        assertEq(index, head);
    }

    /// @dev The queue's entries without the block entries.
    function _inputs(uint64 chainId) internal view returns (QueueEntry[] memory inputs) {
        QueueEntry[] memory entries = _entries(chainId);
        uint256 count;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].kind != InputQueue.BLOCK) count++;
        }
        inputs = new QueueEntry[](count);
        uint256 j;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].kind != InputQueue.BLOCK) inputs[j++] = entries[i];
        }
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
        uint256 data = _queueBase(CHAIN_ID) + DATA;
        uint256 free;
        assembly {
            free := mload(0x40)
        }
        for (uint256 i = 0; i < InputQueue.CAPACITY; i++) {
            if (vm.load(address(hub), bytes32(data + i)) == 0) {
                vm.store(address(hub), bytes32(data + i), bytes32(uint256(1)));
            }
            // Free the cheatcodes' memory, which Monad limits per transaction.
            assembly {
                mstore(0x40, free)
            }
        }
    }

    /// @dev Empties the queue and puts its head and tail at `words`, as if that many had been
    /// written and released.
    function _advanceEmptyQueue(uint64 words) internal {
        uint256 state = (_word(CHAIN_ID, 1) >> 128 << 128) | (uint256(words) << 64) | words;
        vm.store(address(hub), bytes32(_queueBase(CHAIN_ID) + 1), bytes32(state));
    }

    function _sequence(uint64 chainId, bytes memory rlpTx) internal {
        vm.prank(alice);
        hub.sequenceToDomain{value: _sequencingFee(rlpTx.length)}(chainId, rlpTx);
    }

    function _sequence(bytes memory rlpTx) internal {
        _sequence(CHAIN_ID, rlpTx);
    }

    function _attestAt(uint64 chainId, uint64 l1Block) internal {
        _attest(hub, chainId, l1Block, bytes32(uint256(l1Block)), bytes32(0), _keys(VALIDATOR_KEY));
    }

    function _attestAt(uint64 l1Block) internal {
        _attestAt(CHAIN_ID, l1Block);
    }

    // ---------------------------------------------------------------------
    // Layout
    // ---------------------------------------------------------------------

    function test_firstPageFollowsTheLayout() public {
        vm.roll(25);
        hub.registerDomain(8888, _addresses(_keys(VALIDATOR_KEY)), 1, bob, "", 10, 7);
        // The queue starts on a page boundary.
        assertEq(_queueBase(8888) % 128, 0);

        // config: zero(24) | maxUnattestedPeriods(8) | checkpointInterval(64) | feeRecipient(160)
        assertEq(_word(8888, 2), (uint256(7) << 224) | (uint256(10) << 160) | uint160(bob));
        // latest block: gasSold(64) | inputWords(64) | l1BlockNumber(64) | domainBlockNumber(64)
        assertEq(_word(8888, 0), uint256(25) << 64);
        // queue state: messageCount(64) | firstPeriod(64) | tail(64) | head(64)
        assertEq(_word(8888, 1), (uint256(3) << 128) | BLOCK_WORDS);
        // checkpoint table: period(64) | position(64) at base + 3 + period % 50
        assertEq(_word(8888, TABLE + 3), uint256(3) << 64);

        // A message and a transaction in L1 block 531: period 54, table slot 4.
        vm.roll(531);
        _attestAt(8888, 520);
        uint256 fee = hub.minDeliveryFee(1);
        vm.prank(alice);
        hub.sendL1Message{value: fee}(8888, bob, hex"01");
        vm.prank(alice);
        hub.sequenceToDomain{value: 2 ether}(8888, hex"02");

        uint256 gasSold = (fee + 2 ether) / hub.DOMAIN_GAS_PRICE();
        // The message takes a header and two chunks, the transaction a header and one.
        assertEq(_word(8888, 0), (gasSold << 192) | (uint256(5) << 128) | (uint256(531) << 64) | 1);
        (uint64 head,) = _queueBounds(hub, 8888);
        assertEq(_word(8888, 1), (uint256(1) << 192) | (uint256(54) << 128) | (uint256(BLOCK_WORDS) << 64) | head);
        assertEq(_word(8888, TABLE + 4), (uint256(54) << 64) | BLOCK_WORDS);

        assertEq(hub.l1MessageCounts(8888), 1);
        (uint64 gasBlock, uint192 sold) = hub.blockGas(8888);
        assertEq(gasBlock, 531);
        assertEq(sold, gasSold);
        (uint64 l1BlockNumber, uint64 domainBlockNumber) = hub.latestDomainBlock(8888);
        assertEq(l1BlockNumber, 531);
        assertEq(domainBlockNumber, 1);
    }

    function test_ringWordsFollowTheLayout() public {
        bytes32 randao = bytes32(uint256(0xbeef) | (uint256(0xaa) << 248));
        vm.roll(7);
        vm.warp(2_000);
        vm.prevrandao(randao);
        _register(8888, 3);
        bytes memory rlpTx = _payload(33, 5);
        vm.prank(alice);
        hub.sequenceToDomain{value: 1 ether}(8888, rlpTx);

        // block header: kind(8) | l1BlockNumber(64) | l1Timestamp(64) | domainBlockNumber(64) |
        // slotNumber(56), then prevrandao
        assertEq(_word(8888, DATA), (uint256(4) << 248) | (uint256(7) << 184) | (uint256(2_000) << 120));
        assertEq(_word(8888, DATA + 1), uint256(randao));
        // input header: kind(8) | payloadLength(32) | zero(128) | fee(88), then its chunks of
        // 0x01(8) | payload(248)
        assertEq(_word(8888, DATA + 2), (uint256(1) << 248) | (uint256(33) << 216) | 1 ether);
        assertEq(_word(8888, DATA + 3), (uint256(1) << 248) | (uint256(bytes32(rlpTx)) >> 8));
        assertEq(
            _word(8888, DATA + 4),
            (uint256(1) << 248) | (uint256(uint8(rlpTx[31])) << 240) | (uint256(uint8(rlpTx[32])) << 232)
        );
        assertEq(_word(8888, DATA + 5), 0);

        // The next domain block's header carries its number.
        vm.roll(8);
        vm.warp(2_001);
        _sequence(8888, hex"");
        assertEq(
            _word(8888, DATA + 5),
            (uint256(4) << 248) | (uint256(8) << 184) | (uint256(2_001) << 120) | (uint256(1) << 56)
        );
        assertEq(_word(8888, DATA + 6), uint256(randao));
        // An empty payload is a header alone.
        assertEq(_word(8888, DATA + 7), (uint256(1) << 248) | _sequencingFee(0));
        (uint64 head,) = _queueBounds(hub, 8888);
        assertEq(head, 8);
    }

    function test_noZeroWordIsStored() public {
        _sequence(new bytes(31 * 40));
        (uint64 head,) = _queueBounds(hub, CHAIN_ID);
        assertEq(head, BLOCK_WORDS + 41);
        for (uint256 i = 0; i < head; i++) {
            assertTrue(_word(CHAIN_ID, DATA + i) != 0);
        }
    }

    // ---------------------------------------------------------------------
    // Recording
    // ---------------------------------------------------------------------

    function test_recordsTransactionsAndMessagesInL1Order() public {
        uint256 fee = hub.minDeliveryFee(3);
        vm.prank(alice);
        hub.sequenceToDomain{value: 1 ether}(CHAIN_ID, hex"c0ffee");
        vm.roll(2);
        vm.prank(alice);
        hub.sendL1Message{value: fee}(CHAIN_ID, bob, hex"010203");
        (MessageLib.DomainMessage memory forwarded, bytes32 anchor) =
            _attestedSealedMessage(hub, SOURCE_CHAIN_ID, CHAIN_ID, 9, hex"aabbcc");
        vm.prank(alice);
        hub.relayDomainMessage{value: fee}(forwarded, anchor, new bytes32[](0));

        QueueEntry[] memory entries = _inputs(CHAIN_ID);
        assertEq(entries.length, 3);
        assertEq(entries[0].kind, InputQueue.TRANSACTION);
        assertEq(entries[0].fee, 1 ether);
        assertEq(entries[0].payload, hex"c0ffee");
        assertEq(entries[1].kind, InputQueue.MESSAGE);
        assertEq(entries[1].fee, fee);
        assertEq(entries[1].payload, abi.encodePacked(uint64(block.chainid), alice, bob, uint64(0), hex"010203"));
        assertEq(entries[2].kind, InputQueue.ENCRYPTED_MESSAGE);
        assertEq(entries[2].fee, fee);
        assertEq(entries[2].payload, abi.encodePacked(SOURCE_CHAIN_ID, uint64(9), uint64(1), hex"aabbcc"));
    }

    function test_firstInputOfAnL1BlockOpensTheNextDomainBlock() public {
        // Inputs of the registering L1 block belong to block 0.
        _sequence(hex"01");
        uint256 fee = hub.minDeliveryFee(1);
        vm.roll(5);
        vm.warp(500);
        vm.prevrandao(bytes32(uint256(5)));
        _sequence(hex"05");
        vm.prank(alice);
        hub.sendL1Message{value: fee}(CHAIN_ID, bob, hex"01");
        // L1 blocks without inputs open nothing.
        vm.roll(9);
        _sequence(hex"09");

        QueueEntry[] memory entries = _entries(CHAIN_ID);
        assertEq(entries.length, 7);
        assertEq(entries[0].kind, InputQueue.BLOCK);
        assertEq(entries[0].l1BlockNumber, 1);
        assertEq(entries[0].domainBlockNumber, 0);
        assertEq(entries[1].payload, hex"01");
        assertEq(entries[2].kind, InputQueue.BLOCK);
        assertEq(entries[2].l1BlockNumber, 5);
        assertEq(entries[2].l1Timestamp, 500);
        assertEq(entries[2].domainBlockNumber, 1);
        assertEq(entries[2].prevrandao, bytes32(uint256(5)));
        assertEq(entries[3].payload, hex"05");
        assertEq(entries[4].kind, InputQueue.MESSAGE);
        assertEq(entries[5].kind, InputQueue.BLOCK);
        assertEq(entries[5].l1BlockNumber, 9);
        assertEq(entries[5].domainBlockNumber, 2);
        assertEq(entries[6].payload, hex"09");
    }

    function test_blockEntryCarriesTheSlotNumberWhenTheL1HasOne() public {
        // SLOTNUM PUSH0 MSTORE PUSH1 32 PUSH0 RETURN
        assertEq(hub.SLOT_NUMBER_PROBE().code, hex"4b5f5260205ff3");

        // An L1 revision without the opcode: the probe fails.
        vm.etch(hub.SLOT_NUMBER_PROBE(), hex"fe");
        vm.roll(5);
        _sequence(hex"05");
        // One with it: PUSH1 42 PUSH0 MSTORE PUSH1 32 PUSH0 RETURN.
        vm.etch(hub.SLOT_NUMBER_PROBE(), hex"602a5f5260205ff3");
        vm.roll(6);
        vm.prevrandao(bytes32(uint256(6)));
        _sequence(hex"06");

        QueueEntry[] memory entries = _entries(CHAIN_ID);
        assertEq(entries.length, 5);
        assertEq(entries[1].slotNumber, 0);
        assertEq(entries[3].slotNumber, 42);
        assertEq(entries[3].prevrandao, bytes32(uint256(6)));
    }

    function test_queuesAreSeparatePerDomain() public {
        _register(8888, 3);
        _sequence(hex"01");
        _sequence(8888, hex"02");
        assertEq(_inputs(CHAIN_ID).length, 1);
        assertEq(_inputs(CHAIN_ID)[0].payload, hex"01");
        assertEq(_inputs(8888)[0].payload, hex"02");
    }

    function test_revertedCallRecordsNothing() public {
        bytes32 latest = bytes32(_word(CHAIN_ID, 0));
        bytes32 state = bytes32(_word(CHAIN_ID, 1));
        vm.roll(2);
        vm.prank(alice);
        vm.expectRevert(DomainHub.DeliveryFeeTooLow.selector);
        hub.sendL1Message(CHAIN_ID, bob, hex"01");
        vm.prank(alice);
        vm.expectRevert(DomainHub.DomainBlockGasLimitExceeded.selector);
        hub.sequenceToDomain{value: 150_000_001 * 50 gwei}(CHAIN_ID, hex"01");
        assertEq(bytes32(_word(CHAIN_ID, 0)), latest);
        assertEq(bytes32(_word(CHAIN_ID, 1)), state);
    }

    function testFuzz_payloadRoundTrips(uint16 length, uint256 seed, uint64 start) public {
        // From anywhere in the ring, across its end included.
        _advanceEmptyQueue(uint64(bound(start, 0, 1 << 40)));
        vm.roll(2);
        bytes memory payload = _payload(bound(length, 0, 4_000), seed % 1_000);
        _sequence(hex"ff");
        _sequence(payload);
        _sequence(hex"ee");

        QueueEntry[] memory entries = _inputs(CHAIN_ID);
        assertEq(entries.length, 3);
        assertEq(entries[0].payload, hex"ff");
        assertEq(entries[1].payload, payload);
        assertEq(entries[2].payload, hex"ee");
    }

    /// @dev The fee is paid out last, so an input recorded from inside the payment comes
    /// after the paying one in the queue and in the logs alike.
    function test_feeRecipientReenteringKeepsQueueAndLogsInOrder() public {
        ReenteringRecipient recipient = new ReenteringRecipient(hub, 8888);
        hub.registerDomain(8888, _addresses(_keys(VALIDATOR_KEY)), 1, address(recipient), "", CHECKPOINT_INTERVAL, 3);
        uint256 fee = hub.minDeliveryFee(1);
        vm.recordLogs();
        vm.prank(alice);
        hub.sendL1Message{value: 2 * fee}(8888, bob, hex"00");

        QueueEntry[] memory entries = _inputs(8888);
        assertEq(entries.length, 3);
        assertEq(entries[0].payload, abi.encodePacked(uint64(block.chainid), alice, bob, uint64(0), hex"00"));
        assertEq(entries[1].payload, hex"1e");
        assertEq(
            entries[2].payload,
            abi.encodePacked(uint64(block.chainid), address(recipient), address(recipient), uint64(1), hex"1e")
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3);
        assertEq(logs[0].topics[0], IDomainHub.L1MessageRecorded.selector);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(alice))));
        assertEq(logs[1].topics[0], IDomainHub.DomainTransactionSequenced.selector);
        assertEq(logs[2].topics[0], IDomainHub.L1MessageRecorded.selector);
        assertEq(logs[2].topics[2], bytes32(uint256(uint160(address(recipient)))));
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
        assertEq(_firstPeriod(CHAIN_ID), 1);

        // Height 10 covers L1 blocks 5 and 10, not 11: the tail lands on block 11's header.
        _attestAt(10);
        QueueEntry[] memory entries = _entries(CHAIN_ID);
        assertEq(entries.length, 4);
        assertEq(entries[0].kind, InputQueue.BLOCK);
        assertEq(entries[0].l1BlockNumber, 11);
        assertEq(entries[1].payload, hex"11");
        assertEq(entries[3].payload, hex"25");
        assertEq(_firstPeriod(CHAIN_ID), 2);

        // Skipping the checkpoint at 20 releases through 30.
        _attestAt(30);
        (uint64 head, uint64 tail) = _queueBounds(hub, CHAIN_ID);
        assertEq(tail, head);

        // The queue keeps working after it has been emptied.
        vm.roll(35);
        _sequence(hex"35");
        assertEq(_inputs(CHAIN_ID)[0].payload, hex"35");
        assertEq(_firstPeriod(CHAIN_ID), 4);
    }

    function test_firstCheckpointCoversTheRegisteringBlock() public {
        vm.roll(25);
        _register(8888, 3);
        assertEq(hub.domainBlockNumbers(8888), 20);

        // A height below the registering block is stale.
        bytes memory signature = _signTransition(hub, 8888, 20, bytes32(0), bytes32(0), VALIDATOR_KEY);
        vm.expectRevert(DomainHub.StaleBlockNumber.selector);
        hub.submitStateSignature(8888, 20, bytes32(0), bytes32(0), signature);

        // The next scheduled height releases block 0's entry.
        vm.roll(31);
        _attestAt(8888, 30);
        (uint64 head, uint64 tail) = _queueBounds(hub, 8888);
        assertEq(tail, head);

        // A registering block on the schedule is its own first checkpoint.
        vm.roll(40);
        _register(9999, 3);
        assertEq(hub.domainBlockNumbers(9999), 30);
    }

    function test_releaseSkipsPeriodsWithoutInputs() public {
        vm.roll(5);
        _sequence(hex"05");
        vm.roll(45);
        _sequence(hex"45");

        // Periods 2 to 4 hold nothing: the tail moves to period 5.
        _attestAt(20);
        QueueEntry[] memory entries = _entries(CHAIN_ID);
        assertEq(entries.length, 2);
        assertEq(entries[0].l1BlockNumber, 45);
        assertEq(_firstPeriod(CHAIN_ID), 5);

        // Checkpoints below the oldest live period release nothing.
        _attestAt(40);
        assertEq(_entries(CHAIN_ID).length, 2);
        assertEq(_firstPeriod(CHAIN_ID), 5);
    }

    function test_votesBelowQuorumReleaseNothing() public {
        _registerDomain(hub, 8888, _keys(0xB0B, 0xCA11), 2);
        vm.roll(5);
        _sequence(8888, hex"05");
        vm.roll(11);
        hub.submitStateSignature(8888, 10, bytes32(0), bytes32(0), _signTransition(hub, 8888, 10, 0, 0, 0xB0B));
        assertEq(_inputs(8888).length, 1);
        hub.submitStateSignature(8888, 10, bytes32(0), bytes32(0), _signTransition(hub, 8888, 10, 0, 0, 0xCA11));
        assertEq(_entries(8888).length, 0);
    }

    // ---------------------------------------------------------------------
    // Backpressure: unattested periods
    // ---------------------------------------------------------------------

    function test_inputsStopOnceTooManyPeriodsAreUnattested() public {
        vm.roll(25);
        _register(8888, 3);
        _sequence(8888, hex"03");
        vm.roll(31);
        _sequence(8888, hex"04");
        vm.roll(50);
        _sequence(8888, hex"05");

        // Period 3 is the oldest unattested one: period 6 is three past it.
        uint256 fee = hub.minDeliveryFee(1);
        vm.roll(51);
        (MessageLib.DomainMessage memory forwarded, bytes32 anchor) =
            _attestedSealedMessage(hub, SOURCE_CHAIN_ID, 8888, 0, hex"06");
        vm.startPrank(alice);
        vm.expectRevert(InputQueue.TooManyUnattestedPeriods.selector);
        hub.sequenceToDomain{value: _sequencingFee(1)}(8888, hex"06");
        vm.expectRevert(InputQueue.TooManyUnattestedPeriods.selector);
        hub.sendL1Message{value: fee}(8888, bob, hex"06");
        vm.expectRevert(InputQueue.TooManyUnattestedPeriods.selector);
        hub.relayDomainMessage{value: fee}(forwarded, anchor, new bytes32[](0));
        vm.stopPrank();
        assertEq(_inputs(8888).length, 3);

        // Attesting period 3 lets period 6 in, and no further.
        _attestAt(8888, 30);
        _sequence(8888, hex"06");
        vm.roll(61);
        vm.expectRevert(InputQueue.TooManyUnattestedPeriods.selector);
        _sequence(8888, hex"07");
        assertEq(_inputs(8888).length, 3);
    }

    function test_emptyQueueNeverStops() public {
        _register(8888, 1);
        _attestAt(8888, 10);
        vm.roll(100_000);
        _sequence(8888, hex"01");
        // With a limit of one period, the next period waits for this one's attestation.
        vm.roll(100_001);
        vm.expectRevert(InputQueue.TooManyUnattestedPeriods.selector);
        _sequence(8888, hex"02");
        _attestAt(8888, 100_000);
        _sequence(8888, hex"02");
        assertEq(_inputs(8888).length, 1);
    }

    function test_tableSlotsAreReusedAcrossPeriods() public {
        // 120 periods through a 50-slot table, each attested two periods late.
        for (uint64 period = 2; period <= 120; period++) {
            vm.roll(period * CHECKPOINT_INTERVAL);
            _sequence(abi.encodePacked(period));
            if (period > 3) _attestAt((period - 2) * CHECKPOINT_INTERVAL);
            QueueEntry[] memory inputs = _inputs(CHAIN_ID);
            assertEq(inputs.length, period > 2 ? 2 : 1);
            assertEq(inputs[inputs.length - 1].payload, abi.encodePacked(period));
        }
        assertEq(_firstPeriod(CHAIN_ID), 119);
    }

    // ---------------------------------------------------------------------
    // Backpressure: ring capacity
    // ---------------------------------------------------------------------

    function test_fullQueueRevertsUntilAnAttestationReleasesIt() public {
        uint256 capacity = InputQueue.CAPACITY;
        uint256 limit = hub.DOMAIN_BLOCK_WORD_LIMIT();
        _lapRing();
        // Nine L1 blocks with an input at the block size limit, then one input that takes
        // what is left: exactly full.
        bytes memory large = new bytes((limit - 1) * InputQueue.CHUNK);
        for (uint256 l1Block = 5; l1Block < 14; l1Block++) {
            vm.roll(l1Block);
            _sequence(large);
        }
        (uint64 head, uint64 tail) = _queueBounds(hub, CHAIN_ID);
        bytes memory rest = new bytes((capacity - (head - tail) - BLOCK_WORDS - 1) * InputQueue.CHUNK);
        rest[rest.length - 1] = 0x42;
        vm.roll(14);
        _sequence(rest);
        (head, tail) = _queueBounds(hub, CHAIN_ID);
        assertEq(head - tail, capacity);
        // The last entry's last chunk is the ring's last word.
        assertEq(_word(CHAIN_ID, DATA + capacity - 1), (uint256(1) << 248) | 0x42);

        vm.prank(alice);
        vm.expectRevert(InputQueue.InputQueueFull.selector);
        hub.sequenceToDomain{value: _sequencingFee(0)}(CHAIN_ID, "");
        vm.prank(alice);
        vm.expectRevert(InputQueue.InputQueueFull.selector);
        hub.sendL1Message{value: 1 ether}(CHAIN_ID, bob, hex"01");
        // A new L1 block's block entry does not fit either.
        vm.roll(15);
        vm.prank(alice);
        vm.expectRevert(InputQueue.InputQueueFull.selector);
        hub.sequenceToDomain{value: _sequencingFee(0)}(CHAIN_ID, "");

        _attestAt(20);
        _sequence(hex"aa");
        assertEq(_inputs(CHAIN_ID).length, 1);
    }

    function test_entriesWrapAroundTheRing() public {
        uint64 capacity = uint64(InputQueue.CAPACITY);
        _advanceEmptyQueue(capacity - 19);
        vm.roll(2);

        // The block entry and then an entry that runs past the end of the ring.
        bytes memory wrapping = _payload(100 * InputQueue.CHUNK + 7, 2);
        _sequence(wrapping);
        _sequence(hex"bb");
        QueueEntry[] memory entries = _entries(CHAIN_ID);
        assertEq(entries.length, 3);
        assertEq(entries[0].kind, InputQueue.BLOCK);
        assertEq(entries[1].payload, wrapping);
        assertEq(entries[2].payload, hex"bb");

        // The entries after the wrap landed at the start of the ring.
        (uint64 head,) = _queueBounds(hub, CHAIN_ID);
        assertEq(head, capacity + 87);
        assertEq(_word(CHAIN_ID, DATA + 85) >> 248, 1);
        assertEq(_word(CHAIN_ID, DATA + 87), 0);

        // Released across the wrap.
        _attestAt(10);
        (, uint64 tail) = _queueBounds(hub, CHAIN_ID);
        assertEq(tail, head);
    }

    // ---------------------------------------------------------------------
    // Block size limit
    // ---------------------------------------------------------------------

    function test_inputsOfAnL1BlockAreLimitedInSize() public {
        uint256 limit = hub.DOMAIN_BLOCK_WORD_LIMIT();
        assertEq(limit, InputQueue.CAPACITY / 10);
        uint256 fee = hub.minDeliveryFee(1);

        // An input one word short of the limit, then a one-word input: the block is full.
        vm.roll(5);
        _sequence(new bytes((limit - 2) * InputQueue.CHUNK));
        _sequence("");
        assertEq(uint64(_word(CHAIN_ID, 0) >> 128), limit);
        (MessageLib.DomainMessage memory forwarded, bytes32 anchor) =
            _attestedSealedMessage(hub, SOURCE_CHAIN_ID, CHAIN_ID, 0, hex"01");
        vm.startPrank(alice);
        vm.expectRevert(DomainHub.DomainBlockSizeLimitExceeded.selector);
        hub.sequenceToDomain{value: _sequencingFee(0)}(CHAIN_ID, "");
        vm.expectRevert(DomainHub.DomainBlockSizeLimitExceeded.selector);
        hub.sendL1Message{value: fee}(CHAIN_ID, bob, hex"01");
        vm.expectRevert(DomainHub.DomainBlockSizeLimitExceeded.selector);
        hub.relayDomainMessage{value: fee}(forwarded, anchor, new bytes32[](0));
        vm.stopPrank();

        // The next L1 block starts over.
        vm.roll(6);
        _sequence("");
        assertEq(uint64(_word(CHAIN_ID, 0) >> 128), 1);

        // An input over the limit fits in no block.
        vm.roll(7);
        bytes memory tooLarge = new bytes(limit * InputQueue.CHUNK);
        vm.prank(alice);
        vm.expectRevert(DomainHub.DomainBlockSizeLimitExceeded.selector);
        hub.sequenceToDomain{value: _sequencingFee(tooLarge.length)}(CHAIN_ID, tooLarge);
    }

    // ---------------------------------------------------------------------
    // Priming
    // ---------------------------------------------------------------------

    function test_primingFillsOnlyWordsNoInputHasReached() public {
        _sequence(hex"c0ffee");
        uint256 header = _word(CHAIN_ID, DATA + BLOCK_WORDS);
        uint256 chunk = _word(CHAIN_ID, DATA + BLOCK_WORDS + 1);

        // The range starts inside the recorded entries: their words are left alone.
        hub.primeInputQueue(CHAIN_ID, 0, 300);
        assertEq(_word(CHAIN_ID, DATA + BLOCK_WORDS), header);
        assertEq(_word(CHAIN_ID, DATA + BLOCK_WORDS + 1), chunk);
        for (uint256 i = BLOCK_WORDS + 2; i < 300; i++) {
            assertEq(_word(CHAIN_ID, DATA + i), 1);
        }
        assertEq(_word(CHAIN_ID, DATA + 300), 0);

        // Inputs recorded over primed words read back as usual.
        bytes memory payload = _payload(1_000, 3);
        _sequence(payload);
        QueueEntry[] memory entries = _inputs(CHAIN_ID);
        assertEq(entries.length, 2);
        assertEq(entries[0].payload, hex"c0ffee");
        assertEq(entries[1].payload, payload);
    }

    function test_primingIsBoundedByTheRingAndRegistration() public {
        uint256 capacity = InputQueue.CAPACITY;
        hub.primeInputQueue(CHAIN_ID, capacity - 10, 10);
        vm.expectRevert(InputQueue.InputQueueBadIndex.selector);
        hub.primeInputQueue(CHAIN_ID, capacity - 10, 11);
        vm.expectRevert();
        hub.primeInputQueue(CHAIN_ID, 1, type(uint256).max);
        vm.expectRevert(DomainHub.DomainNotRegistered.selector);
        hub.primeInputQueue(9999, 0, 10);
    }

    function test_primingALappedRingWritesNothing() public {
        uint64 capacity = uint64(InputQueue.CAPACITY);
        _advanceEmptyQueue(capacity + 5);
        vm.record();
        hub.primeInputQueue(CHAIN_ID, 0, capacity);
        (, bytes32[] memory writes) = vm.accesses(address(hub));
        assertEq(writes.length, 0);
    }

    // ---------------------------------------------------------------------
    // Model
    // ---------------------------------------------------------------------

    uint64 internal constant MODEL_CHAIN_ID = 9999;
    uint64 internal modelInterval;
    /// @dev L1 block of every domain block of the model domain, and of every input recorded.
    uint64[] internal modelBlocks;
    uint64[] internal modelInputBlocks;
    bytes32[] internal modelInputHashes;
    /// @dev Source nonce of the next forwarded encrypted message.
    uint64 internal modelSourceNonce;
    /// @dev The first block and input the latest attestation does not cover.
    uint256 internal modelFirstBlock;
    uint256 internal modelFirstInput;

    function _modelPeriod(uint256 l1Block) internal view returns (uint64) {
        return uint64((l1Block + modelInterval - 1) / modelInterval);
    }

    /// @dev Moves the model domain's queue, which holds its registration's block entry alone,
    /// to word `start`, as if that many words had been written and released before.
    function _relocateModelQueue(uint64 start) internal {
        uint256 base = _queueBase(MODEL_CHAIN_ID);
        bytes32[] memory words = new bytes32[](BLOCK_WORDS);
        for (uint256 i = 0; i < BLOCK_WORDS; i++) {
            words[i] = vm.load(address(hub), bytes32(base + DATA + i));
            vm.store(address(hub), bytes32(base + DATA + i), bytes32(0));
        }
        for (uint256 i = 0; i < BLOCK_WORDS; i++) {
            vm.store(address(hub), bytes32(base + DATA + (start + i) % InputQueue.CAPACITY), words[i]);
        }
        uint256 period = _firstPeriod(MODEL_CHAIN_ID);
        uint256 state = (period << 128) | (uint256(start) << 64) | (start + BLOCK_WORDS);
        vm.store(address(hub), bytes32(base + 1), bytes32(state));
        vm.store(address(hub), bytes32(base + TABLE + period % 50), bytes32((period << 64) | start));
    }

    /// @dev Random inputs, L1 blocks and attestations against a model of what the queue
    /// must hold: exactly the blocks and inputs after the attested height, in order. Two runs
    /// in three start just short of the ring's end, on one of its first laps.
    function testFuzz_queueMatchesModel(uint256 seed, uint8 limit, uint8 interval) public {
        uint8 maxUnattestedPeriods = uint8(bound(limit, 1, 50));
        modelInterval = [1, 2, 3, 7, 10, 40][interval % 6];
        vm.roll(1 + seed % 40);
        hub.registerDomain(
            MODEL_CHAIN_ID, _addresses(_keys(VALIDATOR_KEY)), 1, address(this), "", modelInterval, maxUnattestedPeriods
        );
        modelBlocks.push(uint64(block.number));
        if (seed % 3 != 0) {
            _relocateModelQueue(uint64((seed % 3) * InputQueue.CAPACITY - 1 - (seed >> 16) % 60));
        }
        // The schedule starts at the last height below the registering block.
        uint64 attested = uint64(block.number - 1) / modelInterval * modelInterval;
        assertEq(hub.domainBlockNumbers(MODEL_CHAIN_ID), attested);

        for (uint256 step = 0; step < 80; step++) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint256 action = seed % 8;
            uint256 amount = (seed >> 8) % 23;
            if (action < 2) {
                vm.roll(block.number + 1 + amount * modelInterval / 8);
            } else if (action < 6) {
                _modelInput(action - 2, abi.encodePacked(seed, new bytes(amount * 5)), maxUnattestedPeriods);
            } else {
                uint64 first = attested / modelInterval + 1;
                uint64 last = uint64(block.number - 1) / modelInterval;
                if (last < first) continue;
                attested = (first + uint64(amount) % (last - first + 1)) * modelInterval;
                _attestAt(MODEL_CHAIN_ID, attested);
                while (modelFirstBlock < modelBlocks.length && modelBlocks[modelFirstBlock] <= attested) {
                    modelFirstBlock++;
                }
                while (modelFirstInput < modelInputBlocks.length && modelInputBlocks[modelFirstInput] <= attested) {
                    modelFirstInput++;
                }
            }
            _assertQueueMatchesModel();
        }
    }

    /// @dev Records a transaction (`kind` 0 or 1), a message (2) or a forwarded encrypted
    /// message (3).
    function _modelInput(uint256 kind, bytes memory data, uint8 maxUnattestedPeriods) internal {
        uint64 latest = modelBlocks[modelBlocks.length - 1];
        // A new period is refused once it is `maxUnattestedPeriods` past the oldest live one.
        bool stalled = modelFirstBlock < modelBlocks.length
            && _modelPeriod(block.number) - _modelPeriod(modelBlocks[modelFirstBlock]) >= maxUnattestedPeriods;
        uint64 nonce = uint64(hub.l1MessageCounts(MODEL_CHAIN_ID));
        uint256 fee = kind < 2 ? _sequencingFee(data.length) : hub.minDeliveryFee(data.length);
        bytes memory payload = data;
        if (kind == 2) payload = abi.encodePacked(uint64(block.chainid), alice, bob, nonce, data);
        MessageLib.DomainMessage memory forwarded;
        bytes32 anchor;
        if (kind == 3) {
            uint64 sourceNonce = modelSourceNonce++;
            payload = abi.encodePacked(SOURCE_CHAIN_ID, sourceNonce, nonce, data);
            (forwarded, anchor) = _attestedSealedMessage(hub, SOURCE_CHAIN_ID, MODEL_CHAIN_ID, sourceNonce, data);
        }
        if (stalled) vm.expectRevert(InputQueue.TooManyUnattestedPeriods.selector);
        vm.prank(alice);
        if (kind == 2) {
            hub.sendL1Message{value: fee}(MODEL_CHAIN_ID, bob, data);
        } else if (kind == 3) {
            hub.relayDomainMessage{value: fee}(forwarded, anchor, new bytes32[](0));
        } else {
            hub.sequenceToDomain{value: fee}(MODEL_CHAIN_ID, data);
        }
        if (stalled) return;
        if (latest != block.number) modelBlocks.push(uint64(block.number));
        modelInputBlocks.push(uint64(block.number));
        modelInputHashes.push(keccak256(payload));
    }

    function _assertQueueMatchesModel() internal view {
        (uint64 head, uint64 index) = _queueBounds(hub, MODEL_CHAIN_ID);
        uint256 input = modelFirstInput;
        uint64 previousPeriod;
        QueueEntry memory entry;
        for (uint256 number = modelFirstBlock; number < modelBlocks.length; number++) {
            uint64 l1Block = modelBlocks[number];
            // The first block of each period is where the table says the period starts.
            if (_modelPeriod(l1Block) != previousPeriod) {
                previousPeriod = _modelPeriod(l1Block);
                assertEq(_word(MODEL_CHAIN_ID, TABLE + previousPeriod % 50), (uint256(previousPeriod) << 64) | index);
            }
            (entry, index) = _queueEntry(hub, MODEL_CHAIN_ID, index);
            assertEq(entry.kind, InputQueue.BLOCK);
            assertEq(entry.l1BlockNumber, l1Block);
            assertEq(entry.domainBlockNumber, number);
            for (; input < modelInputBlocks.length && modelInputBlocks[input] == l1Block; input++) {
                (entry, index) = _queueEntry(hub, MODEL_CHAIN_ID, index);
                assertTrue(entry.kind != InputQueue.BLOCK);
                assertEq(keccak256(entry.payload), modelInputHashes[input]);
            }
        }
        assertEq(index, head);
        assertEq(input, modelInputBlocks.length);
        if (modelFirstBlock < modelBlocks.length) {
            assertEq(_firstPeriod(MODEL_CHAIN_ID), _modelPeriod(modelBlocks[modelFirstBlock]));
        }
        (uint64 latestL1Block, uint64 latestBlock) = hub.latestDomainBlock(MODEL_CHAIN_ID);
        assertEq(latestL1Block, modelBlocks[modelBlocks.length - 1]);
        assertEq(latestBlock, modelBlocks.length - 1);
    }
}
