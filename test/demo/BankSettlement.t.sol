// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {DomainHub} from "../../src/DomainHub.sol";
import {DomainSpoke} from "../../src/DomainSpoke.sol";
import {BridgedERC20} from "../../src/bridge/BridgedERC20.sol";
import {DemoDomainBridge} from "../../src/demo/DemoDomainBridge.sol";
import {DemoL1Bridge} from "../../src/demo/DemoL1Bridge.sol";
import {DemoLedger} from "../../src/demo/DemoLedger.sol";
import {L2Bank} from "../../src/demo/L2Bank.sol";
import {LockingLiquidityPool} from "../../src/demo/LockingLiquidityPool.sol";
import {MerkleTreeLib} from "../../src/libraries/MerkleTreeLib.sol";
import {MessageLib} from "../../src/libraries/MessageLib.sol";

/// @notice The bank demo end to end: a customer of Bank A (EUR, domain A) pays a customer of
/// Bank B (USD, domain B) through the L1 liquidity pool. The test plays the protocol
/// (system deliveries) and the operator service (finalize, attest, relay, lock, execute).
contract BankSettlementTest is Test {
    uint64 internal constant CHAIN_A = 7777;
    uint64 internal constant CHAIN_B = 8888;
    uint256 internal constant VALIDATOR_KEY = 0xA11CE;
    uint256 internal constant RATE_NUM = 12;
    uint256 internal constant RATE_DEN = 10;
    uint256 internal constant DEPOSIT = 500 ether;
    uint256 internal constant AMOUNT_OUT = 60 ether; // $60
    uint256 internal constant AMOUNT_IN = 50 ether; // costs 50 EUR at 1.2

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
        hub = new DomainHub();
        hub.registerDomain(CHAIN_A, 0, _validatorSet(), 1);
        hub.registerDomain(CHAIN_B, 0, _validatorSet(), 1);
        spokeA = new DomainSpoke(CHAIN_A, address(this), block.chainid, address(hub));
        spokeB = new DomainSpoke(CHAIN_B, address(this), block.chainid, address(hub));

        eur = new DemoLedger("Demo Euro", "EUR");
        usd = new DemoLedger("Demo Dollar", "USD");
        l1BridgeA = new DemoL1Bridge(hub, CHAIN_A);
        l1BridgeB = new DemoL1Bridge(hub, CHAIN_B);
        nsBridgeA = new DemoDomainBridge(spokeA, address(l1BridgeA));
        nsBridgeB = new DemoDomainBridge(spokeB, address(l1BridgeB));
        l1BridgeA.registerDomainBridge(address(nsBridgeA));
        l1BridgeB.registerDomainBridge(address(nsBridgeB));
        l1BridgeA.setTokenAllowed(address(eur), true);
        l1BridgeB.setTokenAllowed(address(usd), true);

        pool = new LockingLiquidityPool(eur, usd, RATE_NUM, RATE_DEN, l1BridgeA, l1BridgeB, bankOp);
        usd.mint(address(pool), 30_000 ether);

        bankA = new L2Bank(spokeA, nsBridgeA, address(eur), address(pool), RATE_NUM, RATE_DEN, bankOp);
        bankB = new L2Bank(spokeB, nsBridgeB, address(usd), address(pool), RATE_NUM, RATE_DEN, bankOp);
        vm.startPrank(bankOp);
        bankA.registerPeer(CHAIN_B, address(bankB));
        bankB.registerPeer(CHAIN_A, address(bankA));
        bankB.setReceiveAllowance(bob, 1_000 ether);
        vm.stopPrank();

        // Alice funds her Bank A account: EUR locked on the L1, delivered to domain A.
        eur.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        eur.approve(address(l1BridgeA), DEPOSIT);
        l1BridgeA.bridgeToDomain(alice, address(eur), DEPOSIT);
        vm.stopPrank();
        _deliverL1Message(
            spokeA, address(l1BridgeA), address(nsBridgeA), MessageLib.encodeTransfer(alice, address(eur), DEPOSIT)
        );
        assertEq(_ledgerA().balanceOf(alice), DEPOSIT);
    }

    // ---------------------------------------------------------------------
    // Flows
    // ---------------------------------------------------------------------

    function test_paymentSettlesThroughThePool() public {
        uint256 requestId = _fileOrder(false);
        _kycRoundTrip(requestId, true);

        // Operator: lock at the pool, execute the payment (withdrawal with the lock memo).
        vm.prank(bankOp);
        (uint256 lockId, uint256 quote) = pool.lockLiquidity(AMOUNT_OUT, bob, alice, 600, _requestKey(requestId));
        assertEq(quote, AMOUNT_IN);
        assertEq(pool.lockedOut(), AMOUNT_OUT);
        assertEq(pool.lockIdByRequest(_requestKey(requestId)), lockId + 1);
        vm.prank(bankOp);
        vm.expectRevert("LP: request already locked");
        pool.lockLiquidity(AMOUNT_OUT, bob, alice, 600, _requestKey(requestId));
        vm.recordLogs();
        vm.prank(bankOp);
        bankA.executePayment(requestId, lockId);
        (,,, uint256 amountIn,, L2Bank.RequestStatus status, uint256 storedLock) = bankA.requests(requestId);
        assertEq(uint8(status), uint8(L2Bank.RequestStatus.Paid));
        assertEq(storedLock, lockId);
        assertEq(amountIn, AMOUNT_IN);

        // Relayer: the withdrawal reaches the L1 and settles the lock in the same transaction.
        MessageLib.DomainMessage[] memory recorded = _recordedMessages(spokeA);
        assertEq(recorded.length, 1);
        _relayBatch(spokeA, CHAIN_A, recorded);
        assertEq(eur.balanceOf(address(pool)), AMOUNT_IN, "pool received the EUR");
        assertEq(eur.balanceOf(address(l1BridgeA)), DEPOSIT - AMOUNT_IN, "EUR collateral released");
        assertEq(usd.balanceOf(address(l1BridgeB)), AMOUNT_OUT, "USD locked for domain B");
        assertEq(usd.balanceOf(address(pool)), 30_000 ether - AMOUNT_OUT);
        assertEq(pool.lockedOut(), 0);
        (,,,,, LockingLiquidityPool.LockState state) = pool.locks(lockId);
        assertEq(uint8(state), uint8(LockingLiquidityPool.LockState.Settled));

        // Protocol: the USD deposit lands on domain B.
        _deliverL1Message(
            spokeB, address(l1BridgeB), address(nsBridgeB), MessageLib.encodeTransfer(bob, address(usd), AMOUNT_OUT)
        );
        assertEq(nsBridgeB.bridgedTokens(address(usd)).balanceOf(bob), AMOUNT_OUT, "bob paid at Bank B");
        assertEq(_ledgerA().balanceOf(alice), DEPOSIT - AMOUNT_IN, "alice charged at Bank A");
        assertEq(bankB.receiveAllowance(bob), 1_000 ether - AMOUNT_OUT, "KYC allowance consumed");
    }

    function test_expiredLockRefundsTheCustomer() public {
        uint256 requestId = _fileOrder(true);
        _kycRoundTrip(requestId, true);

        vm.prank(bankOp);
        (uint256 lockId,) = pool.lockLiquidity(AMOUNT_OUT, bob, alice, 0, _requestKey(requestId)); // born expired
        vm.recordLogs();
        vm.prank(bankOp);
        bankA.executePayment(requestId, lockId);
        _relayBatch(spokeA, CHAIN_A, _recordedMessages(spokeA));

        // The pool took the EUR and immediately bridged it back toward alice on domain A.
        assertEq(eur.balanceOf(address(pool)), 0);
        assertEq(eur.balanceOf(address(l1BridgeA)), DEPOSIT, "EUR re-locked for the refund");
        assertEq(usd.balanceOf(address(l1BridgeB)), 0, "no USD moved");
        assertEq(pool.lockedOut(), 0);
        (,,,,, LockingLiquidityPool.LockState state) = pool.locks(lockId);
        assertEq(uint8(state), uint8(LockingLiquidityPool.LockState.Refunded));

        _deliverL1Message(
            spokeA, address(l1BridgeA), address(nsBridgeA), MessageLib.encodeTransfer(alice, address(eur), AMOUNT_IN)
        );
        assertEq(_ledgerA().balanceOf(alice), DEPOSIT, "alice refunded at Bank A");
    }

    function test_kycDenialRefundsOnTheDomain() public {
        vm.prank(bankOp);
        bankB.setReceiveAllowance(bob, AMOUNT_OUT - 1);
        uint256 requestId = _fileOrder(false);
        assertEq(_ledgerA().balanceOf(alice), DEPOSIT - AMOUNT_IN, "custody taken at request time");
        _kycRoundTrip(requestId, false);
        (,,,,, L2Bank.RequestStatus status,) = bankA.requests(requestId);
        assertEq(uint8(status), uint8(L2Bank.RequestStatus.Denied));
        assertEq(_ledgerA().balanceOf(alice), DEPOSIT, "custody returned");
        assertEq(bankB.receiveAllowance(bob), AMOUNT_OUT - 1, "allowance untouched");
        vm.prank(bankOp);
        vm.expectRevert("L2Bank: request not approved");
        bankA.executePayment(requestId, 0);
    }

    function test_settlementHookIsGuarded() public {
        vm.expectRevert("LP: not the source bridge");
        pool.onBridgedTokens(address(eur), AMOUNT_IN, bytes32(0));
        vm.expectRevert("LP: not the locker");
        pool.lockLiquidity(AMOUNT_OUT, bob, alice, 600, _requestKey(0));
        vm.expectRevert("L2Bank: not spoke");
        bankA.onDomainMessage(CHAIN_B, address(bankB), abi.encode(uint8(2), uint256(0), true));
    }

    function test_settlementFailureLeavesWithdrawalRetryable() public {
        uint256 requestId = _fileOrder(false);
        _kycRoundTrip(requestId, true);
        vm.prank(bankOp);
        (uint256 lockId,) = pool.lockLiquidity(AMOUNT_OUT, bob, alice, 0, _requestKey(requestId));
        pool.cancelExpiredLock(lockId); // anyone may release an expired, unpaid lock
        assertEq(pool.lockedOut(), 0);

        vm.recordLogs();
        vm.prank(bankOp);
        bankA.executePayment(requestId, lockId);
        MessageLib.DomainMessage[] memory recorded = _recordedMessages(spokeA);
        (bytes32 anchor, bytes32[] memory leaves) = _finalizeAndAttest(spokeA, CHAIN_A);

        // The hook reverts (lock no longer pending): nothing is released and the hub keeps
        // the message retryable instead of consuming it.
        assertFalse(hub.relayDomainMessage(recorded[0], anchor, MerkleTreeLib.getProof(leaves, 0)));
        assertTrue(hub.failedDomainMessages(CHAIN_A, _hash(recorded[0])));
        assertEq(eur.balanceOf(address(pool)), 0);
        assertEq(eur.balanceOf(address(l1BridgeA)), DEPOSIT);
        assertEq(usd.balanceOf(address(l1BridgeB)), 0);
        vm.expectRevert("DomainHub: retry failed");
        hub.retryDomainMessage(recorded[0]);
    }

    // ---------------------------------------------------------------------
    // Steps
    // ---------------------------------------------------------------------

    /// @dev Alice authorises the bank and files the order; the inquiry is recorded on spoke A.
    function _fileOrder(bool expireLock) internal returns (uint256 requestId) {
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

    /// @dev Inquiry A -> L1 -> B, Bank B answers in the delivery, reply B -> L1 -> A.
    function _kycRoundTrip(uint256 requestId, bool expectApproved) internal {
        // The inquiry is the only pending message on spoke A: relay it (hub forwards to B).
        MessageLib.DomainMessage memory inquiry =
            _pendingEnvelope(spokeA, CHAIN_A, CHAIN_B, address(bankA), address(bankB), 0);
        MessageLib.DomainMessage[] memory batch = new MessageLib.DomainMessage[](1);
        batch[0] = inquiry;
        _relayBatch(spokeA, CHAIN_A, batch);
        assertTrue(hub.relayedDomainMessages(CHAIN_A, _hash(inquiry)));

        // Protocol delivers the inquiry to Bank B, which replies in the same transaction.
        vm.recordLogs();
        _deliverL1Message(spokeB, address(bankA), address(bankB), inquiry.data, CHAIN_A);
        MessageLib.DomainMessage[] memory replies = _recordedMessages(spokeB);
        assertEq(replies.length, 1, "Bank B replied");
        (, uint256 repliedId, bool approved) = abi.decode(replies[0].data, (uint8, uint256, bool));
        assertEq(repliedId, requestId);
        assertEq(approved, expectApproved);

        // Reply B -> L1 -> A.
        _relayBatch(spokeB, CHAIN_B, replies);
        _deliverL1Message(spokeA, address(bankB), address(bankA), replies[0].data, CHAIN_B);
        (,,,,, L2Bank.RequestStatus status,) = bankA.requests(requestId);
        assertEq(uint8(status), uint8(expectApproved ? L2Bank.RequestStatus.Approved : L2Bank.RequestStatus.Denied));
    }

    // ---------------------------------------------------------------------
    // Protocol and operator helpers
    // ---------------------------------------------------------------------

    /// @dev Operator finalizes the spoke's pending batch, the validator attests it, and the
    /// relayer proves every message of `batch` (which must be the full pending list, in order).
    function _relayBatch(DomainSpoke spoke, uint64 chainId, MessageLib.DomainMessage[] memory batch) internal {
        (bytes32 anchor, bytes32[] memory leaves) = _finalizeAndAttest(spoke, chainId);
        assertEq(leaves.length, batch.length, "batch is the full pending list");
        for (uint256 i = 0; i < batch.length; i++) {
            assertEq(_hash(batch[i]), leaves[i], "envelope matches the recorded leaf");
            assertTrue(hub.relayDomainMessage(batch[i], anchor, MerkleTreeLib.getProof(leaves, i)), "relay");
        }
    }

    /// @dev Operator finalizes the spoke's pending batch and the validator attests it on the hub.
    function _finalizeAndAttest(DomainSpoke spoke, uint64 chainId)
        internal
        returns (bytes32 anchor, bytes32[] memory leaves)
    {
        leaves = spoke.getPendingDomainMessages();
        anchor = spoke.finalizeDomainMessages();
        uint64 blockNumber = hub.domainBlockNumbers(chainId) + 1;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(VALIDATOR_KEY, hub.stateTransitionDigest(chainId, blockNumber, bytes32(0), anchor));
        hub.submitStateSignature(chainId, blockNumber, bytes32(0), anchor, abi.encodePacked(r, s, v));
    }

    /// @dev Delivers the next L1 -> domain message the hub recorded onto `spoke`.
    function _deliverL1Message(DomainSpoke spoke, address from, address to, bytes memory data) internal {
        _deliverL1Message(spoke, from, to, data, uint64(block.chainid));
    }

    function _deliverL1Message(DomainSpoke spoke, address from, address to, bytes memory data, uint64 sourceChainId)
        internal
    {
        uint256 nonce = spoke.nextL1Nonce();
        vm.prank(spoke.SYSTEM_RELAYER());
        spoke.relayL1Message(sourceChainId, from, to, data, nonce);
        assertFalse(
            spoke.failedL1Messages(MessageLib.hashMessage(MessageLib.Message(sourceChainId, from, to, data, nonce))),
            "delivery failed"
        );
    }

    /// @dev Reconstructs the envelope of the single pending inquiry on `spoke`: the caller
    /// supplies the routing fields, the payload is rebuilt from the bank's latest request,
    /// and the result is checked against the recorded leaf.
    function _pendingEnvelope(
        DomainSpoke spoke,
        uint64 sourceChainId,
        uint64 destinationChainId,
        address from,
        address to,
        uint256 sourceNonce
    ) internal view returns (MessageLib.DomainMessage memory message) {
        bytes32[] memory pending = spoke.getPendingDomainMessages();
        assertEq(pending.length, 1);
        (uint256 requestId, address user, address recipient, uint256 amountOut) = _lastRequest(L2Bank(from));
        message = MessageLib.DomainMessage({
            sourceChainId: sourceChainId,
            destinationChainId: destinationChainId,
            from: from,
            to: to,
            sourceNonce: sourceNonce,
            data: abi.encode(uint8(1), requestId, user, recipient, amountOut)
        });
        assertEq(_hash(message), pending[0], "reconstructed inquiry matches the recorded leaf");
    }

    function _lastRequest(L2Bank bank)
        internal
        view
        returns (uint256 requestId, address user, address recipient, uint256 amountOut)
    {
        requestId = bank.nextRequestId() - 1;
        (user, recipient, amountOut,,,,) = bank.requests(requestId);
    }

    /// @dev Decodes every `DomainMessageRecorded` envelope `spoke` emitted since `vm.recordLogs()`.
    function _recordedMessages(DomainSpoke spoke) internal view returns (MessageLib.DomainMessage[] memory messages) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("DomainMessageRecorded(bytes32,bytes)");
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

    /// @dev The key the operator locks a payment order under: one lock per order.
    function _requestKey(uint256 requestId) internal view returns (bytes32) {
        return keccak256(abi.encode(address(bankA), requestId));
    }

    function _ledgerA() internal view returns (BridgedERC20) {
        return nsBridgeA.bridgedTokens(address(eur));
    }

    function _hash(MessageLib.DomainMessage memory message) internal view returns (bytes32) {
        return MessageLib.hashDomainMessage(message, block.chainid, address(hub));
    }

    function _validatorSet() internal pure returns (address[] memory vs) {
        vs = new address[](1);
        vs[0] = vm.addr(VALIDATOR_KEY);
    }
}
