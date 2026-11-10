// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDomainMessageReceiver, IDomainHub, IDomainSpoke} from "../src/interfaces/IDomain.sol";
import {MessageLib} from "../src/libraries/MessageLib.sol";
import {DomainHub} from "../src/DomainHub.sol";
import {DomainSpoke} from "../src/DomainSpoke.sol";
import {MockDomainEncryption} from "./mocks/MockDomainEncryption.sol";
import {DomainTestBase} from "./helpers/DomainTestBase.sol";

/// @notice Exercises the messaging layer directly: the hub (L1) and spoke (domain). The test
/// contract is the fee recipient. Checkpoint attestation is covered by DomainCheckpoint.t.sol.
contract DomainMessagingTest is DomainTestBase {
    uint64 internal constant CHAIN_ID = 7777;

    // Validator private keys of the registered set.
    uint256 internal constant K1 = 0xA11CE;
    uint256 internal constant K2 = 0xB0B;
    uint256 internal constant K3 = 0xC0DE;

    bytes internal constant VIEWING_KEY = hex"7b4e909bbe7ffe44c465a220037d608ee35897d31ef972f07f74892cb0f73f13";

    DomainHub internal hub;
    DomainSpoke internal spoke;
    MockDomainEncryption internal precompile;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");
    address internal feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        hub = new DomainHub();
        _registerDomain(hub, CHAIN_ID, _keys(K1, K2, K3), 2);
        spoke = new DomainSpoke(CHAIN_ID, block.chainid, address(hub));
        precompile = _installEncryptionPrecompile();
        vm.deal(alice, 100 ether);
    }

    function _validators() internal pure returns (address[] memory) {
        return _addresses(_keys(K1, K2, K3));
    }

    function _register(uint64 chainId, address recipient, bytes memory viewingKey, uint64 interval) internal {
        hub.registerDomain(chainId, _validators(), 2, recipient, viewingKey, interval, MAX_UNATTESTED_PERIODS);
    }

    // ---------------------------------------------------------------------
    // Registration
    // ---------------------------------------------------------------------

    function test_register_rejectsL1ChainId() public {
        vm.expectRevert(DomainHub.L1ChainIdNotAllowed.selector);
        _register(uint64(block.chainid), feeRecipient, "", 1);
    }

    function test_register_rejectsDuplicate() public {
        vm.expectRevert(DomainHub.DomainAlreadyRegistered.selector);
        _register(CHAIN_ID, feeRecipient, "", 1);
    }

    function test_register_rejectsZeroQuorum() public {
        vm.expectRevert(DomainHub.ZeroQuorum.selector);
        hub.registerDomain(4444, _validators(), 0, feeRecipient, "", 1, MAX_UNATTESTED_PERIODS);
    }

    function test_register_rejectsQuorumAboveValidatorCount() public {
        vm.expectRevert(DomainHub.QuorumExceedsValidators.selector);
        hub.registerDomain(4444, _validators(), 4, feeRecipient, "", 1, MAX_UNATTESTED_PERIODS);
    }

    function test_register_rejectsZeroValidator() public {
        address[] memory validators = new address[](1);
        validators[0] = address(0);
        vm.expectRevert(DomainHub.ZeroValidator.selector);
        hub.registerDomain(4444, validators, 1, feeRecipient, "", 1, MAX_UNATTESTED_PERIODS);
    }

    function test_register_rejectsDuplicateValidator() public {
        address[] memory validators = new address[](2);
        validators[0] = vm.addr(K1);
        validators[1] = vm.addr(K1);
        vm.expectRevert(DomainHub.DuplicateValidator.selector);
        hub.registerDomain(4444, validators, 1, feeRecipient, "", 1, MAX_UNATTESTED_PERIODS);
    }

    function test_register_rejectsZeroFeeRecipient() public {
        vm.expectRevert(DomainHub.ZeroFeeRecipient.selector);
        _register(4444, address(0), "", 1);
    }

    function test_register_rejectsZeroCheckpointInterval() public {
        vm.expectRevert(DomainHub.ZeroCheckpointInterval.selector);
        _register(4444, feeRecipient, "", 0);
    }

    function test_register_rejectsPeriodLimitOutOfRange() public {
        vm.expectRevert(DomainHub.InvalidMaxUnattestedPeriods.selector);
        hub.registerDomain(4444, _validators(), 2, feeRecipient, "", 1, 0);
        vm.expectRevert(DomainHub.InvalidMaxUnattestedPeriods.selector);
        hub.registerDomain(4444, _validators(), 2, feeRecipient, "", 1, 51);
    }

    function test_register_rejectsMalformedViewingKey() public {
        vm.expectRevert(DomainHub.InvalidViewingKey.selector);
        _register(4444, feeRecipient, hex"c0ffee", 1);

        vm.expectRevert(DomainHub.InvalidViewingKey.selector);
        _register(4444, feeRecipient, bytes.concat(VIEWING_KEY, hex"00"), 1);
    }

    function test_register_storesConfig() public {
        vm.expectEmit(true, true, false, true, address(hub));
        emit IDomainHub.DomainRegistered(4444, feeRecipient, 25);
        vm.expectEmit(true, false, false, true, address(hub));
        emit IDomainHub.ViewingKeyRegistered(4444, "");
        vm.prank(stranger); // registration is permissionless; the caller gets no role
        _register(4444, feeRecipient, "", 25);

        assertTrue(hub.isDomainRegistered(4444));
        assertFalse(hub.isDomainRegistered(5555));
        assertEq(hub.feeRecipients(4444), feeRecipient);
        assertEq(hub.checkpointIntervals(4444), 25);
        assertEq(hub.maxUnattestedPeriods(4444), MAX_UNATTESTED_PERIODS);
        assertEq(hub.quorums(4444), 2);
        assertEq(hub.viewingKeys(4444), "");
        assertEq(hub.getValidators(4444), _validators());
    }

    function test_register_publishesViewingKey() public {
        vm.expectEmit(true, false, false, true, address(hub));
        emit IDomainHub.ViewingKeyRegistered(4444, VIEWING_KEY);
        _register(4444, feeRecipient, VIEWING_KEY, 1);

        // Senders read the key from the hub to encrypt domain transactions to it.
        assertEq(hub.viewingKeys(4444), VIEWING_KEY);
        assertEq(hub.viewingKeys(4444).length, hub.VIEWING_KEY_LENGTH());
    }

    // ---------------------------------------------------------------------
    // L1 -> domain
    // ---------------------------------------------------------------------

    function test_sendL1Message_rejectsUnregisteredDomain() public {
        vm.expectRevert(DomainHub.DomainNotRegistered.selector);
        hub.sendL1Message(9999, bob, hex"01");
    }

    function test_sendL1Message_recordsHashAndEmitsPreimage() public {
        bytes memory data = MessageLib.encodeTransfer(bob, address(0x1234), 100 ether);
        bytes32 expectedHash = MessageLib.hashMessage(
            MessageLib.Message({sourceChainId: uint64(block.chainid), from: alice, to: bob, data: data, nonce: 0})
        );

        vm.expectEmit(address(hub));
        emit IDomainHub.L1MessageRecorded(
            CHAIN_ID, uint64(block.chainid), alice, bob, data, 0, DELIVERY_FEE, expectedHash
        );
        vm.prank(alice);
        hub.sendL1Message{value: DELIVERY_FEE}(CHAIN_ID, bob, data);

        assertEq(hub.l1MessageCounts(CHAIN_ID), 1);
    }

    function test_sendL1Message_noncesArePerDomain() public {
        _register(4444, feeRecipient, "", 1);

        // Each domain assigns its own gapless nonce sequence, checked via the emitted
        // preimages.
        vm.expectEmit(address(hub));
        emit IDomainHub.L1MessageRecorded(
            CHAIN_ID,
            uint64(block.chainid),
            alice,
            bob,
            hex"01",
            0,
            DELIVERY_FEE,
            MessageLib.hashMessage(MessageLib.Message(uint64(block.chainid), alice, bob, hex"01", 0))
        );
        vm.prank(alice);
        hub.sendL1Message{value: DELIVERY_FEE}(CHAIN_ID, bob, hex"01");

        vm.expectEmit(address(hub));
        emit IDomainHub.L1MessageRecorded(
            4444,
            uint64(block.chainid),
            alice,
            bob,
            hex"01",
            0,
            DELIVERY_FEE,
            MessageLib.hashMessage(MessageLib.Message(uint64(block.chainid), alice, bob, hex"01", 0))
        );
        vm.prank(alice);
        hub.sendL1Message{value: DELIVERY_FEE}(4444, bob, hex"01");

        vm.expectEmit(address(hub));
        emit IDomainHub.L1MessageRecorded(
            CHAIN_ID,
            uint64(block.chainid),
            alice,
            bob,
            hex"01",
            1,
            DELIVERY_FEE,
            MessageLib.hashMessage(MessageLib.Message(uint64(block.chainid), alice, bob, hex"01", 1))
        );
        vm.prank(alice);
        hub.sendL1Message{value: DELIVERY_FEE}(CHAIN_ID, bob, hex"01");

        assertEq(hub.l1MessageCounts(CHAIN_ID), 2);
        assertEq(hub.l1MessageCounts(4444), 1);
    }

    function test_sendL1Message_forwardsFeeAndRecordsIt() public {
        _register(4444, feeRecipient, "", 1);

        vm.expectEmit(address(hub));
        emit IDomainHub.L1MessageRecorded(
            4444,
            uint64(block.chainid),
            alice,
            bob,
            hex"01",
            0,
            0.05 ether,
            MessageLib.hashMessage(MessageLib.Message(uint64(block.chainid), alice, bob, hex"01", 0))
        );
        vm.prank(alice);
        hub.sendL1Message{value: 0.05 ether}(4444, bob, hex"01");

        assertEq(feeRecipient.balance, 0.05 ether);
        assertEq(address(hub).balance, 0);
    }

    function test_sendViewingKey_recordsAHubMessageToTheSpoke() public {
        _registerKeyedDomain(hub, 8888, K1);
        bytes memory data = MessageLib.encodeViewingKey(8888, hub.viewingKeys(8888));
        MessageLib.Message memory message =
            MessageLib.Message(uint64(block.chainid), address(hub), address(spoke), data, 0);

        vm.expectEmit(address(hub));
        emit IDomainHub.L1MessageRecorded(
            CHAIN_ID,
            uint64(block.chainid),
            address(hub),
            address(spoke),
            data,
            0,
            DELIVERY_FEE,
            MessageLib.hashMessage(message)
        );
        vm.deal(stranger, 1 ether);
        vm.prank(stranger); // anyone may push a key, paying its delivery
        hub.sendViewingKey{value: DELIVERY_FEE}(CHAIN_ID, address(spoke), 8888);
        assertEq(hub.l1MessageCounts(CHAIN_ID), 1);
    }

    function test_sendViewingKey_rejectsUnregisteredDomainMissingKeyAndLowFee() public {
        _register(4444, feeRecipient, "", 1);
        _registerKeyedDomain(hub, 8888, K1);
        vm.expectRevert(DomainHub.DomainNotRegistered.selector);
        hub.sendViewingKey{value: DELIVERY_FEE}(9999, address(spoke), 8888);
        vm.expectRevert(DomainHub.NoViewingKey.selector);
        hub.sendViewingKey{value: DELIVERY_FEE}(CHAIN_ID, address(spoke), 4444); // registered without a key
        vm.expectRevert(DomainHub.NoViewingKey.selector);
        hub.sendViewingKey{value: DELIVERY_FEE}(CHAIN_ID, address(spoke), 9999); // not registered
        uint256 minimum = hub.minDeliveryFee(MessageLib.encodeViewingKey(8888, hub.viewingKeys(8888)).length);
        vm.expectRevert(DomainHub.DeliveryFeeTooLow.selector);
        hub.sendViewingKey{value: minimum - 1}(CHAIN_ID, address(spoke), 8888);
        assertEq(hub.l1MessageCounts(CHAIN_ID), 0);
        hub.sendViewingKey{value: minimum}(CHAIN_ID, address(spoke), 8888);
        assertEq(hub.l1MessageCounts(CHAIN_ID), 1);
    }

    function test_sendL1Message_revertsIfFeeRecipientRejectsFee() public {
        _register(4444, address(new RejectingFeeRecipient()), "", 1);

        vm.prank(alice);
        vm.expectRevert(DomainHub.FeeTransferFailed.selector);
        hub.sendL1Message{value: DELIVERY_FEE}(4444, bob, hex"01");
    }

    function test_sendL1Message_rejectsFeeBelowMinimum() public {
        bytes memory data = new bytes(300);
        uint256 minimum = hub.minDeliveryFee(data.length);
        assertEq(minimum, (200_000 + 48 * 300) * hub.DOMAIN_GAS_PRICE());

        vm.prank(alice);
        vm.expectRevert(DomainHub.DeliveryFeeTooLow.selector);
        hub.sendL1Message{value: minimum - 1}(CHAIN_ID, bob, data);
        assertEq(hub.l1MessageCounts(CHAIN_ID), 0);

        vm.prank(alice);
        hub.sendL1Message{value: minimum}(CHAIN_ID, bob, data);
        assertEq(hub.l1MessageCounts(CHAIN_ID), 1);
    }

    // ---------------------------------------------------------------------
    // Spoke deployment
    // ---------------------------------------------------------------------

    function test_spokeConstructorRejectsInvalidBindings() public {
        vm.expectRevert(DomainSpoke.ZeroHub.selector);
        new DomainSpoke(CHAIN_ID, block.chainid, address(0));
        vm.expectRevert(DomainSpoke.DomainIsL1.selector);
        new DomainSpoke(uint64(block.chainid), block.chainid, address(hub));
        vm.expectRevert(DomainSpoke.L1ChainIdTooLarge.selector);
        new DomainSpoke(CHAIN_ID, uint256(type(uint64).max) + 1, address(hub));
    }

    // ---------------------------------------------------------------------
    // Protocol delivery of L1 messages
    // ---------------------------------------------------------------------

    function test_relayL1Message_onlySystemRelayer() public {
        vm.prank(stranger);
        vm.expectRevert(DomainSpoke.NotSystemRelayer.selector);
        spoke.relayL1Message(uint64(block.chainid), alice, bob, hex"01", 0);
    }

    function test_relayL1Message_deliversInOrder() public {
        RecordingReceiver receiver = new RecordingReceiver();

        vm.startPrank(spoke.SYSTEM_RELAYER());
        spoke.relayL1Message(uint64(block.chainid), alice, address(receiver), hex"01", 0);
        spoke.relayL1Message(uint64(block.chainid), bob, address(receiver), hex"02", 1);
        vm.stopPrank();

        assertEq(spoke.nextL1Nonce(), 2);
        assertEq(receiver.callCount(), 2);
        assertEq(receiver.lastSource(), block.chainid);
        assertEq(receiver.lastFrom(), bob);
        assertEq(receiver.lastData(), hex"02");
    }

    function test_relayL1Message_rejectsReplayedOrRegressedNonce() public {
        vm.startPrank(spoke.SYSTEM_RELAYER());
        spoke.relayL1Message(uint64(block.chainid), alice, bob, hex"01", 3);

        // Nonces are strictly increasing: a delivered nonce cannot be replayed and no earlier
        // nonce can be delivered afterwards.
        vm.expectRevert(DomainSpoke.OutOfOrderNonce.selector);
        spoke.relayL1Message(uint64(block.chainid), alice, bob, hex"01", 3);
        vm.expectRevert(DomainSpoke.OutOfOrderNonce.selector);
        spoke.relayL1Message(uint64(block.chainid), alice, bob, hex"02", 1);
        vm.stopPrank();
    }

    function test_relayL1Message_marksFailedAndAdvancesQueue() public {
        RecordingReceiver receiver = new RecordingReceiver();
        receiver.setRejecting(true);
        MessageLib.Message memory message =
            MessageLib.Message(uint64(block.chainid), alice, address(receiver), hex"01", 0);
        bytes32 messageHash = MessageLib.hashMessage(message);

        vm.expectEmit(address(spoke));
        emit IDomainSpoke.L1MessageRelayed(messageHash, uint64(block.chainid), alice, address(receiver), 0, false);
        vm.prank(spoke.SYSTEM_RELAYER());
        spoke.relayL1Message(uint64(block.chainid), alice, address(receiver), hex"01", 0);

        // The failure is recorded and the queue moved past it.
        assertTrue(spoke.failedL1Messages(messageHash));
        assertEq(receiver.callCount(), 0);
        assertEq(spoke.nextL1Nonce(), 1);

        // Retry fails while the target still rejects; the failed mark is retained.
        vm.expectRevert(DomainSpoke.RetryFailed.selector);
        spoke.retryL1Message(message);
        assertTrue(spoke.failedL1Messages(messageHash));

        // Once the target accepts, anyone can re-execute the delivery.
        receiver.setRejecting(false);
        vm.expectEmit(address(spoke));
        emit IDomainSpoke.L1MessageRelayed(messageHash, uint64(block.chainid), alice, address(receiver), 0, true);
        vm.prank(stranger);
        spoke.retryL1Message(message);
        assertFalse(spoke.failedL1Messages(messageHash));
        assertEq(receiver.callCount(), 1);
        assertEq(receiver.lastSource(), block.chainid);
        assertEq(receiver.lastFrom(), alice);

        // A retried message cannot be replayed.
        vm.expectRevert(DomainSpoke.NotFailedMessage.selector);
        spoke.retryL1Message(message);
    }

    function test_relayL1Message_gapSkipsUndeliverableNonce() public {
        RecordingReceiver receiver = new RecordingReceiver();

        // Nonce 1 is an undecryptable encrypted message: the client never delivers it, and
        // the delivery of nonce 2 consumes the gap.
        vm.startPrank(spoke.SYSTEM_RELAYER());
        spoke.relayL1Message(uint64(block.chainid), alice, address(receiver), hex"01", 0);
        spoke.relayL1Message(uint64(block.chainid), bob, address(receiver), hex"02", 2);
        vm.stopPrank();

        assertEq(spoke.nextL1Nonce(), 3);
        assertEq(receiver.callCount(), 2);

        // The skipped nonce is consumed for good: it cannot be delivered afterwards.
        vm.prank(spoke.SYSTEM_RELAYER());
        vm.expectRevert(DomainSpoke.OutOfOrderNonce.selector);
        spoke.relayL1Message(uint64(block.chainid), alice, address(receiver), hex"03", 1);
    }

    function test_relayL1Message_forwardsAllButTheReserve() public {
        GasMeteringReceiver receiver = new GasMeteringReceiver();
        uint256 reserve = spoke.DELIVERY_GAS_RESERVE();

        // The target gets everything the system transaction's gas limit holds beyond the
        // spoke's own work and the reserve, whatever the limit is.
        for (uint256 i = 0; i < 2; i++) {
            uint256 limit = (i + 1) * 1_000_000;
            vm.prank(spoke.SYSTEM_RELAYER());
            spoke.relayL1Message{gas: limit}(uint64(block.chainid), alice, address(receiver), hex"01", i);
            assertGt(receiver.lastGas(), limit - reserve - 100_000);
            assertLt(receiver.lastGas(), limit - reserve);
        }
    }

    function test_relayL1Message_reserveSurvivesLargePayloadAndReturnBomb() public {
        bytes memory data = new bytes(32_768);
        uint256 gas = hub.DELIVERY_BASE_GAS() + hub.DELIVERY_GAS_PER_BYTE() * data.length;
        address[2] memory targets = [address(new GasExhaustingReceiver()), address(new ReturnBombReceiver())];

        for (uint256 i = 0; i < targets.length; i++) {
            bytes32 messageHash =
                MessageLib.hashMessage(MessageLib.Message(uint64(block.chainid), alice, targets[i], data, i));
            vm.expectEmit(address(spoke));
            emit IDomainSpoke.L1MessageRelayed(messageHash, uint64(block.chainid), alice, targets[i], i, false);
            vm.prank(spoke.SYSTEM_RELAYER());
            spoke.relayL1Message{gas: gas}(uint64(block.chainid), alice, targets[i], data, i);
            assertTrue(spoke.failedL1Messages(messageHash));
        }
        assertEq(spoke.nextL1Nonce(), 2);
    }

    function test_relayL1Message_revertsWhenTheFeeDoesNotCoverTheReserve() public {
        RecordingReceiver receiver = new RecordingReceiver();

        vm.prank(spoke.SYSTEM_RELAYER());
        vm.expectRevert();
        spoke.relayL1Message{gas: 70_000}(uint64(block.chainid), alice, address(receiver), hex"01", 0);
        assertEq(spoke.nextL1Nonce(), 0);
    }

    function test_onDomainMessage_storesKeysOnlyFromHubDeliveries() public {
        _registerKeyedDomain(hub, 8888, K1);
        bytes memory key = hub.viewingKeys(8888);
        bytes memory data = MessageLib.encodeViewingKey(8888, key);

        // Not a delivery: a direct call, even from the hub's address.
        vm.prank(address(hub));
        vm.expectRevert(DomainSpoke.NotDelivery.selector);
        spoke.onDomainMessage(uint64(block.chainid), address(hub), data);

        // Deliveries not from the hub on the L1 fail and store nothing.
        vm.startPrank(spoke.SYSTEM_RELAYER());
        spoke.relayL1Message(uint64(block.chainid), alice, address(spoke), data, 0);
        spoke.relayL1Message(8888, address(hub), address(spoke), data, 1);
        vm.stopPrank();
        assertEq(spoke.viewingKeys(8888), "");
        assertTrue(
            spoke.failedL1Messages(
                MessageLib.hashMessage(MessageLib.Message(uint64(block.chainid), alice, address(spoke), data, 0))
            )
        );
        assertTrue(
            spoke.failedL1Messages(
                MessageLib.hashMessage(MessageLib.Message(8888, address(hub), address(spoke), data, 1))
            )
        );

        // The hub's own message stores the key.
        vm.expectEmit(address(spoke));
        emit IDomainSpoke.ViewingKeySet(8888, key);
        vm.prank(spoke.SYSTEM_RELAYER());
        spoke.relayL1Message(uint64(block.chainid), address(hub), address(spoke), data, 2);
        assertEq(spoke.viewingKeys(8888), key);
        assertEq(spoke.nextL1Nonce(), 3);
    }

    /// @dev The encryption precompile reads this slot directly from state.
    function test_viewingKeyStorageSlot() public {
        _registerKeyedDomain(hub, 8888, K1);
        _deliverViewingKey(hub, spoke, 8888);
        bytes memory key = hub.viewingKeys(8888);
        bytes32 slot = keccak256(abi.encode(uint256(8888), uint256(7)));
        // A 32-byte value is stored in the long form: the slot holds 2 * length + 1 and the
        // bytes start at keccak256(slot).
        assertEq(vm.load(address(spoke), slot), bytes32(uint256(key.length * 2 + 1)));
        bytes32 firstWord;
        assembly {
            firstWord := mload(add(key, 32))
        }
        assertEq(vm.load(address(spoke), keccak256(abi.encode(slot))), firstWord);
    }

    function test_retryL1Message_rejectsUnknownMessage() public {
        vm.expectRevert(DomainSpoke.NotFailedMessage.selector);
        spoke.retryL1Message(MessageLib.Message(uint64(block.chainid), alice, bob, hex"01", 0));
    }

    // ---------------------------------------------------------------------
    // Domain -> L1 or domain
    // ---------------------------------------------------------------------

    function test_sendDomainMessage_recordsIdByNonceAndEmitsPreimage() public {
        MessageLib.DomainMessage memory message = MessageLib.DomainMessage(
            MessageLib.MessageKind.Plain, CHAIN_ID, uint64(block.chainid), alice, bob, 0, TEST_SALT, hex"cafe"
        );
        bytes32 expectedHash = MessageLib.hashDomainMessage(message, block.chainid, address(hub));

        vm.expectEmit(address(spoke));
        emit IDomainSpoke.DomainMessageRecorded(expectedHash, abi.encode(message));
        vm.prank(alice);
        bytes32 messageId = spoke.sendDomainMessage(uint64(block.chainid), bob, hex"cafe", TEST_SALT);

        assertEq(messageId, expectedHash);
        assertEq(spoke.domainMessageCount(), 1);
        assertEq(spoke.domainMessageIds(0), expectedHash);
    }

    function test_domainMessageIds_storedByNonce() public {
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            spoke.sendDomainMessage(uint64(block.chainid), bob, abi.encodePacked(i), TEST_SALT);
        }
        assertEq(spoke.domainMessageCount(), 5);

        // Each id is the hash of its envelope, keyed by nonce; an unrecorded nonce reads zero.
        bytes32[] memory ids = _batchLeaves(spoke, 0, 5);
        for (uint256 i = 0; i < 5; i++) {
            MessageLib.DomainMessage memory message = MessageLib.DomainMessage(
                MessageLib.MessageKind.Plain,
                CHAIN_ID,
                uint64(block.chainid),
                alice,
                bob,
                i,
                TEST_SALT,
                abi.encodePacked(i)
            );
            assertEq(ids[i], MessageLib.hashDomainMessage(message, block.chainid, address(hub)));
        }
        assertEq(spoke.domainMessageIds(5), bytes32(0));
    }

    function test_sendDomainMessage_sealsDomainBoundMessagesThroughThePrecompile() public {
        _registerKeyedDomain(hub, 8888, K1);
        _deliverViewingKey(hub, spoke, 8888);
        // No sender, target or salt; the data is (alice, bob, 0xcafe) sealed by this spoke for
        // 8888 under nonce 0 with 8888's key, as the mock seals it.
        bytes memory ciphertext = abi.encode(
            address(spoke),
            uint64(8888),
            uint256(0),
            keccak256(hub.viewingKeys(8888)),
            MessageLib.encodePlaintext(alice, bob, hex"cafe")
        );
        MessageLib.DomainMessage memory message = MessageLib.DomainMessage(
            MessageLib.MessageKind.Encrypted, CHAIN_ID, 8888, address(0), address(0), 0, bytes32(0), ciphertext
        );
        bytes32 expectedHash = MessageLib.hashDomainMessage(message, block.chainid, address(hub));

        vm.expectEmit(address(spoke));
        emit IDomainSpoke.DomainMessageRecorded(expectedHash, abi.encode(message));
        vm.prank(alice);
        bytes32 messageId = spoke.sendDomainMessage(8888, bob, hex"cafe", TEST_SALT);

        assertEq(messageId, expectedHash);
        assertEq(spoke.domainMessageIds(0), expectedHash);
        assertEq(precompile.seals(), 1);
        assertEq(spoke.ENCRYPTION_PRECOMPILE(), address(precompile));
    }

    function test_sendDomainMessage_requiresSaltOnlyForTheL1() public {
        _registerKeyedDomain(hub, 8888, K1);
        _deliverViewingKey(hub, spoke, 8888);
        vm.startPrank(alice);
        vm.expectRevert(DomainSpoke.ZeroSalt.selector);
        spoke.sendDomainMessage(uint64(block.chainid), bob, hex"cafe", bytes32(0));
        spoke.sendDomainMessage(8888, bob, hex"cafe", bytes32(0));
        vm.stopPrank();
        assertEq(spoke.domainMessageCount(), 1);
    }

    function test_sendDomainMessage_rejectsDestinationWithoutViewingKey() public {
        vm.prank(alice);
        vm.expectRevert("MockDomainEncryption: unknown viewing key");
        spoke.sendDomainMessage(8888, bob, hex"cafe", TEST_SALT);
        assertEq(spoke.domainMessageCount(), 0);
        assertEq(precompile.seals(), 0);
    }

    // ---------------------------------------------------------------------
    // L1-sequenced domain transactions
    // ---------------------------------------------------------------------

    function test_sequenceToDomain_forwardsFeeAndEmits() public {
        _register(4444, feeRecipient, "", 1);

        vm.expectEmit(address(hub));
        emit IDomainHub.DomainTransactionSequenced(4444, hex"c0ffee", 0.1 ether);
        vm.prank(alice);
        hub.sequenceToDomain{value: 0.1 ether}(4444, hex"c0ffee");

        assertEq(feeRecipient.balance, 0.1 ether);
        assertEq(address(hub).balance, 0);
    }

    function test_domainBlockGasLimit_boundsEveryDomainPerL1Block() public {
        _register(4444, feeRecipient, "", 1);
        uint256 price = hub.DOMAIN_GAS_PRICE();
        uint256 cap = hub.DOMAIN_BLOCK_GAS_LIMIT();

        // Sequencing and messages draw from one budget per domain and L1 block.
        vm.prank(alice);
        hub.sequenceToDomain{value: (cap - 300_000) * price}(CHAIN_ID, hex"c0ffee");
        vm.prank(alice);
        hub.sendL1Message{value: 300_000 * price}(CHAIN_ID, bob, hex"01");
        (uint64 blockNumber, uint192 gasSold) = hub.blockGas(CHAIN_ID);
        assertEq(blockNumber, block.number);
        assertEq(gasSold, cap);
        vm.prank(alice);
        vm.expectRevert(DomainHub.DomainBlockGasLimitExceeded.selector);
        hub.sequenceToDomain{value: _sequencingFee(3)}(CHAIN_ID, hex"c0ffee");
        vm.prank(alice);
        vm.expectRevert(DomainHub.DomainBlockGasLimitExceeded.selector);
        hub.sendL1Message{value: 300_000 * price}(CHAIN_ID, bob, hex"01");

        // Other domains and later blocks have their own budgets.
        vm.prank(alice);
        hub.sendL1Message{value: 300_000 * price}(4444, bob, hex"01");
        vm.roll(block.number + 1);
        vm.prank(alice);
        hub.sequenceToDomain{value: cap * price}(CHAIN_ID, hex"c0ffee");
        (, gasSold) = hub.blockGas(CHAIN_ID);
        assertEq(gasSold, cap);
    }

    function test_sequenceToDomain_rejectsAFeeBelowTheMinimum() public {
        // A transaction's intrinsic gas plus 10 per payload byte, at the domain gas price.
        uint256 minimum = hub.minSequencingFee(3);
        assertEq(minimum, (21_000 + 10 * 3) * hub.DOMAIN_GAS_PRICE());
        assertEq(minimum, _sequencingFee(3));

        vm.startPrank(alice);
        vm.expectRevert(DomainHub.SequencingFeeTooLow.selector);
        hub.sequenceToDomain(CHAIN_ID, hex"c0ffee");
        vm.expectRevert(DomainHub.SequencingFeeTooLow.selector);
        hub.sequenceToDomain{value: minimum - 1}(CHAIN_ID, hex"c0ffee");
        hub.sequenceToDomain{value: minimum}(CHAIN_ID, hex"c0ffee");
        // The same fee does not cover a longer payload.
        vm.expectRevert(DomainHub.SequencingFeeTooLow.selector);
        hub.sequenceToDomain{value: minimum}(CHAIN_ID, hex"c0ffee00");
        vm.stopPrank();
    }

    function test_sequenceToDomain_rejectsUnregisteredDomain() public {
        vm.expectRevert(DomainHub.DomainNotRegistered.selector);
        hub.sequenceToDomain(9999, hex"01");
    }

    function test_sequenceToDomain_revertsIfFeeRecipientRejectsFee() public {
        address rejecting = address(new RejectingFeeRecipient());
        _register(4444, rejecting, "", 1);

        vm.prank(alice);
        vm.expectRevert(DomainHub.FeeTransferFailed.selector);
        hub.sequenceToDomain{value: 0.1 ether}(4444, hex"01");
    }
}

