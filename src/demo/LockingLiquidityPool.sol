// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DemoL1Bridge, IBridgedTokenReceiver} from "./DemoL1Bridge.sol";

/// @notice L1 liquidity pool with accounts on two ledgers (TOKEN_IN, e.g. EUR, and
/// TOKEN_OUT, e.g. USD) that secures cross-domain payments with a LOCK: the payer's bank
/// asks the pool to lock `amountOut` of TOKEN_OUT for a recipient on the destination
/// domain, gets back a quote in TOKEN_IN at the current (fixed, for this demo) rate plus a
/// lock id, and then pays TOKEN_IN referencing that lock id as the withdrawal memo.
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
contract LockingLiquidityPool is Ownable, IBridgedTokenReceiver {
    using SafeERC20 for IERC20;

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

    /// @notice The only account allowed to reserve liquidity (the payer bank's operator), so
    /// a public demo cannot be griefed into locking everything.
    address public locker;

    uint256 public nextLockId;
    mapping(uint256 => Lock) public locks;
    /// @notice TOKEN_OUT currently reserved by pending locks.
    uint256 public lockedOut;
    /// @notice Lock id + 1 per request key, so an operator can resume without double-locking.
    mapping(bytes32 => uint256) public lockIdByRequest;

    event LockerSet(address locker);
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
    event LiquidityWithdrawn(address indexed token, address to, uint256 amount);

    constructor(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 rateNum,
        uint256 rateDen,
        DemoL1Bridge bridgeIn,
        DemoL1Bridge bridgeOut,
        address locker_
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
        locker = locker_;
    }

    function setLocker(address locker_) external onlyOwner {
        locker = locker_;
        emit LockerSet(locker_);
    }

    /// @notice TOKEN_OUT not promised to any pending lock.
    function availableOut() public view returns (uint256) {
        return TOKEN_OUT.balanceOf(address(this)) - lockedOut;
    }

    /// @notice The TOKEN_IN cost of `amountOut` at the pool's rate, rounded up.
    function quoteIn(uint256 amountOut) public view returns (uint256) {
        return (amountOut * RATE_DEN + RATE_NUM - 1) / RATE_NUM;
    }

    /// @notice Reserves `amountOut` of TOKEN_OUT for `recipientOnDest` at the current rate.
    /// Returns the lock id (the memo the payment must reference) and the TOKEN_IN quote.
    /// `requestKey` identifies the payment order being served; a key can only ever be
    /// locked once. `ttlSeconds == 0` creates an already-expired lock - the demo's timeout
    /// knob: its settlement is guaranteed to take the refund path.
    function lockLiquidity(
        uint256 amountOut,
        address recipientOnDest,
        address refundTo,
        uint64 ttlSeconds,
        bytes32 requestKey
    ) external returns (uint256 lockId, uint256 amountIn) {
        require(msg.sender == locker, "LP: not the locker");
        require(amountOut > 0, "LP: zero amount");
        require(recipientOnDest != address(0) && refundTo != address(0), "LP: zero recipient");
        require(lockIdByRequest[requestKey] == 0, "LP: request already locked");
        require(amountOut <= availableOut(), "LP: insufficient liquidity");

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
            BRIDGE_OUT.bridgeToDomain(lock.recipientOnDest, address(TOKEN_OUT), lock.amountOut);
            emit LockSettled(lockId, lock.recipientOnDest, lock.amountOut);
        } else {
            lock.state = LockState.Refunded;
            TOKEN_IN.forceApprove(address(BRIDGE_IN), amount);
            BRIDGE_IN.bridgeToDomain(lock.refundTo, address(TOKEN_IN), amount);
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
