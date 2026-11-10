// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {DomainHub} from "../../src/DomainHub.sol";
import {DomainTestBase} from "../helpers/DomainTestBase.sol";

/// @notice Gas of the hub's input paths, one L1 transaction per measurement. Run with
/// `forge test --match-path 'test/gas/*' --isolate -vv`: isolation executes every call below as
/// its own transaction, so each pays intrinsic gas, calldata and cold storage as it would on
/// chain. Results are logged as `GAS,<variant>,<scenario>,<payload bytes>,<gas>`.
///
/// The file only uses calls the hub had before the input queue, so the same file measures
/// both; the queue's storage is located through `inputQueueBase` when the hub has one.
contract InputGasTest is DomainTestBase {
    uint64 internal constant CHAIN_ID = 7777;
    uint256 internal constant VALIDATOR_KEY = 0xA11CE;

    DomainHub internal hub;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        hub = _deployHub();
        hub.registerDomain(CHAIN_ID, _addresses(_keys(VALIDATOR_KEY)), 1, feeRecipient, "", CHECKPOINT_INTERVAL);
        vm.deal(alice, 1_000_000 ether);
        vm.deal(feeRecipient, 1 ether);
        vm.roll(1_000);
    }

    // ---------------------------------------------------------------------
    // Variant hooks
    // ---------------------------------------------------------------------

    function _deployHub() internal virtual returns (DomainHub) {
        return new DomainHub();
    }

    function _variant() internal view virtual returns (string memory) {
        return _hasQueue() ? "queue+events" : "events";
    }

    function _sequenceSelector() internal pure virtual returns (bytes4) {
        return DomainHub.sequenceToDomain.selector;
    }

    function _messageSelector() internal pure virtual returns (bytes4) {
        return DomainHub.sendL1Message.selector;
    }

    function _encryptedSelector() internal pure virtual returns (bytes4) {
        return DomainHub.sendEncryptedL1Message.selector;
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _queueBase() internal view returns (bool found, uint256 base) {
        (bool ok, bytes memory out) =
            address(hub).staticcall(abi.encodeWithSignature("inputQueueBase(uint64)", CHAIN_ID));
        if (ok && out.length == 32) return (true, abi.decode(out, (uint256)));
    }

    function _hasQueue() internal view returns (bool found) {
        (found,) = _queueBase();
    }

    /// @dev Puts the hub in its long-run state: every queue word already nonzero, as after the
    /// ring's first lap, and the domain's bookkeeping slots written by an earlier call.
    function _steadyState() internal {
        (bool found, uint256 base) = _queueBase();
        if (found) {
            for (uint256 i = 4; i < 128 + (1 << 16); i++) {
                vm.store(address(hub), bytes32(base + i), bytes32(uint256(1)));
            }
        }
        _send(_sequenceSelector(), abi.encode(CHAIN_ID, _bytes(100, 0)), 100_000);
        _send(_messageSelector(), abi.encode(CHAIN_ID, bob, _bytes(100, 0)), 300_000);
    }

    /// @dev Empties the queue and moves it to the next page boundary, as if everything before
    /// had been released, so the next entry starts a page and touches as few as it can. An
    /// entry of `w` words that starts mid-page may touch one page more.
    function _alignQueue() internal {
        (bool found, uint256 base) = _queueBase();
        if (!found) return;
        uint256 meta = uint256(vm.load(address(hub), bytes32(base)));
        uint256 head = (uint64(meta) + 127) & ~uint256(127);
        uint256 checkpointHead = uint32(meta >> 192);
        meta = (checkpointHead << 224) | (checkpointHead << 192) | (uint256(uint64(meta >> 128)) << 128) | (head << 64)
            | head;
        vm.store(address(hub), bytes32(base), bytes32(meta));
    }

    /// @dev Incompressible bytes, like a signed or encrypted transaction.
    function _bytes(uint256 length, uint256 seed) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i = 0; i < length; i += 32) {
            bytes32 word = keccak256(abi.encode(seed, i));
            assembly ("memory-safe") {
                mstore(add(add(out, 32), i), word)
            }
        }
        // The loop may have written past the end; restore the length word's neighbours.
        assembly ("memory-safe") {
            mstore(add(add(out, 32), length), 0)
            mstore(0x40, add(add(out, 64), and(add(length, 31), not(31))))
        }
    }

    /// @dev One transaction from alice in a fresh L1 block, paying for `domainGas`.
    function _send(bytes4 selector, bytes memory arguments, uint256 domainGas) internal returns (uint256 gasUsed) {
        vm.roll(block.number + 1);
        uint256 fee = domainGas * hub.DOMAIN_GAS_PRICE();
        vm.prank(alice);
        (bool ok,) = address(hub).call{value: fee}(abi.encodePacked(selector, arguments));
        Vm.Gas memory gas = vm.lastCallGas();
        require(ok, "bench call failed");
        return gas.gasTotalUsed;
    }

    function _log(string memory scenario, uint256 size, uint256 gasUsed) internal view {
        console.log(string.concat("GAS,", _variant(), ",", scenario, ",", vm.toString(size), ",", vm.toString(gasUsed)));
    }

    function _deliveryGas(uint256 size) internal pure returns (uint256) {
        return 200_000 + 48 * size + 50_000;
    }

    function _transactionSizes() internal pure returns (uint256[] memory sizes) {
        sizes = new uint256[](9);
        sizes[0] = 110; // native transfer
        sizes[1] = 180; // ERC-20 transfer
        sizes[2] = 500;
        sizes[3] = 1_000;
        sizes[4] = 2_000;
        sizes[5] = 4_000;
        sizes[6] = 8_000;
        sizes[7] = 16_000;
        sizes[8] = 32_000;
    }

    function _messageSizes() internal pure returns (uint256[] memory sizes) {
        sizes = new uint256[](5);
        sizes[0] = 0;
        sizes[1] = 100; // a bridge deposit
        sizes[2] = 500;
        sizes[3] = 2_000;
        sizes[4] = 8_000;
    }

    // ---------------------------------------------------------------------
    // Measurements
    // ---------------------------------------------------------------------

    function test_gas_sequence_steady() public {
        _steadyState();
        uint256[] memory sizes = _transactionSizes();
        for (uint256 i = 0; i < sizes.length; i++) {
            _alignQueue();
            bytes memory rlpTx = _bytes(sizes[i], i + 1);
            _log("sequence/steady", sizes[i], _send(_sequenceSelector(), abi.encode(CHAIN_ID, rlpTx), 100_000));
        }
    }

    function test_gas_sequence_firstLap() public {
        _send(_sequenceSelector(), abi.encode(CHAIN_ID, _bytes(100, 0)), 100_000);
        uint256[] memory sizes = _transactionSizes();
        for (uint256 i = 0; i < sizes.length; i++) {
            _alignQueue();
            bytes memory rlpTx = _bytes(sizes[i], i + 1);
            _log("sequence/first-lap", sizes[i], _send(_sequenceSelector(), abi.encode(CHAIN_ID, rlpTx), 100_000));
        }
    }

    function test_gas_message_steady() public {
        _steadyState();
        uint256[] memory sizes = _messageSizes();
        for (uint256 i = 0; i < sizes.length; i++) {
            _alignQueue();
            bytes memory data = _bytes(sizes[i], i + 1);
            _log(
                "message/steady",
                sizes[i],
                _send(_messageSelector(), abi.encode(CHAIN_ID, bob, data), _deliveryGas(sizes[i]))
            );
        }
    }

    function test_gas_message_firstLap() public {
        _send(_messageSelector(), abi.encode(CHAIN_ID, bob, _bytes(100, 0)), 300_000);
        uint256[] memory sizes = _messageSizes();
        for (uint256 i = 0; i < sizes.length; i++) {
            _alignQueue();
            bytes memory data = _bytes(sizes[i], i + 1);
            _log(
                "message/first-lap",
                sizes[i],
                _send(_messageSelector(), abi.encode(CHAIN_ID, bob, data), _deliveryGas(sizes[i]))
            );
        }
    }

    function test_gas_encryptedMessage_steady() public {
        _steadyState();
        uint256[] memory sizes = _messageSizes();
        for (uint256 i = 1; i < sizes.length; i++) {
            _alignQueue();
            bytes memory ciphertext = _bytes(sizes[i], i + 1);
            _log(
                "encrypted/steady",
                sizes[i],
                _send(_encryptedSelector(), abi.encode(CHAIN_ID, ciphertext), _deliveryGas(sizes[i]))
            );
        }
    }

    /// @dev Paying ahead for the state growth of whole pages of the queue; the size logged is
    /// the number of pages.
    function test_gas_prime() public {
        if (!_hasQueue()) return;
        uint8[3] memory pages = [1, 8, 32];
        uint256 from = 128;
        for (uint256 i = 0; i < pages.length; i++) {
            uint256 count = uint256(pages[i]) * 128;
            (bool ok,) = address(hub)
                .call(abi.encodeWithSignature("primeInputQueue(uint64,uint256,uint256)", CHAIN_ID, from, count));
            require(ok, "bench call failed");
            _log("prime", pages[i], vm.lastCallGas().gasTotalUsed);
            from += count;
        }
    }

    /// @dev The attestation that reaches quorum, releasing the inputs of `periods` checkpoint
    /// periods (logged as the size) from the queue.
    function _attestationGas(uint256 periods) internal returns (uint256) {
        _steadyState();
        // Attest the current height first, so the measured attestation releases exactly the
        // periods recorded below and rewrites slots an earlier one already wrote.
        uint64 height = (uint64(block.number) / CHECKPOINT_INTERVAL + 1) * CHECKPOINT_INTERVAL;
        _attest(hub, CHAIN_ID, height, bytes32(uint256(1)), bytes32(0), _keys(VALIDATOR_KEY));
        for (uint256 i = 0; i < periods; i++) {
            vm.roll(height + i * CHECKPOINT_INTERVAL + 1);
            _send(_sequenceSelector(), abi.encode(CHAIN_ID, _bytes(110, i)), 100_000);
        }
        uint64 target = height + uint64(periods == 0 ? 1 : periods) * CHECKPOINT_INTERVAL;
        vm.roll(uint256(target) + 1);
        bytes memory signature = _signTransition(hub, CHAIN_ID, target, bytes32(uint256(2)), bytes32(0), VALIDATOR_KEY);
        hub.submitStateSignature(CHAIN_ID, target, bytes32(uint256(2)), bytes32(0), signature);
        Vm.Gas memory gas = vm.lastCallGas();
        assertEq(hub.domainBlockNumbers(CHAIN_ID), target);
        (bool found, uint256 base) = _queueBase();
        if (found) {
            // Everything recorded was released.
            uint256 meta = uint256(vm.load(address(hub), bytes32(base)));
            assertEq(uint64(meta), uint64(meta >> 64));
        }
        return gas.gasTotalUsed;
    }

    function test_gas_attestation_releasing0() public {
        _log("attestation", 0, _attestationGas(0));
    }

    function test_gas_attestation_releasing1() public {
        _log("attestation", 1, _attestationGas(1));
    }

    function test_gas_attestation_releasing124() public {
        _log("attestation", 124, _attestationGas(124));
    }
}
