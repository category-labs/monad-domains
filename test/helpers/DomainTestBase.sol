// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, StdStorage, stdStorage} from "forge-std/Test.sol";
import {DomainHub} from "../../src/DomainHub.sol";
import {DomainSpoke} from "../../src/DomainSpoke.sol";
import {DOMAIN_ENCRYPTION_PRECOMPILE} from "../../src/interfaces/IDomainEncryption.sol";
import {MessageLib} from "../../src/libraries/MessageLib.sol";
import {MerkleTreeLib} from "./MerkleTreeLib.sol";
import {MockDomainEncryption} from "../mocks/MockDomainEncryption.sol";

/// @notice Shared protocol steps for tests: registering a domain on the hub and attesting
/// state transitions the way validators do, on the domain's checkpoint schedule. A batch of
/// domain-origin messages is everything recorded since the last attestation; its root is the
/// anchor carried by the next attestation.
abstract contract DomainTestBase is Test {
    using stdStorage for StdStorage;

    /// @dev Attested L1 heights must be multiples of this.
    uint64 internal constant CHECKPOINT_INTERVAL = 10;
    bytes32 internal constant TEST_SALT = bytes32(uint256(1));
    /// @dev Checkpoint periods a test domain may leave unattested: the most the hub allows.
    uint8 internal constant MAX_UNATTESTED_PERIODS = 50;

    /// @dev `domainMessageCount` as of the last attestation per domain: the start of the
    /// next batch. Mirrors what a validator reads from the state at the previous checkpoint.
    mapping(uint64 => uint256) internal attestedMessageCounts;

    /// @dev Fee attached to test deliveries: above the hub's minimum for any test payload.
    uint256 internal constant DELIVERY_FEE = 0.1 ether;

    /// @dev The hub's `minSequencingFee`, without a call, so it can sit between a prank or an
    /// expected revert and the sequencing call.
    function _sequencingFee(uint256 payloadLength) internal pure returns (uint256) {
        return (21_000 + 10 * payloadLength) * 50 gwei;
    }

    /// @dev Registered as every test domain's fee recipient.
    receive() external payable {}

    // ---------------------------------------------------------------------
    // Input queue, read from the hub's storage
    // ---------------------------------------------------------------------

    struct QueueEntry {
        uint8 kind;
        // Of a block entry.
        uint64 l1BlockNumber;
        uint64 l1Timestamp;
        uint64 domainBlockNumber;
        uint64 slotNumber;
        bytes32 prevrandao;
        // Of an input.
        uint256 fee;
        bytes payload;
    }

    function _queueBase(uint64 chainId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(chainId, "monad.domains.input-queue"))) & ~uint256(127);
    }

    function _queueWord(DomainHub hub, uint64 chainId, uint256 slot) internal view returns (uint256) {
        return uint256(vm.load(address(hub), bytes32(_queueBase(chainId) + slot)));
    }

    function _queueBounds(DomainHub hub, uint64 chainId) internal view returns (uint64 head, uint64 tail) {
        uint256 state = _queueWord(hub, chainId, 1);
        return (uint64(state), uint64(state >> 64));
    }

    /// @dev The entry starting at ring word `index`, and the word the next entry starts at.
    function _queueEntry(DomainHub hub, uint64 chainId, uint64 index)
        internal
        view
        returns (QueueEntry memory entry, uint64 next)
    {
        uint256 header = _queueWord(hub, chainId, 128 + index % 131072);
        entry.kind = uint8(header >> 248);
        if (entry.kind == 4) {
            // Two words: the header, then prevrandao.
            entry.l1BlockNumber = uint64(header >> 184);
            entry.l1Timestamp = uint64(header >> 120);
            entry.domainBlockNumber = uint64(header >> 56);
            entry.slotNumber = uint56(header);
            entry.prevrandao = bytes32(_queueWord(hub, chainId, 128 + (index + 1) % 131072));
            return (entry, index + 2);
        }
        entry.fee = uint88(header);
        uint256 length = uint32(header >> 216);
        entry.payload = new bytes(length);
        next = index + 1;
        for (uint256 copied = 0; copied < length; next++) {
            // 0x01, then 31 payload bytes, zero past the payload's end.
            uint256 chunk = _queueWord(hub, chainId, 128 + next % 131072);
            assertEq(chunk >> 248, 1, "chunk tag");
            for (uint256 i = 0; i < 31; i++) {
                uint8 value = uint8(chunk >> (240 - 8 * i));
                if (copied < length) {
                    entry.payload[copied++] = bytes1(value);
                } else {
                    assertEq(value, 0, "chunk padding");
                }
            }
        }
    }

    // ---------------------------------------------------------------------
    // Keys
    // ---------------------------------------------------------------------

    function _keys(uint256 key) internal pure returns (uint256[] memory keys) {
        keys = new uint256[](1);
        keys[0] = key;
    }

    function _keys(uint256 a, uint256 b) internal pure returns (uint256[] memory keys) {
        keys = new uint256[](2);
        keys[0] = a;
        keys[1] = b;
    }

    function _keys(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory keys) {
        keys = new uint256[](3);
        keys[0] = a;
        keys[1] = b;
        keys[2] = c;
    }

    function _addresses(uint256[] memory keys) internal pure returns (address[] memory validators) {
        validators = new address[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            validators[i] = vm.addr(keys[i]);
        }
    }

    // ---------------------------------------------------------------------
    // Registration
    // ---------------------------------------------------------------------

    /// @dev Registers `chainId` with the validators behind `keys`, the test contract as fee
    /// recipient, no viewing key and the shared checkpoint interval.
    function _registerDomain(DomainHub hub, uint64 chainId, uint256[] memory keys, uint256 quorum) internal {
        hub.registerDomain(
            chainId, _addresses(keys), quorum, address(this), "", CHECKPOINT_INTERVAL, MAX_UNATTESTED_PERIODS
        );
    }

    /// @dev Single validator, quorum 1.
    function _registerDomain(DomainHub hub, uint64 chainId, uint256 key) internal {
        _registerDomain(hub, chainId, _keys(key), 1);
    }

    // ---------------------------------------------------------------------
    // Attestation
    // ---------------------------------------------------------------------

    /// @dev The first scheduled height above the hub's latest attested one.
    function _nextCheckpointHeight(DomainHub hub, uint64 chainId) internal view returns (uint64) {
        uint64 interval = hub.checkpointIntervals(chainId);
        return (hub.domainBlockNumbers(chainId) / interval + 1) * interval;
    }

    /// @dev One validator's signature over the transition at the hub's current nonce.
    function _signTransition(DomainHub hub, uint64 chainId, uint64 l1Block, bytes32 root, bytes32 anchor, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hub.stateTransitionDigest(chainId, l1Block, root, anchor));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Attests `(l1Block, root, anchor)` with every key in turn, rolling the L1 past
    /// `l1Block` first so the height counts as final. Stops once the state advanced.
    function _attest(DomainHub hub, uint64 chainId, uint64 l1Block, bytes32 root, bytes32 anchor, uint256[] memory keys)
        internal
    {
        if (block.number <= l1Block) vm.roll(uint256(l1Block) + 1);
        for (uint256 i = 0; i < keys.length; i++) {
            hub.submitStateSignature(
                chainId, l1Block, root, anchor, _signTransition(hub, chainId, l1Block, root, anchor, keys[i])
            );
            if (hub.domainBlockNumbers(chainId) == l1Block) break;
        }
    }

    /// @dev Attests at the next scheduled height.
    function _attestNext(DomainHub hub, uint64 chainId, bytes32 root, bytes32 anchor, uint256[] memory keys)
        internal
        returns (uint64 l1Block)
    {
        l1Block = _nextCheckpointHeight(hub, chainId);
        _attest(hub, chainId, l1Block, root, anchor, keys);
    }

    // ---------------------------------------------------------------------
    // Batches
    // ---------------------------------------------------------------------

    /// @dev Message IDs with nonce in `[fromNonce, toNonce)`, the leaves of that batch.
    function _batchLeaves(DomainSpoke spoke, uint256 fromNonce, uint256 toNonce)
        internal
        view
        returns (bytes32[] memory leaves)
    {
        leaves = new bytes32[](toNonce - fromNonce);
        for (uint256 i = 0; i < leaves.length; i++) {
            leaves[i] = spoke.domainMessageIds(fromNonce + i);
        }
    }

    /// @dev Leaves of the batch an attestation would anchor now: everything recorded since
    /// the last attestation of this spoke's domain.
    function _pendingLeaves(DomainSpoke spoke) internal view returns (bytes32[] memory) {
        return _batchLeaves(spoke, attestedMessageCounts[spoke.DOMAIN_CHAIN_ID()], spoke.domainMessageCount());
    }

    /// @dev Anchors every message recorded since the last attestation at the next scheduled
    /// height, signed by `keys`. Returns the anchor (zero when nothing was recorded).
    function _attestBatch(DomainHub hub, DomainSpoke spoke, uint256[] memory keys) internal returns (bytes32 anchor) {
        bytes32[] memory leaves = _pendingLeaves(spoke);
        anchor = leaves.length == 0 ? bytes32(0) : MerkleTreeLib.root(leaves);
        _attestNext(hub, spoke.DOMAIN_CHAIN_ID(), bytes32(0), anchor, keys);
        attestedMessageCounts[spoke.DOMAIN_CHAIN_ID()] = spoke.domainMessageCount();
    }

    function _attestBatch(DomainHub hub, DomainSpoke spoke, uint256 key) internal returns (bytes32 anchor) {
        return _attestBatch(hub, spoke, _keys(key));
    }

    // ---------------------------------------------------------------------
    // Forwarded encrypted messages
    // ---------------------------------------------------------------------

    /// @dev The envelope `sourceChainId`'s spoke records for `ciphertext` sealed to
    /// `destinationChainId` under `sourceNonce`, with its ID written into the hub's storage as
    /// an attested anchor of the source. Relaying it with an empty proof makes the hub record
    /// an encrypted message, which it takes from no other call. The source must be registered.
    function _attestedSealedMessage(
        DomainHub hub,
        uint64 sourceChainId,
        uint64 destinationChainId,
        uint256 sourceNonce,
        bytes memory ciphertext
    ) internal returns (MessageLib.DomainMessage memory message, bytes32 anchor) {
        message = MessageLib.DomainMessage({
            kind: MessageLib.MessageKind.Encrypted,
            sourceChainId: sourceChainId,
            destinationChainId: destinationChainId,
            from: address(0),
            to: address(0),
            sourceNonce: sourceNonce,
            salt: bytes32(0),
            data: ciphertext
        });
        anchor = MessageLib.hashDomainMessage(message, block.chainid, address(hub));
        stdstore.target(address(hub)).sig(hub.domainAnchors.selector).with_key(uint256(sourceChainId)).with_key(anchor)
            .checked_write(true);
    }

    // ---------------------------------------------------------------------
    // Encryption precompile
    // ---------------------------------------------------------------------

    /// @dev Etches the encryption precompile mock at its address; register destination keys
    /// with `setViewingKey`.
    function _installEncryptionPrecompile() internal returns (MockDomainEncryption precompile) {
        vm.etch(DOMAIN_ENCRYPTION_PRECOMPILE, address(new MockDomainEncryption()).code);
        vm.label(DOMAIN_ENCRYPTION_PRECOMPILE, "DomainEncryption");
        return MockDomainEncryption(DOMAIN_ENCRYPTION_PRECOMPILE);
    }

    /// @dev Opens a mock ciphertext into the delivery's sender, target and payload, as the
    /// destination client would.
    function _openMessage(bytes memory ciphertext) internal pure returns (address from, address to, bytes memory data) {
        (,,, bytes memory plaintext) = MockDomainEncryption(DOMAIN_ENCRYPTION_PRECOMPILE).openMessage(ciphertext);
        return MessageLib.decodePlaintext(plaintext);
    }
}