/// @dev Fee recipient without a payable fallback: any fee forwarded to it reverts.
contract RejectingFeeRecipient {}

/// @dev Records the gas it was called with.
contract GasMeteringReceiver is IDomainMessageReceiver {
    uint256 public lastGas;

    function onDomainMessage(uint64, address, bytes calldata) external {
        lastGas = gasleft();
    }
}

/// @dev Burns every unit of gas it is given.
contract GasExhaustingReceiver is IDomainMessageReceiver {
    function onDomainMessage(uint64, address, bytes calldata) external pure {
        assembly {
            invalid()
        }
    }
}

/// @dev Reverts with far more return data than the caller could afford to copy.
contract ReturnBombReceiver is IDomainMessageReceiver {
    function onDomainMessage(uint64, address, bytes calldata) external pure {
        assembly {
            revert(0, 0x40000)
        }
    }
}

/// @dev Receiver that records what the spoke delivers, with a toggleable rejection mode to
/// exercise the failed-delivery path.
contract RecordingReceiver is IDomainMessageReceiver {
    uint256 public callCount;
    uint64 public lastSource;
    address public lastFrom;
    bytes public lastData;

    bool internal _rejecting;

    function setRejecting(bool rejecting) external {
        _rejecting = rejecting;
    }

    function onDomainMessage(uint64 sourceChainId, address from, bytes calldata data) external {
        require(!_rejecting, "RecordingReceiver: rejecting");
        callCount++;
        lastSource = sourceChainId;
        lastFrom = from;
        lastData = data;
    }
}
