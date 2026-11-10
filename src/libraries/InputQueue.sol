// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Bounded circular buffer of a domain's inputs (sequenced transactions and L1 ->
/// domain messages) kept in L1 state, so the inputs a checkpoint has not yet covered can be
/// read from the state alone and replayed on top of the last attested domain state.
///
/// The layout is built for MIP-8 page storage (128 slots per page, `page = slot >> 7`), where a
/// transaction pays to load and to first write each page once and then 100 gas per slot, and
/// where only a zero -> nonzero write pays for state growth:
///
///   base            `keccak256(domainChainId, NAMESPACE)` with the low 7 bits cleared, so
///                   every region below starts on a page boundary
///   base + 0        meta: `checkpointTail(32) | checkpointHead(32) | lastEpoch(64) | tail(64) | head(64)`
///   base + 1..3     the caller's words: state the caller touches whenever it pushes, kept
///                   here so that a push loads and writes no page beyond the queue's own
///   base + 4..127   checkpoint index, a ring of `epoch(64) | startWord(64)`
///   base + 128..    data ring of `CAPACITY` words
///
/// `head` and `tail` count words ever written and released; word `i` lives at data slot
/// `i % CAPACITY`. An entry is a header word followed by its payload in 31-byte chunks:
///
///   header   `kind(8) | payloadLength(32) | l1BlockNumber(64) | l1Timestamp(64) | fee(88)`
///   chunk    `0x01 | 31 payload bytes` (the last chunk zero-padded)
///
/// The kind and the chunk tag keep every written word nonzero: once the ring has been lapped
/// a write only ever replaces a nonzero word, so it never pays for state growth, and nothing
/// in a payload can clear a slot for the next writer to regrow.
///
/// Entries are released by checkpoint epoch. The index holds one item per epoch that still
/// has entries in the ring, with the word its entries start at; releasing through an epoch
/// moves `tail` to the start of the first later epoch. When the index is full the newest item
/// absorbs further epochs: its entries are then held until the last absorbed epoch is released.
library InputQueue {
    /// @dev Words of the data ring: 512 pages, 2 MiB.
    uint256 internal constant CAPACITY = 1 << 16;
    /// @dev Items of the checkpoint index: the rest of the meta page.
    uint256 internal constant CHECKPOINTS = 124;
    /// @dev Payload bytes per data word.
    uint256 internal constant CHUNK = 31;

    uint256 private constant PAGE_MASK = 0x7f;
    uint256 private constant INDEX_OFFSET = 4;
    uint256 private constant DATA_OFFSET = 128;
    uint256 private constant U32 = 0xffffffff;
    uint256 private constant U64 = 0xffffffffffffffff;
    uint256 private constant U88 = 0xffffffffffffffffffffff;
    uint256 private constant CHUNK_TAG = 1 << 248;

    error InputQueueFull();
    error InputQueueBadIndex();

    struct Entry {
        uint8 kind;
        uint64 l1BlockNumber;
        uint64 l1Timestamp;
        uint256 fee;
        bytes payload;
    }

    /// @notice First slot of `domainChainId`'s queue: its meta word.
    function base(uint64 domainChainId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(domainChainId, "monad.domains.input-queue"))) & ~PAGE_MASK;
    }

    /// @notice Reads caller word `word` (1 to 3).
    function loadWord(uint256 queue, uint256 word) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := sload(add(queue, word))
        }
    }

    /// @notice Writes caller word `word` (1 to 3).
    function storeWord(uint256 queue, uint256 word, uint256 value) internal {
        assembly ("memory-safe") {
            sstore(add(queue, word), value)
        }
    }

    /// @notice Words ever written and words released; the entries in `[tail, head)` are live.
    function bounds(uint256 queue) internal view returns (uint64 head, uint64 tail) {
        uint256 meta;
        assembly ("memory-safe") {
            meta := sload(queue)
        }
        head = uint64(meta);
        tail = uint64(meta >> 64);
    }

    /// @notice Words an entry with `payloadLength` bytes occupies.
    function wordsFor(uint256 payloadLength) internal pure returns (uint256) {
        return 1 + (payloadLength + CHUNK - 1) / CHUNK;
    }

    /// @notice Appends an entry stamped with the current L1 block, filed under checkpoint
    /// `epoch` (which must not decrease between calls). `kind` must be nonzero and `fee` fit 88
    /// bits. Reverts with `InputQueueFull` if the live entries would exceed `CAPACITY`.
    function push(uint256 queue, uint8 kind, uint256 fee, bytes memory payload, uint64 epoch) internal {
        uint256 length = payload.length;
        uint256 chunks = (length + CHUNK - 1) / CHUNK;
        uint256 meta;
        assembly ("memory-safe") {
            meta := sload(queue)
        }
        uint256 head = meta & U64;
        uint256 tail = (meta >> 64) & U64;
        if (head + chunks + 1 - tail > CAPACITY) revert InputQueueFull();

        uint256 header =
            (uint256(kind) << 248) | (length << 216) | (block.number << 152) | (block.timestamp << 88) | (fee & U88);
        assembly ("memory-safe") {
            let mask := sub(CAPACITY, 1)
            let data := add(queue, DATA_OFFSET)
            sstore(add(data, and(head, mask)), header)
            let word := add(head, 1)
            let ptr := add(payload, 32)
            for { let i := 0 } lt(i, chunks) { i := add(i, 1) } {
                let chunk := or(CHUNK_TAG, shr(8, mload(ptr)))
                if eq(add(i, 1), chunks) {
                    // Zero whatever follows the payload in memory out of the last chunk.
                    let used := add(1, sub(length, mul(i, CHUNK)))
                    chunk := and(chunk, not(shr(mul(8, used), not(0))))
                }
                sstore(add(data, and(word, mask)), chunk)
                word := add(word, 1)
                ptr := add(ptr, CHUNK)
            }
        }

        uint256 checkpointHead = (meta >> 192) & U32;
        uint256 checkpointTail = meta >> 224;
        if (checkpointHead == checkpointTail || epoch != (meta >> 128) & U64) {
            if (checkpointHead - checkpointTail == CHECKPOINTS) {
                // Index full: the newest item absorbs this epoch, keeping its start.
                uint256 slot = _indexSlot(queue, checkpointHead - 1);
                assembly ("memory-safe") {
                    sstore(slot, or(shl(64, epoch), and(sload(slot), U64)))
                }
            } else {
                uint256 slot = _indexSlot(queue, checkpointHead);
                assembly ("memory-safe") {
                    sstore(slot, or(shl(64, epoch), head))
                }
                checkpointHead++;
            }
        }
        meta = (checkpointTail << 224) | (checkpointHead << 192) | (uint256(epoch) << 128) | (tail << 64)
            | (head + chunks + 1);
        assembly ("memory-safe") {
            sstore(queue, meta)
        }
    }

    /// @notice Pays ahead for the state growth of data words `[from, from + count)`, which must
    /// lie within the ring: writes a filler into each one still empty, so the pushes that
    /// first reach them only replace a nonzero word. Words the queue has already written are
    /// skipped; once the ring has been lapped there is nothing left to prime.
    function prime(uint256 queue, uint256 from, uint256 count) internal {
        if (from + count > CAPACITY) revert InputQueueBadIndex();
        (uint64 head,) = bounds(queue);
        if (from < head) {
            uint256 written = head - from;
            if (written >= count) return;
            from = head;
            count -= written;
        }
        assembly ("memory-safe") {
            let slot := add(add(queue, DATA_OFFSET), from)
            for { let end := add(slot, count) } lt(slot, end) { slot := add(slot, 1) } {
                if iszero(sload(slot)) { sstore(slot, 1) }
            }
        }
    }

    /// @notice Releases every entry filed under an epoch up to and including `epoch`.
    function release(uint256 queue, uint64 epoch) internal {
        uint256 meta;
        assembly ("memory-safe") {
            meta := sload(queue)
        }
        uint256 checkpointHead = (meta >> 192) & U32;
        uint256 checkpointTail = meta >> 224;
        if (checkpointHead == checkpointTail) return;

        uint256 first = checkpointTail;
        uint256 item;
        assembly ("memory-safe") {
            let index := add(queue, INDEX_OFFSET)
            for {} iszero(eq(checkpointTail, checkpointHead)) { checkpointTail := add(checkpointTail, 1) } {
                item := sload(add(index, mod(checkpointTail, CHECKPOINTS)))
                if gt(shr(64, item), epoch) { break }
            }
        }
        if (checkpointTail == first) return;

        // Everything before the first epoch left is released; with none left, everything is.
        uint256 tail = checkpointTail == checkpointHead ? meta & U64 : item & U64;
        meta = (checkpointTail << 224) | (meta & ~(U32 << 224) & ~(U64 << 64)) | (tail << 64);
        assembly ("memory-safe") {
            sstore(queue, meta)
        }
    }

    /// @notice Decodes the entry starting at word `index` and returns the word the next entry
    /// starts at. `index` must be the start of a live entry: `tail`, or a `next` returned for
    /// an earlier one.
    function entryAt(uint256 queue, uint64 index) internal view returns (Entry memory entry, uint64 next) {
        (uint64 head, uint64 tail) = bounds(queue);
        if (index < tail || index >= head) revert InputQueueBadIndex();
        uint256 header;
        assembly ("memory-safe") {
            header := sload(add(add(queue, DATA_OFFSET), and(index, sub(CAPACITY, 1))))
        }
        uint256 length = (header >> 216) & U32;
        uint256 chunks = (length + CHUNK - 1) / CHUNK;
        entry.kind = uint8(header >> 248);
        entry.l1BlockNumber = uint64(header >> 152);
        entry.l1Timestamp = uint64(header >> 88);
        entry.fee = header & U88;
        bytes memory payload = new bytes(chunks * CHUNK + 1);
        assembly ("memory-safe") {
            let mask := sub(CAPACITY, 1)
            let data := add(queue, DATA_OFFSET)
            let ptr := add(payload, 32)
            for { let i := 0 } lt(i, chunks) { i := add(i, 1) } {
                mstore(ptr, shl(8, sload(add(data, and(add(add(index, 1), i), mask)))))
                ptr := add(ptr, CHUNK)
            }
            mstore(payload, length)
        }
        entry.payload = payload;
        next = uint64(index + chunks + 1);
    }

    function _indexSlot(uint256 queue, uint256 position) private pure returns (uint256) {
        return queue + INDEX_OFFSET + (position % CHECKPOINTS);
    }
}
