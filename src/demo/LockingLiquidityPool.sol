// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDomainHub} from "../interfaces/IDomain.sol";
import {IDomainMessageReceiver} from "../interfaces/IDomainMessageReceiver.sol";
import {DemoL1Bridge, IBridgedTokenReceiver} from "./DemoL1Bridge.sol";

/// @notice L1 liquidity pool with accounts on two ledgers (TOKEN_IN, e.g. EUR, and
/// TOKEN_OUT, e.g. USD) that secures cross-domain payments with a LOCK: the payer's bank
/// contract asks the pool - by a cross-domain message - to lock `amountOut` of TOKEN_OUT
/// for a recipient on the destination domain; the pool locks it in the transaction that
/// delivers the request and replies, by an L1 -> domain message, with a quote in TOKEN_IN
/// at the current (fixed, for this demo) rate plus a lock id. The bank then pays TOKEN_IN
/// referencing that lock id as the withdrawal memo. No off-chain key takes part.
///
/// Settlement is atomic with the payment: the payer's bank withdraws the quoted TOKEN_IN to
/// this pool through the DemoDomainBridge with the lock id as memo; when the hub delivers
/// that withdrawal, the DemoL1Bridge pays the pool and calls `onBridgedTokens`, which - in
/// the same L1 transaction - pays the locked TOKEN_OUT into the destination domain's bridge
/// for the recipient. If the payment arrives after the lock timed out, the pool instead
/// returns the TOKEN_IN to the refund address on the source domain and releases the
/// reserved liquidity.
///
/// Locked TOKEN_OUT is reserved (`lockedOut`), so concurrent locks can never promise the
/// same liquidity twice. Rate: `RATE_NUM` TOKEN_OUT per `RATE_DEN` TOKEN_IN (equal
/// decimals assumed); quotes round up in the pool's favor.
contract LockingLiquidityPool is Ownable, IBridgedTokenReceiver, IDomainMessageReceiver {
    using SafeERC20 for IERC20;

    /// @notice Message kinds shared with L2Bank: the lock request and the two answers.
    uint8 internal constant KIND_LOCK = 3;
    uint8 internal constant KIND_LOCKED = 4;
    uint8 internal constant KIND_LOCK_FAILED = 5;
    /// @notice Length of the transfer payload a bridge deposit carries.
    uint256 internal constant TRANSFER_LENGTH = 96;

    enum LockState {
        None,
        Pending,
        Settled,
        Refunded,
        Cancelled
    }

    struct Lock {
        uint256 amountIn;
        uint256 amountOut;
        address recipientOnDest;
        address refundTo;
        uint64 expiry;
        LockState state;
    }

    IERC20 public immutable TOKEN_IN;
    IERC20 public immutable TOKEN_OUT;
    uint256 public immutable RATE_NUM;
    uint256 public immutable RATE_DEN;
    /// @notice Bridge of the source domain: TOKEN_IN arrives from it, refunds return through it.
    DemoL1Bridge public immutable BRIDGE_IN;
    /// @notice Bridge of the destination domain: locked TOKEN_OUT is paid through it.
    DemoL1Bridge public immutable BRIDGE_OUT;
    /// @notice The hub that delivers lock requests and carries the replies.
    IDomainHub public immutable HUB;
    /// @notice The source domain (BRIDGE_IN's domain), where the payer bank lives.
    uint64 public immutable SOURCE_CHAIN_ID;

    /// @notice The only contract allowed to reserve liquidity: the payer bank on the source
    /// domain, so a public demo cannot be griefed into locking everything.
    address public payerBank;
    /// @notice Lifetime of a live lock.
    uint64 public lockTtl;
    /// @notice Domain gas the pool buys for the target of every message it sends, on top of
    /// the hub's minimum. Paid from the pool's native balance.
    uint256 public deliveryGas = 3_000_000;

    uint256 public nextLockId;
    mapping(uint256 => Lock) public locks;
    /// @notice TOKEN_OUT currently reserved by pending locks.
    uint256 public lockedOut;
    /// @notice Lock id + 1 per request key (`keccak256(abi.encode(payerBank, requestId))`).
    mapping(bytes32 => uint256) public lockIdByRequest;

    event PayerBankSet(address bank);
    event LockTtlSet(uint64 ttlSeconds);
    event DeliveryGasSet(uint256 gas);
    event LiquidityLocked(
        uint256 indexed lockId,
        bytes32 indexed requestKey,
        uint256 amountIn,
        uint256 amountOut,
        address indexed recipientOnDest,
        address refundTo,
        uint64 expiry
    );
    event LockSettled(uint256 indexed lockId, address indexed recipientOnDest, uint256 amountOut);
    event LockRefunded(uint256 indexed lockId, address indexed refundTo, uint256 amountIn);
    event LockCancelled(uint256 indexed lockId);
    event LockRejected(bytes32 indexed requestKey, uint256 amountOut);
    event LiquidityWithdrawn(address indexed token, address to, uint256 amount);
    event Swapped(address indexed payer, address indexed recipient, uint256 amountIn, uint256 amountOut);

    constructor(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 rateNum,
        uint256 rateDen,
        DemoL1Bridge bridgeIn,
        DemoL1Bridge bridgeOut,
        uint64 lockTtl_
    ) Ownable(msg.sender) {
        require(address(tokenIn) != address(0) && address(tokenOut) != address(0), "LP: zero token");
        require(address(tokenIn) != address(tokenOut), "LP: identical tokens");
        require(rateNum > 0 && rateDen > 0, "LP: zero rate");
        require(address(bridgeIn) != address(0) && address(bridgeOut) != address(0), "LP: zero bridge");
        TOKEN_IN = tokenIn;
        TOKEN_OUT = tokenOut;
        RATE_NUM = rateNum;
        RATE_DEN = rateDen;
        BRIDGE_IN = bridgeIn;
        BRIDGE_OUT = bridgeOut;
        HUB = bridgeIn.HUB();
        SOURCE_CHAIN_ID = bridgeIn.DOMAIN_CHAIN_ID();
        lockTtl = lockTtl_;
    }

    /// @notice Sets the payer bank (deployed on the source domain after this pool).
    function setPayerBank(address bank) external onlyOwner {
        payerBank = bank;
        emit PayerBankSet(bank);
    }

    function setLockTtl(uint64 ttlSeconds) external onlyOwner {
        lockTtl = ttlSeconds;
        emit LockTtlSet(ttlSeconds);
    }

    function setDeliveryGas(uint256 gas) external onlyOwner {
        deliveryGas = gas;
        emit DeliveryGasSet(gas);
    }

    /// @notice Funds the delivery fees: the pool sends its messages from hub callbacks, where
    /// no value arrives.
    receive() external payable {}

    /// @notice The fee the pool attaches to a message with `dataLength` payload bytes.
    function deliveryFee(uint256 dataLength) public view returns (uint256) {
        return HUB.minDeliveryFee(dataLength) + deliveryGas * HUB.DOMAIN_GAS_PRICE();
    }

    /// @notice TOKEN_OUT not promised to any pending lock.
    function availableOut() public view returns (uint256) {
        return TOKEN_OUT.balanceOf(address(this)) - lockedOut;
    }

    /// @notice The TOKEN_IN cost of `amountOut` at the pool's rate, rounded up.
    function quoteIn(uint256 amountOut) public view returns (uint256) {
        return (amountOut * RATE_DEN + RATE_NUM - 1) / RATE_NUM;
    }

    /// @notice Direct swap on the L1 at the pool's rate: the caller pays `quoteIn(amountOut)`
    /// TOKEN_IN and `recipient` receives `amountOut` TOKEN_OUT on the L1, in one transaction.
    /// Takes only liquidity no pending lock has reserved, so it can never break a bank
    /// payment in flight. Public, like the L1 itself: anyone sees who swapped what.
    function swap(uint256 amountOut, address recipient) external returns (uint256 amountIn) {
        require(amountOut > 0, "LP: zero amount");
        require(recipient != address(0), "LP: zero recipient");
        require(amountOut <= availableOut(), "LP: not enough liquidity");
        amountIn = quoteIn(amountOut);
        TOKEN_IN.safeTransferFrom(msg.sender, address(this), amountIn);
        TOKEN_OUT.safeTransfer(recipient, amountOut);
        emit Swapped(msg.sender, recipient, amountIn, amountOut);
    }

    /// @notice Receives the payer bank's lock request, proven and delivered by the hub:
    /// `(KIND_LOCK, requestId, amountOut, recipientOnDest, refundTo, expireLock)`. Reserves
    /// `amountOut` of TOKEN_OUT at the current rate and, in the same transaction, sends the
    /// bank `(KIND_LOCKED, requestId, lockId, amountIn)` - the lock id is the memo the
    /// payment must reference - or `(KIND_LOCK_FAILED, requestId)` when the liquidity is not
    /// there, so the bank can refund its customer instead of waiting. `expireLock` creates an
    /// already-expired lock - the demo's timeout knob: its settlement takes the refund path.
    function onDomainMessage(uint64 sourceChainId, address from, bytes calldata data) external {
        require(msg.sender == address(HUB), "LP: not hub");
        require(sourceChainId == SOURCE_CHAIN_ID && from == payerBank && from != address(0), "LP: not the payer bank");
        (uint8 kind, uint256 requestId, uint256 amountOut, address recipientOnDest, address refundTo, bool expireLock) =
            abi.decode(data, (uint8, uint256, uint256, address, address, bool));
        require(kind == KIND_LOCK, "LP: unknown message kind");

        // One lock per payment order; the hub's replay protection makes a repeat impossible.
        bytes32 requestKey = keccak256(abi.encode(from, requestId));
        require(lockIdByRequest[requestKey] == 0, "LP: request already locked");
        if (amountOut == 0 || amountOut > availableOut() || recipientOnDest == address(0) || refundTo == address(0)) {
            emit LockRejected(requestKey, amountOut);
            _reply(from, abi.encode(KIND_LOCK_FAILED, requestId));
            return;
        }
        (uint256 lockId, uint256 amountIn) =
            _lock(amountOut, recipientOnDest, refundTo, expireLock ? 0 : lockTtl, requestKey);
        _reply(from, abi.encode(KIND_LOCKED, requestId, lockId, amountIn));
    }

    /// @dev Sends `payload` to the payer bank, paying its delivery from the pool's balance.
    function _reply(address bank, bytes memory payload) internal {
        HUB.sendL1Message{value: deliveryFee(payload.length)}(SOURCE_CHAIN_ID, bank, payload);
    }

    /// @dev Reserves `amountOut` for `recipientOnDest`; `ttlSeconds == 0` is born expired.
    function _lock(uint256 amountOut, address recipientOnDest, address refundTo, uint64 ttlSeconds, bytes32 requestKey)
        internal
        returns (uint256 lockId, uint256 amountIn)
    {
        amountIn = quoteIn(amountOut);
        lockId = nextLockId++;
        uint64 expiry = ttlSeconds == 0 ? 0 : uint64(block.timestamp) + ttlSeconds;
        locks[lockId] = Lock({
            amountIn: amountIn,
            amountOut: amountOut,
            recipientOnDest: recipientOnDest,
            refundTo: refundTo,
            expiry: expiry,
            state: LockState.Pending
        });
        lockedOut += amountOut;
        lockIdByRequest[requestKey] = lockId + 1;
        emit LiquidityLocked(lockId, requestKey, amountIn, amountOut, recipientOnDest, refundTo, expiry);
    }

    /// @notice Settlement hook: BRIDGE_IN calls this right after paying a memo withdrawal to
    /// the pool. `memo` is the lock id. Pays the locked TOKEN_OUT to the destination domain
    /// (lock still live) or bridges the TOKEN_IN back to the refund address on the source
    /// domain (lock timed out). Reverting here leaves the withdrawal retryable at the hub.
    function onBridgedTokens(address token, uint256 amount, bytes32 memo) external {
        require(msg.sender == address(BRIDGE_IN), "LP: not the source bridge");
        require(token == address(TOKEN_IN), "LP: wrong payment token");
        uint256 lockId = uint256(memo);
        Lock storage lock = locks[lockId];
        require(lock.state == LockState.Pending, "LP: lock not pending");
        require(amount == lock.amountIn, "LP: wrong payment amount");

        lockedOut -= lock.amountOut;
        if (block.timestamp <= lock.expiry) {
            lock.state = LockState.Settled;
            TOKEN_OUT.forceApprove(address(BRIDGE_OUT), lock.amountOut);
            BRIDGE_OUT.bridgeToDomain{value: deliveryFee(TRANSFER_LENGTH)}(
                lock.recipientOnDest, address(TOKEN_OUT), lock.amountOut
            );
            emit LockSettled(lockId, lock.recipientOnDest, lock.amountOut);
        } else {
            lock.state = LockState.Refunded;
            TOKEN_IN.forceApprove(address(BRIDGE_IN), amount);
            BRIDGE_IN.bridgeToDomain{value: deliveryFee(TRANSFER_LENGTH)}(lock.refundTo, address(TOKEN_IN), amount);
            emit LockRefunded(lockId, lock.refundTo, amount);
        }
    }

    /// @notice Releases the liquidity reserved by an expired lock that was never paid.
    function cancelExpiredLock(uint256 lockId) external {
        Lock storage lock = locks[lockId];
        require(lock.state == LockState.Pending, "LP: lock not pending");
        require(block.timestamp > lock.expiry, "LP: lock not expired");
        lock.state = LockState.Cancelled;
        lockedOut -= lock.amountOut;
        emit LockCancelled(lockId);
    }

    /// @notice Owner-only liquidity management; reserved TOKEN_OUT cannot be pulled.
    function withdrawLiquidity(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(TOKEN_OUT)) {
            require(amount <= availableOut(), "LP: amount reserved by locks");
        }
        IERC20(token).safeTransfer(to, amount);
        emit LiquidityWithdrawn(token, to, amount);
    }
}
