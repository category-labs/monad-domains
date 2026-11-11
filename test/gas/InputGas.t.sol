// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {DomainHub} from "../../src/DomainHub.sol";
import {DomainTestBase} from "../helpers/DomainTestBase.sol";

/// @dev Two storage reads, to tell whether storage is priced by page (MIP-8).
contract PageProbe {
    function read(uint256 a, uint256 b) external view returns (uint256 sum) {
        assembly ("memory-safe") {
            sum := add(sload(a), sload(b))
        }
    }
}

/// @notice Gas of the hub's input and attestation paths, one L1 transaction per measurement.
/// Run with `forge test --match-path 'test/gas/*' --isolate -vv` on a Foundry that prices
/// storage the Monad way (1.8 or later; the tests skip themselves otherwise). Isolation
/// executes every call below as its own transaction, so each pays intrinsic gas, calldata
/// and cold storage as it would on chain. Results are logged as
/// `GAS,<scenario>,<payload bytes or periods>,<gas>`.
contract InputGasTest is DomainTestBase {
    uint64 internal constant CHAIN_ID = 7777;
    uint256 internal constant KEY = 0xA11CE;
    uint256 internal constant KEY_2 = 0xB0B;

    DomainHub internal hub;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        vm.roll(1_000);
        // A zero prevrandao would make the block entry's second word a zero write.
        vm.prevrandao(keccak256("prevrandao"));
        hub = new DomainHub();
        hub.registerDomain(
            CHAIN_ID, _addresses(_keys(KEY, KEY_2)), 1, feeRecipient, "", CHECKPOINT_INTERVAL, MAX_UNATTESTED_PERIODS
        );
        vm.deal(alice, 1_000_000 ether);
        vm.deal(feeRecipient, 1 ether);
    }

    /// @dev Skips the test unless a second read in a storage page is cheaper than a read in
    /// another page.
    modifier pagePriced() {
        PageProbe probe = new PageProbe();
        probe.read(0x1000, 0x1001);
        uint256 samePage = vm.lastCallGas().gasTotalUsed;
        probe.read(0x2000, 0x3000);
        if (vm.lastCallGas().gasTotalUsed < samePage + 4_000) {
            console.log("storage is not priced by page: gas measurements skipped");
            vm.skip(true);
        }
        _;
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev First slot of the domain's input queue, or zero on a hub that keeps none.
    function _queue() internal view returns (uint256 base) {
        base = uint256(keccak256(abi.encode(CHAIN_ID, "monad.domains.input-queue"))) & ~uint256(127);
        if (vm.load(address(hub), bytes32(base + 2)) == 0) base = 0;
    }

    /// @dev Puts the hub in its long-run state: every word of the checkpoint table and the
    /// ring already nonzero, as after their first lap, and the domain's bookkeeping slots
    /// written by earlier calls.
    function _steadyState() internal {
        uint256 base = _queue();
        if (base != 0) {
            for (uint256 i = 3; i < 128 + (1 << 16); i++) {
                if (vm.load(address(hub), bytes32(base + i)) == 0) {
                    vm.store(address(hub), bytes32(base + i), bytes32(uint256(1)));
                }
            }
        }
        _send(DomainHub.sequenceToDomain.selector, abi.encode(CHAIN_ID, _bytes(100, 0)), 100_000, true);
        _send(DomainHub.sendL1Message.selector, abi.encode(CHAIN_ID, bob, _bytes(100, 0)), 300_000, true);
    }

    /// @dev Empties the queue and moves it to the next page boundary, as if everything before
    /// had been released, so the next entry starts a page and touches as few as it can.
    function _alignQueue() internal {
        uint256 base = _queue();
        if (base == 0) return;
        uint256 state = uint256(vm.load(address(hub), bytes32(base + 1)));
        uint256 head = (uint64(state) + 127) & ~uint256(127);
        vm.store(address(hub), bytes32(base + 1), bytes32((state >> 128 << 128) | (head << 64) | head));
    }

    /// @dev Incompressible bytes, like a signed or encrypted transaction.
    function _bytes(uint256 length, uint256 seed) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            out[i] = keccak256(abi.encode(seed, i / 32))[i % 32];
        }
    }

    /// @dev One transaction from alice paying for `domainGas`, in a fresh L1 block if `newBlock`.
    function _send(bytes4 selector, bytes memory arguments, uint256 domainGas, bool newBlock)
        internal
        returns (uint256)
    {
        if (newBlock) vm.roll(block.number + 1);
        uint256 fee = domainGas * hub.DOMAIN_GAS_PRICE();
        vm.prank(alice);
        (bool ok,) = address(hub).call{value: fee}(abi.encodePacked(selector, arguments));
        uint256 gasUsed = vm.lastCallGas().gasTotalUsed;
        require(ok, "bench call failed");
        return gasUsed;
    }

    function _log(string memory scenario, uint256 size, uint256 gasUsed) internal pure {
        console.log(string.concat("GAS,", scenario, ",", vm.toString(size), ",", vm.toString(gasUsed)));
    }

    function _sequencingGas(uint256 size) internal pure returns (uint256) {
        return 100_000 + 10 * size;
    }

    function _deliveryGas(uint256 size) internal pure returns (uint256) {
        return 200_000 + 48 * size + 50_000;
    }

    function _transactionSizes() internal pure returns (uint256[] memory sizes) {
        sizes = new uint256[](6);
        sizes[0] = 110; // native transfer
        sizes[1] = 180; // ERC-20 transfer
        sizes[2] = 500;
        sizes[3] = 2_000;
        sizes[4] = 8_000;
        sizes[5] = 32_000;
    }

    function _messageSizes() internal pure returns (uint256[] memory sizes) {
        sizes = new uint256[](4);
        sizes[0] = 0;
        sizes[1] = 100; // a bridge deposit
        sizes[2] = 500;
        sizes[3] = 2_000;
    }

    // ---------------------------------------------------------------------
    // Inputs
    // ---------------------------------------------------------------------

    /// @dev The first input of an L1 block, which also opens the domain's next block.
    function test_gas_sequence_newBlock() public pagePriced {
        _steadyState();
        uint256[] memory sizes = _transactionSizes();
        for (uint256 i = 0; i < sizes.length; i++) {
            _alignQueue();
            bytes memory arguments = abi.encode(CHAIN_ID, _bytes(sizes[i], i + 1));
            _log(
                "sequence/new-block",
                sizes[i],
                _send(DomainHub.sequenceToDomain.selector, arguments, _sequencingGas(sizes[i]), true)
            );
        }
    }

    /// @dev A later input of an L1 block.
    function test_gas_sequence_sameBlock() public pagePriced {
        _steadyState();
        uint256[] memory sizes = _transactionSizes();
        for (uint256 i = 0; i < sizes.length; i++) {
            bytes memory arguments = abi.encode(CHAIN_ID, _bytes(sizes[i], i + 1));
            _log(
                "sequence/same-block",
                sizes[i],
                _send(DomainHub.sequenceToDomain.selector, arguments, _sequencingGas(sizes[i]), false)
            );
        }
    }

    /// @dev Into ring words nothing has been written to yet.
    function test_gas_sequence_firstLap() public pagePriced {
        _send(DomainHub.sequenceToDomain.selector, abi.encode(CHAIN_ID, _bytes(100, 0)), 100_000, true);
        uint256[] memory sizes = _transactionSizes();
        for (uint256 i = 0; i < sizes.length; i++) {
            bytes memory arguments = abi.encode(CHAIN_ID, _bytes(sizes[i], i + 1));
            _log(
                "sequence/first-lap",
                sizes[i],
                _send(DomainHub.sequenceToDomain.selector, arguments, _sequencingGas(sizes[i]), false)
            );
        }
    }

    function test_gas_message_newBlock() public pagePriced {
        _steadyState();
        uint256[] memory sizes = _messageSizes();
        for (uint256 i = 0; i < sizes.length; i++) {
            _alignQueue();
            bytes memory arguments = abi.encode(CHAIN_ID, bob, _bytes(sizes[i], i + 1));
            _log(
                "message/new-block",
                sizes[i],
                _send(DomainHub.sendL1Message.selector, arguments, _deliveryGas(sizes[i]), true)
            );
        }
    }

    function test_gas_message_sameBlock() public pagePriced {
        _steadyState();
        uint256[] memory sizes = _messageSizes();
        for (uint256 i = 0; i < sizes.length; i++) {
            bytes memory arguments = abi.encode(CHAIN_ID, bob, _bytes(sizes[i], i + 1));
            _log(
                "message/same-block",
                sizes[i],
                _send(DomainHub.sendL1Message.selector, arguments, _deliveryGas(sizes[i]), false)
            );
        }
    }

    function test_gas_encryptedMessage_sameBlock() public pagePriced {
        _steadyState();
        uint256[] memory sizes = _messageSizes();
        for (uint256 i = 1; i < sizes.length; i++) {
            bytes memory arguments = abi.encode(CHAIN_ID, _bytes(sizes[i], i + 1));
            _log(
                "encrypted/same-block",
                sizes[i],
                _send(DomainHub.sendEncryptedL1Message.selector, arguments, _deliveryGas(sizes[i]), false)
            );
        }
    }

    /// @dev Paying ahead for the state growth of whole pages of the ring; the size logged is
    /// the number of pages.
    function test_gas_prime() public pagePriced {
        if (_queue() == 0) return;
        uint8[2] memory pages = [1, 8];
        uint256 from = 128;
        for (uint256 i = 0; i < pages.length; i++) {
            uint256 count = uint256(pages[i]) * 128;
            (bool ok,) = address(hub)
                .call(abi.encodeWithSignature("primeInputQueue(uint64,uint256,uint256)", CHAIN_ID, from, count));
            _log("prime", pages[i], vm.lastCallGas().gasTotalUsed);
            require(ok, "bench call failed");
            from += count;
        }
    }

    // ---------------------------------------------------------------------
    // Attestation
    // ---------------------------------------------------------------------

    /// @dev Records one input in each of `periods` checkpoint periods after an attested
    /// height, and returns the height that covers them all.
    function _unattestedPeriods(uint256 periods) internal returns (uint64 target) {
        _steadyState();
        uint64 height = (uint64(block.number) / CHECKPOINT_INTERVAL + 1) * CHECKPOINT_INTERVAL;
        _attest(hub, CHAIN_ID, height, bytes32(uint256(1)), bytes32(0), _keys(KEY));
        for (uint256 i = 0; i < periods; i++) {
            vm.roll(height + i * CHECKPOINT_INTERVAL);
            _send(DomainHub.sequenceToDomain.selector, abi.encode(CHAIN_ID, _bytes(110, i)), 100_000, true);
        }
        target = height + uint64(periods == 0 ? 1 : periods) * CHECKPOINT_INTERVAL;
        vm.roll(uint256(target) + 1);
    }

    /// @dev The signature that reaches quorum, releasing the inputs of `periods` periods.
    function _quorumGas(uint256 periods) internal returns (uint256 gasUsed) {
        uint64 target = _unattestedPeriods(periods);
        bytes memory signature = _signTransition(hub, CHAIN_ID, target, bytes32(uint256(2)), bytes32(0), KEY);
        hub.submitStateSignature(CHAIN_ID, target, bytes32(uint256(2)), bytes32(0), signature);
        gasUsed = vm.lastCallGas().gasTotalUsed;
        assertEq(hub.domainBlockNumbers(CHAIN_ID), target);
    }

    function test_gas_attestation_releasing0() public pagePriced {
        _log("attestation/quorum", 0, _quorumGas(0));
    }

    function test_gas_attestation_releasing1() public pagePriced {
        _log("attestation/quorum", 1, _quorumGas(1));
    }

    function test_gas_attestation_releasing50() public pagePriced {
        _log("attestation/quorum", 50, _quorumGas(50));
    }

    /// @dev A signature that does not reach quorum yet.
    function test_gas_attestation_vote() public pagePriced {
        hub.registerDomain(
            8888, _addresses(_keys(KEY, KEY_2)), 2, feeRecipient, "", CHECKPOINT_INTERVAL, MAX_UNATTESTED_PERIODS
        );
        // An earlier transition, so the measured vote rewrites slots rather than creating them.
        _attest(hub, 8888, 1_000, bytes32(uint256(1)), bytes32(0), _keys(KEY, KEY_2));
        vm.roll(1_011);
        bytes memory signature = _signTransition(hub, 8888, 1_010, bytes32(uint256(2)), bytes32(0), KEY);
        hub.submitStateSignature(8888, 1_010, bytes32(uint256(2)), bytes32(0), signature);
        _log("attestation/vote", 0, vm.lastCallGas().gasTotalUsed);
        assertEq(hub.domainBlockNumbers(8888), 1_000);
    }
}
