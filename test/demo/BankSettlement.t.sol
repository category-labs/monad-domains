// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DomainHub} from "../../src/DomainHub.sol";
import {DomainSpoke} from "../../src/DomainSpoke.sol";
import {IDomainHub, IDomainSpoke} from "../../src/interfaces/IDomain.sol";
import {BridgedERC20} from "../../src/bridge/BridgedERC20.sol";
import {DemoDomainBridge} from "../../src/demo/DemoDomainBridge.sol";
import {DemoL1Bridge} from "../../src/demo/DemoL1Bridge.sol";
import {DemoLedger} from "../../src/demo/DemoLedger.sol";
import {L2Bank} from "../../src/demo/L2Bank.sol";
import {LockingLiquidityPool} from "../../src/demo/LockingLiquidityPool.sol";
import {MessageLib} from "../../src/libraries/MessageLib.sol";
import {DomainTestBase} from "../helpers/DomainTestBase.sol";
import {MerkleTreeLib} from "../helpers/MerkleTreeLib.sol";

/// @notice The bank demo end to end: a customer of Bank A (EUR, domain A) pays a customer of
/// Bank B (USD, domain B) through the L1 liquidity pool. The test plays the protocol (the
/// encryption precompile, system deliveries with the gas their fee bought) and the relayer
/// (attest, prove, pay for forwarding); the banks and the pool do everything else - KYC round
/// trip, lock request, quote and payment - by messages.
/// forge-config: default.isolate = false
contract BankSettlementTest is DomainTestBase {
    uint64 internal constant CHAIN_A = 7777;
    uint64 internal constant CHAIN_B = 8888;
    uint256 internal constant VALIDATOR_KEY = 0xA11CE;
    uint256 internal constant RATE_NUM = 12;
    uint256 internal constant RATE_DEN = 10;
    uint256 internal constant DEPOSIT = 500 ether;
    uint256 internal constant AMOUNT_OUT = 60 ether; // $60
    uint256 internal constant AMOUNT_IN = 50 ether; // costs 50 EUR at 1.2
    uint256 internal constant LIMIT_A = 2_000 ether; // alice's limit at Bank A
    uint256 internal constant POOL_FUNDS = 10 ether; // native token the pool pays its deliveries from

    /// @dev A delivery the hub recorded for `domainChainId`, as that domain's client derives it,
    /// and the fee that sets its gas limit.
    struct Delivery {
        uint64 domainChainId;
        MessageLib.Message message;
        uint256 fee;
    }

    uint64 internal immutable L1 = uint64(block.chainid);

    DomainHub internal hub;
    DomainSpoke internal spokeA;
    DomainSpoke internal spokeB;
    DemoLedger internal eur;
    DemoLedger internal usd;
    DemoL1Bridge internal l1BridgeA;
    DemoL1Bridge internal l1BridgeB;
    DemoDomainBridge internal nsBridgeA;
    DemoDomainBridge internal nsBridgeB;
    LockingLiquidityPool internal pool;
    L2Bank internal bankA;
    L2Bank internal bankB;

    address internal bankOp = makeAddr("bankOperator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        hub = _deployHub(address(this));
        _registerKeyedDomain(hub, CHAIN_A, VALIDATOR_KEY);
        _registerKeyedDomain(hub, CHAIN_B, VALIDATOR_KEY);
        spokeA = new DomainSpoke(CHAIN_A, block.chainid, address(hub));
        spokeB = new DomainSpoke(CHAIN_B, block.chainid, address(hub));
        // The banks seal their messages to each other's domain.
        _installEncryptionPrecompile();
        _deliverViewingKey(hub, spokeA, CHAIN_B);
        _deliverViewingKey(hub, spokeB, CHAIN_A);

        eur = new DemoLedger("Demo Euro", "EUR");
        usd = new DemoLedger("Demo Dollar", "USD");
        l1BridgeA = new DemoL1Bridge(hub, CHAIN_A);
        l1BridgeB = new DemoL1Bridge(hub, CHAIN_B);
        nsBridgeA = new DemoDomainBridge(spokeA, address(l1BridgeA), address(this), address(0));
        nsBridgeB = new DemoDomainBridge(spokeB, address(l1BridgeB), address(this), address(0));
        l1BridgeA.registerDomainBridge(address(nsBridgeA));
        l1BridgeB.registerDomainBridge(address(nsBridgeB));
        l1BridgeA.setTokenAllowed(address(eur), true);
        l1BridgeB.setTokenAllowed(address(usd), true);

        pool = new LockingLiquidityPool(eur, usd, RATE_NUM, RATE_DEN, l1BridgeA, l1BridgeB, 600);
        usd.mint(address(pool), 30_000 ether);
        _fundPool(POOL_FUNDS);

        bankA = new L2Bank(spokeA, nsBridgeA, address(eur), address(pool), RATE_NUM, RATE_DEN, bankOp);
        bankB = new L2Bank(spokeB, nsBridgeB, address(usd), address(pool), RATE_NUM, RATE_DEN, bankOp);
        pool.setPayerBank(address(bankA));
        vm.startPrank(bankOp);
        bankA.registerPeer(CHAIN_B, address(bankB));
        bankB.registerPeer(CHAIN_A, address(bankA));
        bankA.setTierLimit(1, LIMIT_A);
        bankA.setKycTier(alice, 1);
        bankB.setReceiveAllowance(bob, 1_000 ether);
        vm.stopPrank();

        // Alice funds her Bank A account: EUR locked on the L1, delivered to domain A.
        eur.mint(alice, DEPOSIT);
        vm.deal(alice, 1 ether);
        vm.recordLogs();
        vm.startPrank(alice);
        eur.approve(address(l1BridgeA), DEPOSIT);
        l1BridgeA.bridgeToDomain{value: DELIVERY_FEE}(alice, address(eur), DEPOSIT);
        vm.stopPrank();
        Delivery memory deposit = _recordedDelivery();
        _assertDelivery(
            deposit,
            CHAIN_A,
            L1,
            address(l1BridgeA),
            address(nsBridgeA),
            MessageLib.encodeTransfer(alice, address(eur), DEPOSIT)
        );
        _deliver(deposit);
        assertEq(_ledgerA().balanceOf(alice), DEPOSIT);
    }

    // ---------------------------------------------------------------------
    // Flows
    // ---------------------------------------------------------------------

    function test_paymentSettlesThroughThePool() public {
        uint256 requestId = _fileOrder(false);
        assertEq(bankA.receiveAllowance(alice), LIMIT_A - AMOUNT_IN, "limit reserved at filing");
        MessageLib.DomainMessage[] memory lockRequests = _kycRoundTrip(requestId, true);

        // Bank A asked the pool for the lock in the transaction that delivered the KYC reply.
        assertEq(lockRequests.length, 1, "lock request sent");
        assertEq(lockRequests[0].destinationChainId, block.chainid);
        assertEq(lockRequests[0].from, address(bankA));
        assertEq(lockRequests[0].to, address(pool));
        assertTrue(lockRequests[0].salt != bytes32(0), "L1-bound sends are salted");
        assertEq(lockRequests[0].data, abi.encode(uint8(3), requestId, AMOUNT_OUT, bob, alice, false));

        // The pool locks while the request is delivered and quotes; the quote pays the pool.
        (uint256 lockId, MessageLib.DomainMessage[] memory payments) = _lockRoundTrip(requestId, lockRequests);
        (uint256 quote,,,,,) = pool.locks(lockId);
        assertEq(quote, AMOUNT_IN);
        assertEq(pool.lockedOut(), AMOUNT_OUT);
        (,,, uint256 amountIn,, L2Bank.RequestStatus status, uint256 storedLock) = bankA.requests(requestId);
        assertEq(uint8(status), uint8(L2Bank.RequestStatus.Paid));
        assertEq(storedLock, lockId);
        assertEq(amountIn, AMOUNT_IN);
        assertEq(bankA.receiveAllowance(alice), LIMIT_A - AMOUNT_IN, "alice's limit stays drawn down");

        // Relayer: the withdrawal reaches the L1 and settles the lock in the same transaction.
        assertEq(payments.length, 1);
        assertTrue(payments[0].salt != bytes32(0) && payments[0].salt != lockRequests[0].salt, "a salt per send");
        Delivery memory payout = _relayBatch(spokeA, payments);
        assertEq(eur.balanceOf(address(pool)), AMOUNT_IN, "pool received the EUR");
        assertEq(eur.balanceOf(address(l1BridgeA)), DEPOSIT - AMOUNT_IN, "EUR collateral released");
        assertEq(usd.balanceOf(address(l1BridgeB)), AMOUNT_OUT, "USD locked for domain B");
        assertEq(usd.balanceOf(address(pool)), 30_000 ether - AMOUNT_OUT);
        assertEq(pool.lockedOut(), 0);
        (,,,,, LockingLiquidityPool.LockState state) = pool.locks(lockId);
        assertEq(uint8(state), uint8(LockingLiquidityPool.LockState.Settled));

        // The pool paid for both of its deliveries: the quote and the payout.
        assertEq(payout.fee, pool.deliveryFee(96));
        assertEq(address(pool).balance, POOL_FUNDS - pool.deliveryFee(128) - pool.deliveryFee(96));

        // Protocol: the USD deposit lands on domain B.
        _assertDelivery(
            payout,
            CHAIN_B,
            L1,
            address(l1BridgeB),
            address(nsBridgeB),
            MessageLib.encodeTransfer(bob, address(usd), AMOUNT_OUT)
        );
        _deliver(payout);
        assertEq(nsBridgeB.bridgedTokens(address(usd)).balanceOf(bob), AMOUNT_OUT, "bob paid at Bank B");
        assertEq(_ledgerA().balanceOf(alice), DEPOSIT - AMOUNT_IN, "alice charged at Bank A");
        assertEq(bankB.receiveAllowance(bob), 1_000 ether - AMOUNT_OUT, "KYC allowance consumed");
    }

    function test_expiredLockRefundsTheCustomer() public {
        uint256 requestId = _fileOrder(true);
        (uint256 lockId, MessageLib.DomainMessage[] memory payments) =
            _lockRoundTrip(requestId, _kycRoundTrip(requestId, true));
        (,,,, uint64 expiry,) = pool.locks(lockId);
        assertEq(expiry, 0, "born expired");
        assertEq(bankA.receiveAllowance(alice), LIMIT_A, "a refunded payment leaves the limit alone");
        Delivery memory refund = _relayBatch(spokeA, payments);

        // The pool took the EUR and immediately bridged it back toward alice on domain A.
        assertEq(eur.balanceOf(address(pool)), 0);
        assertEq(eur.balanceOf(address(l1BridgeA)), DEPOSIT, "EUR re-locked for the refund");
        assertEq(usd.balanceOf(address(l1BridgeB)), 0, "no USD moved");
        assertEq(pool.lockedOut(), 0);
        (,,,,, LockingLiquidityPool.LockState state) = pool.locks(lockId);
        assertEq(uint8(state), uint8(LockingLiquidityPool.LockState.Refunded));

        _assertDelivery(
            refund,
            CHAIN_A,
            L1,
            address(l1BridgeA),
            address(nsBridgeA),
            MessageLib.encodeTransfer(alice, address(eur), AMOUNT_IN)
        );
        assertEq(refund.fee, pool.deliveryFee(96), "the pool paid for the refund's delivery");
        _deliver(refund);
        assertEq(_ledgerA().balanceOf(alice), DEPOSIT, "alice refunded at Bank A");
    }

    function test_kycDenialRefundsOnTheDomain() public {
        vm.prank(bankOp);
        bankB.setReceiveAllowance(bob, AMOUNT_OUT - 1);
        uint256 requestId = _fileOrder(false);
        assertEq(_ledgerA().balanceOf(alice), DEPOSIT - AMOUNT_IN, "custody taken at request time");
        MessageLib.DomainMessage[] memory lockRequests = _kycRoundTrip(requestId, false);
        assertEq(lockRequests.length, 0, "no lock requested");
        (,,,,, L2Bank.RequestStatus status,) = bankA.requests(requestId);
        assertEq(uint8(status), uint8(L2Bank.RequestStatus.Denied));
        assertEq(_ledgerA().balanceOf(alice), DEPOSIT, "custody returned");
        assertEq(bankA.receiveAllowance(alice), LIMIT_A, "alice's limit returned");
        assertEq(bankB.receiveAllowance(bob), AMOUNT_OUT - 1, "allowance untouched");
    }

    function test_poolWithoutLiquidityRefundsTheCustomer() public {
        pool.withdrawLiquidity(address(usd), address(this), usd.balanceOf(address(pool)));
        uint256 requestId = _fileOrder(false);
        MessageLib.DomainMessage[] memory lockRequests = _kycRoundTrip(requestId, true);

        Delivery memory answer = _relayBatch(spokeA, lockRequests);
        _assertDelivery(answer, CHAIN_A, L1, address(pool), address(bankA), abi.encode(uint8(5), requestId));
        assertEq(pool.nextLockId(), 0);

        _deliver(answer);
        (,,,,, L2Bank.RequestStatus status,) = bankA.requests(requestId);
        assertEq(uint8(status), uint8(L2Bank.RequestStatus.Failed));
        assertEq(_ledgerA().balanceOf(alice), DEPOSIT, "custody returned");
        assertEq(bankA.receiveAllowance(alice), LIMIT_A);
    }

    function test_quoteOtherThanTheChargeRefunds() public {
        uint256 requestId = _fileOrder(false);
        _kycRoundTrip(requestId, true);
        _deliver(
            _l1Delivery(
                spokeA, address(pool), address(bankA), abi.encode(uint8(4), requestId, uint256(7), AMOUNT_IN + 1)
            )
        );
        (,,,,, L2Bank.RequestStatus status,) = bankA.requests(requestId);
        assertEq(uint8(status), uint8(L2Bank.RequestStatus.Failed));
        assertEq(_ledgerA().balanceOf(alice), DEPOSIT, "custody returned");
        assertEq(bankA.receiveAllowance(alice), LIMIT_A, "alice's limit returned");
    }

    function test_dailyLimitIsEnforced() public {
        vm.prank(bankOp);
        bankA.setTierLimit(1, AMOUNT_IN - 1);
        vm.prank(bankOp);
        bankA.setKycTier(alice, 1);
        vm.startPrank(alice);
        _ledgerA().approve(address(bankA), AMOUNT_IN);
        vm.expectRevert("L2Bank: over your daily limit");
        bankA.requestTransfer(bob, AMOUNT_OUT, false);
        vm.stopPrank();

        // Not onboarded at Bank A: no limit at all.
        address carol = makeAddr("carol");
        vm.prank(carol);
        vm.expectRevert("L2Bank: over your daily limit");
        bankA.requestTransfer(bob, AMOUNT_OUT, false);
    }

    function test_dailyLimitResetsAtMidnightUtc() public {
        vm.warp(10 days + 23 hours);
        uint256 requestId = _fileOrder(false);
        _lockRoundTrip(requestId, _kycRoundTrip(requestId, true));
        assertEq(bankA.receiveAllowance(alice), LIMIT_A - AMOUNT_IN, "used today");
        assertEq(bankB.receiveAllowance(bob), 1_000 ether - AMOUNT_OUT, "received today");

        vm.warp(11 days); // 00:00 UTC
        assertEq(bankA.receiveAllowance(alice), LIMIT_A, "a new day, the full limit");
        assertEq(bankB.receiveAllowance(bob), 1_000 ether, "a new day, the full limit");

        // Re-onboarding does not top up a day's limit.
        uint256 second = _fileOrder(false);
        vm.prank(bankOp);
        bankA.setKycTier(alice, 1);
        assertEq(bankA.receiveAllowance(alice), LIMIT_A - AMOUNT_IN);
        assertEq(bankA.requestDay(second), 11);
    }

    function test_refundOnALaterDayGivesNoExtraLimit() public {
        vm.warp(10 days + 23 hours);
        uint256 requestId = _fileOrderTo(makeAddr("stranger")); // Bank B never verified this address
        assertEq(bankA.receiveAllowance(alice), LIMIT_A - AMOUNT_IN);

        // Yesterday's order is denied today: the € come back, and the delivery must not try to
        // hand back limit that no longer counts (nothing was used today).
        vm.warp(11 days);
        _kycRoundTrip(requestId, false);
        assertEq(_ledgerA().balanceOf(alice), DEPOSIT, "custody returned");
        assertEq(bankA.receiveAllowance(alice), LIMIT_A, "today's full limit, nothing extra");
        _fileOrder(false);
        assertEq(bankA.receiveAllowance(alice), LIMIT_A - AMOUNT_IN);
    }

    function test_kycTierSetsTheLimit() public {
        assertEq(bankA.kycTier(alice), 1);
        assertEq(bankA.receiveAllowance(alice), LIMIT_A);
        vm.startPrank(bankOp);
        bankA.setTierLimit(2, 25_000 ether);
        bankA.setKycTier(alice, 2);
        vm.stopPrank();
        assertEq(bankA.kycTier(alice), 2);
        assertEq(bankA.receiveAllowance(alice), 25_000 ether, "the tier's limit, reset");
        vm.expectRevert("L2Bank: not the bank");
        bankA.setKycTier(alice, 1);
        vm.expectRevert("L2Bank: not the bank");
        bankA.setTierLimit(1, 1);
    }

    function test_messagesAreGuarded() public {
        vm.expectRevert("LP: not the source bridge");
        pool.onBridgedTokens(address(eur), AMOUNT_IN, bytes32(0));

        bytes memory lockRequest = abi.encode(uint8(3), uint256(0), AMOUNT_OUT, bob, alice, false);
        vm.expectRevert("LP: not hub");
        pool.onDomainMessage(CHAIN_A, address(bankA), lockRequest);
        vm.prank(address(hub));
        vm.expectRevert("LP: not the payer bank");
        pool.onDomainMessage(CHAIN_A, alice, lockRequest);
        vm.prank(address(hub));
        vm.expectRevert("LP: not the payer bank");
        pool.onDomainMessage(CHAIN_B, address(bankA), lockRequest);

        vm.expectRevert("L2Bank: not spoke");
        bankA.onDomainMessage(CHAIN_B, address(bankB), abi.encode(uint8(2), uint256(0), true));
        // The pool's answers count only when they come from the pool's address on the L1.
        vm.prank(address(spokeA));
        vm.expectRevert("L2Bank: not the peer bank");
        bankA.onDomainMessage(CHAIN_B, address(pool), abi.encode(uint8(4), uint256(0), uint256(0), AMOUNT_IN));
    }

    function test_settlementFailureLeavesWithdrawalRetryable() public {
        uint256 requestId = _fileOrder(true); // born-expired lock
        (uint256 lockId, MessageLib.DomainMessage[] memory payments) =
            _lockRoundTrip(requestId, _kycRoundTrip(requestId, true));
        pool.cancelExpiredLock(lockId); // anyone may release an expired, unpaid lock
        assertEq(pool.lockedOut(), 0);

        (bytes32 anchor, bytes32[] memory leaves) = _attestPending(spokeA);

        // The hook reverts (lock no longer pending): nothing is released and the hub keeps
        // the message retryable instead of consuming it.
        assertFalse(hub.relayDomainMessage(payments[0], anchor, MerkleTreeLib.getProof(leaves, 0)));
        assertTrue(hub.failedDomainMessages(CHAIN_A, _hash(payments[0])));
        assertEq(eur.balanceOf(address(pool)), 0);
        assertEq(eur.balanceOf(address(l1BridgeA)), DEPOSIT);
        assertEq(usd.balanceOf(address(l1BridgeB)), 0);
        vm.expectRevert(DomainHub.RetryFailed.selector);
        hub.retryDomainMessage(payments[0]);
    }

    function test_unfundedPoolLeavesTheLockRequestRetryable() public {
        vm.deal(address(pool), 0);
        uint256 requestId = _fileOrder(false);
        MessageLib.DomainMessage[] memory lockRequests = _kycRoundTrip(requestId, true);
        (bytes32 anchor, bytes32[] memory leaves) = _attestPending(spokeA);

        // The pool cannot pay for its answer: the callback reverts and nothing is locked.
        assertFalse(hub.relayDomainMessage(lockRequests[0], anchor, MerkleTreeLib.getProof(leaves, 0)));
        assertTrue(hub.failedDomainMessages(CHAIN_A, _hash(lockRequests[0])));
        assertEq(pool.nextLockId(), 0);

        // Funded, the same request locks on retry.
        _fundPool(POOL_FUNDS);
        vm.recordLogs();
        hub.retryDomainMessage(lockRequests[0]);
        Delivery memory quote = _recordedDelivery();
        _assertDelivery(
            quote, CHAIN_A, L1, address(pool), address(bankA), abi.encode(uint8(4), requestId, uint256(0), AMOUNT_IN)
        );
        assertEq(pool.lockedOut(), AMOUNT_OUT);
        assertEq(address(pool).balance, POOL_FUNDS - quote.fee);
    }

    function test_deliveryGasSetsThePoolsFee() public {
        uint256 price = hub.DOMAIN_GAS_PRICE();
        assertEq(pool.deliveryGas(), 3_000_000);
        assertEq(pool.deliveryFee(96), hub.minDeliveryFee(96) + 3_000_000 * price);

        vm.expectEmit(address(pool));
        emit LockingLiquidityPool.DeliveryGasSet(1_000_000);
        pool.setDeliveryGas(1_000_000);
        assertEq(pool.deliveryFee(128), hub.minDeliveryFee(128) + 1_000_000 * price);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.setDeliveryGas(1);
    }

    function test_plainWithdrawalIsSaltedAndNamesItsMessage() public {
        MessageLib.DomainMessage memory withdrawal = MessageLib.DomainMessage({
            sourceChainId: CHAIN_A,
            destinationChainId: L1,
            from: address(nsBridgeA),
            to: address(l1BridgeA),
            sourceNonce: 0,
            salt: TEST_SALT,
            data: MessageLib.encodeTransfer(bob, address(eur), 1 ether)
        });
        vm.startPrank(alice);
        vm.expectRevert(DomainSpoke.ZeroSalt.selector);
        nsBridgeA.bridgeToL1(bob, address(eur), 1 ether, bytes32(0));
        vm.expectEmit(address(nsBridgeA));
        emit DemoDomainBridge.WithdrawalInitiated(alice, bob, address(eur), 1 ether, bytes32(0), _hash(withdrawal));
        nsBridgeA.bridgeToL1(bob, address(eur), 1 ether, TEST_SALT);
        vm.stopPrank();

        (bytes32 anchor, bytes32[] memory leaves) = _attestPending(spokeA);
        assertTrue(hub.relayDomainMessage(withdrawal, anchor, MerkleTreeLib.getProof(leaves, 0)));
        assertEq(eur.balanceOf(bob), 1 ether);
        assertEq(_ledgerA().balanceOf(alice), DEPOSIT - 1 ether);
    }

    function test_swapPaysTheRecipientOnTheL1() public {
        address carol = makeAddr("carol");
        eur.mint(carol, AMOUNT_IN);
        vm.startPrank(carol);
        eur.approve(address(pool), AMOUNT_IN);
        uint256 charged = pool.swap(AMOUNT_OUT, bob);
        vm.stopPrank();

        assertEq(charged, AMOUNT_IN, "charged the quote");
        assertEq(eur.balanceOf(carol), 0);
        assertEq(eur.balanceOf(address(pool)), AMOUNT_IN, "pool received the EUR");
        assertEq(usd.balanceOf(bob), AMOUNT_OUT, "bob received USD on the L1");
        assertEq(usd.balanceOf(address(pool)), 30_000 ether - AMOUNT_OUT);
    }

    function test_swapCannotTakeLiquidityReservedByALock() public {
        // A bank payment locks AMOUNT_OUT; the swap may only use what is left.
        uint256 requestId = _fileOrder(false);
        _lockRoundTrip(requestId, _kycRoundTrip(requestId, true));
        assertEq(pool.lockedOut(), AMOUNT_OUT);
        uint256 free = pool.availableOut();

        address carol = makeAddr("carol");
        eur.mint(carol, 100_000 ether);
        vm.startPrank(carol);
        eur.approve(address(pool), type(uint256).max);
        vm.expectRevert("LP: not enough liquidity");
        pool.swap(free + 1, carol);
        pool.swap(free, carol);
        vm.stopPrank();
        assertEq(pool.availableOut(), 0);
        assertEq(usd.balanceOf(address(pool)), AMOUNT_OUT, "the locked USD is still there");
    }

    function test_swapNeedsTheEurAndARecipient() public {
        address carol = makeAddr("carol");
        vm.startPrank(carol);
        vm.expectRevert("LP: zero amount");
        pool.swap(0, carol);
        vm.expectRevert("LP: zero recipient");
        pool.swap(AMOUNT_OUT, address(0));
        vm.expectRevert(); // no EUR approved
        pool.swap(AMOUNT_OUT, carol);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Steps
    // ---------------------------------------------------------------------

    /// @dev Alice authorises the bank and files the order; the inquiry is recorded on spoke A.
    function _fileOrder(bool expireLock) internal returns (uint256 requestId) {
        vm.recordLogs();
        vm.startPrank(alice);
        _ledgerA().approve(address(bankA), AMOUNT_IN);
        requestId = bankA.requestTransfer(bob, AMOUNT_OUT, expireLock);
        vm.stopPrank();
        (
            address user,
            address recipient,
            uint256 amountOut,
            uint256 amountIn,
            bool expire,
            L2Bank.RequestStatus status,
        ) = bankA.requests(requestId);
        assertEq(user, alice);
        assertEq(recipient, bob);
        assertEq(amountOut, AMOUNT_OUT);
        assertEq(amountIn, AMOUNT_IN);
        assertEq(expire, expireLock);
        assertEq(uint8(status), uint8(L2Bank.RequestStatus.PendingKyc));
    }

    /// @dev Files an order to `recipient` (no lock expiry) without the checks of `_fileOrder`.
    function _fileOrderTo(address recipient) internal returns (uint256 requestId) {
        vm.recordLogs();
        vm.startPrank(alice);
        _ledgerA().approve(address(bankA), AMOUNT_IN);
        requestId = bankA.requestTransfer(recipient, AMOUNT_OUT, false);
        vm.stopPrank();
    }

    /// @dev Inquiry A -> L1 -> B, Bank B answers in the delivery, reply B -> L1 -> A; the L1
    /// only forwards ciphertext. Takes the inquiry spoke A recorded since the order was filed.
    /// Returns what Bank A recorded while the reply was delivered: the lock request, when approved.
    function _kycRoundTrip(uint256 requestId, bool expectApproved)
        internal
        returns (MessageLib.DomainMessage[] memory lockRequests)
    {
        // The inquiry is the only pending message on spoke A, sealed: its envelope names nobody.
        MessageLib.DomainMessage[] memory inquiries = _recordedMessages(spokeA);
        assertEq(inquiries.length, 1, "inquiry recorded");
        assertEq(inquiries[0].destinationChainId, CHAIN_B);
        assertEq(inquiries[0].from, address(0), "the envelope hides the sender");
        assertEq(inquiries[0].to, address(0), "the envelope hides the target");

        // Relay it (the hub forwards the ciphertext to B); B's client opens it.
        Delivery memory inquiry = _relayBatch(spokeA, inquiries);
        assertTrue(hub.relayedDomainMessages(CHAIN_A, _hash(inquiries[0])));
        _assertDelivery(inquiry, CHAIN_B, CHAIN_A, address(bankA), address(bankB), _inquiryPayload(requestId));

        // Protocol delivers the inquiry to Bank B, which replies in the same transaction.
        MessageLib.DomainMessage[] memory replies = _deliver(inquiry);
        assertEq(replies.length, 1, "Bank B replied");

        // Reply B -> L1 -> A.
        Delivery memory reply = _relayBatch(spokeB, replies);
        _assertDelivery(
            reply, CHAIN_A, CHAIN_B, address(bankB), address(bankA), abi.encode(uint8(2), requestId, expectApproved)
        );
        lockRequests = _deliver(reply);
        (,,,,, L2Bank.RequestStatus status,) = bankA.requests(requestId);
        assertEq(uint8(status), uint8(expectApproved ? L2Bank.RequestStatus.Approved : L2Bank.RequestStatus.Denied));
    }

    /// @dev The inquiry Bank A sends its peer for `requestId`.
    function _inquiryPayload(uint256 requestId) internal view returns (bytes memory) {
        (address user, address recipient, uint256 amountOut,,,,) = bankA.requests(requestId);
        return abi.encode(uint8(1), requestId, user, recipient, amountOut);
    }

    /// @dev Lock request A -> L1: the hub calls the pool, which locks and records its quote
    /// for Bank A in the same transaction, paying for its delivery; the protocol delivers the
    /// quote to Bank A, which pays the pool in that delivery. Returns the lock and the recorded
    /// payment withdrawal.
    function _lockRoundTrip(uint256 requestId, MessageLib.DomainMessage[] memory lockRequests)
        internal
        returns (uint256 lockId, MessageLib.DomainMessage[] memory payments)
    {
        Delivery memory quote = _relayBatch(spokeA, lockRequests);
        (,, lockId,) = abi.decode(quote.message.data, (uint8, uint256, uint256, uint256));
        assertEq(pool.lockIdByRequest(_requestKey(requestId)), lockId + 1);
        _assertDelivery(
            quote, CHAIN_A, L1, address(pool), address(bankA), abi.encode(uint8(4), requestId, lockId, AMOUNT_IN)
        );
        assertEq(quote.fee, pool.deliveryFee(128), "the pool paid for the quote's delivery");

        payments = _deliver(quote);
    }

    // ---------------------------------------------------------------------
    // Protocol and relayer helpers
    // ---------------------------------------------------------------------

    /// @dev The validator attests the spoke's pending batch at the next checkpoint and the
    /// relayer proves every message of `batch` (which must be the full pending list, in order),
    /// paying for the delivery of those bound for a domain. Returns the one delivery the hub
    /// recorded meanwhile.
    function _relayBatch(DomainSpoke spoke, MessageLib.DomainMessage[] memory batch)
        internal
        returns (Delivery memory)
    {
        (bytes32 anchor, bytes32[] memory leaves) = _attestPending(spoke);
        assertEq(leaves.length, batch.length, "batch is the full pending list");
        vm.recordLogs();
        for (uint256 i = 0; i < batch.length; i++) {
            assertEq(_hash(batch[i]), leaves[i], "envelope matches the recorded leaf");
            uint256 fee = batch[i].destinationChainId == L1 ? 0 : DELIVERY_FEE;
            assertTrue(hub.relayDomainMessage{value: fee}(batch[i], anchor, MerkleTreeLib.getProof(leaves, i)), "relay");
        }
        return _recordedDelivery();
    }

    /// @dev The validator attests everything the spoke recorded since its last checkpoint.
    function _attestPending(DomainSpoke spoke) internal returns (bytes32 anchor, bytes32[] memory leaves) {
        leaves = _pendingLeaves(spoke);
        anchor = _attestBatch(hub, spoke, VALIDATOR_KEY);
    }

    /// @dev Delivers `delivery` as the protocol does: a system transaction whose gas limit is
    /// what the fee bought, less its intrinsic gas at the calldata floor. Returns the messages
    /// the spoke recorded during the delivery.
    function _deliver(Delivery memory delivery) internal returns (MessageLib.DomainMessage[] memory) {
        DomainSpoke spoke = delivery.domainChainId == CHAIN_A ? spokeA : spokeB;
        MessageLib.Message memory m = delivery.message;
        bytes memory input = abi.encodeCall(spoke.relayL1Message, (m.sourceChainId, m.from, m.to, m.data, m.nonce));
        uint256 gasLimit = delivery.fee / hub.DOMAIN_GAS_PRICE() - 21_000 - 40 * input.length;
        vm.recordLogs();
        vm.prank(spoke.SYSTEM_RELAYER());
        spoke.relayL1Message{gas: gasLimit}(m.sourceChainId, m.from, m.to, m.data, m.nonce);
        assertFalse(spoke.failedL1Messages(MessageLib.hashMessage(m)), "delivery failed");
        return _recordedMessages(spoke);
    }

    /// @dev A delivery of an L1 message from `from` under `spoke`'s next nonce.
    function _l1Delivery(DomainSpoke spoke, address from, address to, bytes memory data)
        internal
        view
        returns (Delivery memory)
    {
        return Delivery(
            spoke.DOMAIN_CHAIN_ID(), MessageLib.Message(L1, from, to, data, spoke.nextL1Nonce()), DELIVERY_FEE
        );
    }

    /// @dev The one delivery the hub recorded since `vm.recordLogs()`, as the destination's
    /// client derives it: an L1 message as recorded, a forwarded ciphertext opened with the
    /// domain's viewing key.
    function _recordedDelivery() internal view returns (Delivery memory delivery) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hub)) continue;
            if (logs[i].topics[0] == IDomainHub.L1MessageRecorded.selector) {
                delivery = _plainDelivery(logs[i]);
            } else if (logs[i].topics[0] == IDomainHub.EncryptedMessageRecorded.selector) {
                delivery = _openedDelivery(logs[i]);
            } else {
                continue;
            }
            found++;
        }
        assertEq(found, 1, "one delivery recorded");
    }

    function _plainDelivery(Vm.Log memory log) internal pure returns (Delivery memory) {
        (uint64 sourceChainId, bytes memory data, uint256 nonce, uint256 fee,) =
            abi.decode(log.data, (uint64, bytes, uint256, uint256, bytes32));
        address from = address(uint160(uint256(log.topics[2])));
        address to = address(uint160(uint256(log.topics[3])));
        return Delivery(uint64(uint256(log.topics[1])), MessageLib.Message(sourceChainId, from, to, data, nonce), fee);
    }

    function _openedDelivery(Vm.Log memory log) internal view returns (Delivery memory delivery) {
        MessageLib.Message memory m = delivery.message;
        delivery.domainChainId = uint64(uint256(log.topics[1]));
        m.sourceChainId = uint64(uint256(log.topics[2]));
        uint256 sourceNonce;
        bytes memory ciphertext;
        (sourceNonce, ciphertext, m.nonce, delivery.fee) = abi.decode(log.data, (uint256, bytes, uint256, uint256));
        bytes32 viewingKey = bytes32(hub.viewingKeys(delivery.domainChainId));
        bool opened;
        (opened, m.from, m.to, m.data) =
            _openMessage(ciphertext, m.sourceChainId, delivery.domainChainId, sourceNonce, viewingKey);
        assertTrue(opened, "the destination client opens the forwarded ciphertext");
    }

    function _assertDelivery(
        Delivery memory delivery,
        uint64 domainChainId,
        uint64 sourceChainId,
        address from,
        address to,
        bytes memory data
    ) internal pure {
        assertEq(delivery.domainChainId, domainChainId, "delivery domain");
        assertEq(delivery.message.sourceChainId, sourceChainId, "delivery source");
        assertEq(delivery.message.from, from, "delivery sender");
        assertEq(delivery.message.to, to, "delivery target");
        assertEq(delivery.message.data, data, "delivery payload");
    }

    /// @dev Decodes every `DomainMessageRecorded` envelope `spoke` emitted since `vm.recordLogs()`.
    function _recordedMessages(DomainSpoke spoke) internal view returns (MessageLib.DomainMessage[] memory messages) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = IDomainSpoke.DomainMessageRecorded.selector;
        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(spoke) && logs[i].topics[0] == topic) count++;
        }
        messages = new MessageLib.DomainMessage[](count);
        uint256 j;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(spoke) || logs[i].topics[0] != topic) continue;
            bytes memory encoded = abi.decode(logs[i].data, (bytes));
            messages[j++] = abi.decode(encoded, (MessageLib.DomainMessage));
        }
    }

    function _fundPool(uint256 amount) internal {
        (bool funded,) = address(pool).call{value: amount}("");
        assertTrue(funded, "pool funded");
    }

    /// @dev The key the pool locks a payment order under: one lock per order.
    function _requestKey(uint256 requestId) internal view returns (bytes32) {
        return keccak256(abi.encode(address(bankA), requestId));
    }

    function _ledgerA() internal view returns (BridgedERC20) {
        return nsBridgeA.bridgedTokens(address(eur));
    }

    function _hash(MessageLib.DomainMessage memory message) internal view returns (bytes32) {
        return MessageLib.hashDomainMessage(message, block.chainid, address(hub));
    }
}
