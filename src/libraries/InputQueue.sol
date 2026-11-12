// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice A domain's input queue in the hub's storage: the inputs its latest attested
/// checkpoint does not cover yet.
///
/// Each domain owns one region, starting on a MIP-8 page boundary (128 slots per page). Fields
/// are listed from the high bits to the low bits, with sizes in bits:
///
///   base            `keccak256(abi.encode(domainChainId, "monad.domains.input-queue"))`, low 7
///                   bits cleared
///   base + 0        latest block: `gasSold(64) | inputWords(64) | l1BlockNumber(64) | domainBlockNumber(64)`
///   base + 1        queue state: `messageCount(64) | firstPeriod(64) | tail(64) | head(64)`
///   base + 2        config: `zero(24) | maxUnattestedPeriods(8) | checkpointInterval(64) | feeRecipient(160)`
///   base + 3..52    checkpoint table: `zero(128) | period(64) | position(64)`, the item of
///                   period `p` at `base + 3 + p % 50`
///   base + 53..127  unused
///   base + 128..    data ring of `CAPACITY` words, word `i` at `base + 128 + i % CAPACITY`
///
/// `head` and `tail` count the words ever written and released. The ring holds entries back
/// to back. A block entry of two words opens every domain block, and that block's inputs
/// follow it, each a header word followed by its payload in chunks:
///
///   block header    `kind(8) | l1BlockNumber(64) | l1Timestamp(64) | domainBlockNumber(64) |
///                   slotNumber(56)`, then the word `prevrandao(256)`; `slotNumber` is zero
///                   if the L1 block has none
///   input header    `kind(8) | payloadLength(32) | zero(128) | fee(88)`
///   chunk           `0x01(8) | payload(248)`: 31 payload bytes, the last chunk zero-padded
///
/// Payload of each input kind, with sizes in bytes:
///
///   transaction        `rlpTx`
///   message            `sourceChainId(8) | from(20) | to(20) | nonce(8) | data`
///   encrypted message  `sourceChainId(8) | from(20) | nonce(8) | ciphertext`
///
/// No word written to the ring is zero unless `prevrandao` is, so once it has been lapped a
/// write only replaces a nonzero word and pays no state growth.
library InputQueue {
    /// @dev Words of the data ring.
    uint256 internal constant CAPACITY = 1 << 17;
    /// @dev Payload bytes per chunk word.
    uint256 internal constant CHUNK = 31;
    /// @dev Slots of the checkpoint table: the most periods a domain may leave unattested.
    uint256 internal constant MAX_PERIODS = 50;

    /// @dev Entry kinds.
    uint8 internal constant TRANSACTION = 1;
    uint8 internal constant MESSAGE = 2;
    uint8 internal constant ENCRYPTED_MESSAGE = 3;
    uint8 internal constant BLOCK = 4;

    /// @dev Words of the first page.
    uint256 internal constant LATEST = 0;
    uint256 internal constant STATE = 1;
    uint256 internal constant CONFIG = 2;
    uint256 private constant TABLE = 3;
    uint256 private constant DATA = 128;

    uint256 private constant CHUNK_TAG = 1 << 248;

    error InputQueueFull();
    error InputQueueBadIndex();
    error TooManyUnattestedPeriods();

    /// @dev The queue state word.
    struct State {
        uint64 head;
        uint64 tail;
        uint64 firstPeriod;
        uint64 messageCount;
    }

    /// @notice First slot of `domainChainId`'s queue.
    function base(uint64 domainChainId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(domainChainId, "monad.domains.input-queue"))) & ~uint256(0x7f);
    }

    function load(uint256 queue, uint256 word) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := sload(add(queue, word))
        }
    }

    function store(uint256 queue, uint256 word, uint256 value) internal {
        assembly ("memory-safe") {
            sstore(add(queue, word), value)
        }
    }

    function loadState(uint256 queue) internal view returns (State memory state) {
        uint256 word = load(queue, STATE);
        state.head = uint64(word);
        state.tail = uint64(word >> 64);
        state.firstPeriod = uint64(word >> 128);
        state.messageCount = uint64(word >> 192);
    }

    function storeState(uint256 queue, State memory state) internal {
        store(
            queue,
            STATE,
            (uint256(state.messageCount) << 192) | (uint256(state.firstPeriod) << 128) | (uint256(state.tail) << 64)
                | state.head
        );
    }

    /// @dev Header of the block entry that opens `domainBlockNumber` in the current L1 block.
    function blockHeader(uint64 domainBlockNumber, uint56 slotNumber) internal view returns (uint256) {
        return (uint256(BLOCK) << 248) | (uint256(uint64(block.number)) << 184)
            | (uint256(uint64(block.timestamp)) << 120) | (uint256(domainBlockNumber) << 56) | slotNumber;
    }

    /// @dev Header of an input. `fee` must fit in 88 bits.
    function inputHeader(uint8 kind, uint256 fee) internal pure returns (uint256) {
        return (uint256(kind) << 248) | fee;
    }

    /// @dev Records that `period`'s entries start at `head`. Reverts if `period` is
    /// `maxUnattestedPeriods` or more past the oldest unattested one.
    function openPeriod(uint256 queue, State memory state, uint64 period, uint256 maxUnattestedPeriods) internal {
        if (state.head == state.tail) {
            state.firstPeriod = period;
        } else if (period - state.firstPeriod >= maxUnattestedPeriods) {
            revert TooManyUnattestedPeriods();
        }
        store(queue, TABLE + period % MAX_PERIODS, (uint256(period) << 64) | state.head);
    }

    /// @dev Ring words of an input with `length` payload bytes: its header and chunks.
    function inputWords(uint256 length) internal pure returns (uint256) {
        return 1 + (length + CHUNK - 1) / CHUNK;
    }

    /// @dev Appends a block entry: `header`, then `prevrandao`.
    function pushBlock(uint256 queue, State memory state, uint256 header, uint256 prevrandao) internal {
        uint256 head = state.head;
        if (head + 2 - state.tail > CAPACITY) revert InputQueueFull();
        store(queue, DATA + head % CAPACITY, header);
        store(queue, DATA + (head + 1) % CAPACITY, prevrandao);
        state.head = uint64(head + 2);
    }

    /// @dev Appends an entry: `header` with the payload's length, then the payload in chunks.
    function push(uint256 queue, State memory state, uint256 header, bytes memory payload) internal {
        uint256 length = payload.length;
        uint256 chunks = (length + CHUNK - 1) / CHUNK;
        uint256 head = state.head;
        if (head + chunks + 1 - state.tail > CAPACITY) revert InputQueueFull();
        // The check above keeps `length` within its 32 bits.
        header |= length << 216;
        assembly ("memory-safe") {
            let mask := sub(CAPACITY, 1)
            let data := add(queue, DATA)
            sstore(add(data, and(head, mask)), header)
            let ptr := add(payload, 32)
            for { let i := 0 } lt(i, chunks) { i := add(i, 1) } {
                let chunk := or(CHUNK_TAG, shr(8, mload(ptr)))
                if eq(add(i, 1), chunks) {
                    // Zero whatever follows the payload in memory out of the last chunk.
                    let used := add(1, sub(length, mul(i, CHUNK)))
                    chunk := and(chunk, not(shr(mul(8, used), not(0))))
                }
                sstore(add(data, and(add(add(head, 1), i), mask)), chunk)
                ptr := add(ptr, CHUNK)
            }
        }
        state.head = uint64(head + chunks + 1);
    }

    /// @notice Releases every entry of the periods up to `period`. `latestPeriod` is the
    /// period of the latest domain block.
    function release(uint256 queue, uint64 period, uint64 latestPeriod) internal {
        State memory state = loadState(queue);
        if (state.head == state.tail || period < state.firstPeriod) return;
        state.tail = state.head;
        // At most `MAX_PERIODS - 1` steps: the live periods span fewer than `MAX_PERIODS`.
        for (uint64 p = period + 1; p <= latestPeriod; p++) {
            uint256 item = load(queue, TABLE + p % MAX_PERIODS);
            if (item >> 64 == p) {
                state.tail = uint64(item);
                state.firstPeriod = p;
                break;
            }
        }
        storeState(queue, state);
    }

    /// @notice Pays ahead for the state growth of data words `[from, from + count)`: writes a
    /// filler into each one no entry has reached yet, so the first entries to reach them only
    /// replace a nonzero word.
    function prime(uint256 queue, uint256 from, uint256 count) internal {
        if (from + count > CAPACITY) revert InputQueueBadIndex();
        uint256 head = uint64(load(queue, STATE));
        if (from < head) {
            uint256 written = head - from;
            if (written >= count) return;
            from = head;
            count -= written;
        }
        assembly ("memory-safe") {
            let slot := add(add(queue, DATA), from)
            for { let end := add(slot, count) } lt(slot, end) { slot := add(slot, 1) } {
                if iszero(sload(slot)) { sstore(slot, 1) }
            }
        }
    }
}
