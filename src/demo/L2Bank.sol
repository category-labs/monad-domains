// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDomainSpoke} from "../interfaces/IDomain.sol";
import {IDomainMessageReceiver} from "../interfaces/IDomainMessageReceiver.sol";
import {DemoDomainBridge} from "./DemoDomainBridge.sol";

/// @notice A bank on a domain, operating that domain's wrapped ledger for its customers.
/// Two banks on different domains talk to each other through the hub's native domain ->
/// domain routing: a bank's `sendDomainMessage` to its peer is proven on the hub by the
/// relayer and delivered to the peer as a protocol system transaction (`onDomainMessage`).
///
///   - The PAYER side (e.g. Bank A on domain A, EUR ledger): a customer files a payment
///     order (`requestTransfer`) - the bank takes the quoted EUR into custody and sends the
///     peer bank a KYC inquiry: does the recipient exist and may they receive this amount?
///     On a positive reply the bank asks the L1 pool, by a domain -> L1 message, to lock
///     the liquidity; the pool locks it and replies with the quote and lock id, and on that
///     reply the bank withdraws the EUR to the pool with the lock id as memo. The pool's
///     settlement delivers the swapped currency on the peer's domain. A negative reply, or
///     a pool without the liquidity, refunds the customer. No off-chain key is involved.
///   - The PAYEE side (e.g. Bank B on domain B, USD ledger): keeps the know-your-depositor
///     registry (`receiveAllowance`) and answers inquiries in the delivery transaction.
///
/// KYC tiers: the bank sets a daily limit per tier (`setTierLimit`) and a tier per customer
/// (`setKycTier`), which gives the customer their tier's daily limit. The limit caps what a
/// customer may receive (payee side) or send (payer side) per UTC day: usage resets at
/// 00:00 UTC, and `receiveAllowance` is what is left of it today.
///
/// One contract implements both roles so each domain deploys the same code. Any account can
/// be a customer: the registry is per address and the bank operator onboards addresses.
contract L2Bank is IDomainMessageReceiver {
    using SafeERC20 for IERC20;

    uint8 internal constant KIND_INQUIRY = 1;
    uint8 internal constant KIND_REPLY = 2;
    /// @notice Bank -> pool lock request and the pool's two answers (see LockingLiquidityPool).
    uint8 internal constant KIND_LOCK = 3;
    uint8 internal constant KIND_LOCKED = 4;
    uint8 internal constant KIND_LOCK_FAILED = 5;

    enum RequestStatus {
        None,
        PendingKyc,
        Approved,
        Denied,
        Paid,
        /// @notice Approved, but the pool could not lock (or quoted differently): refunded.
        Failed
    }

    struct Request {
        address user;
        address recipient;
        uint256 amountOut;
        /// @notice The ledger amount taken into custody at request time (the pool's quote).
        uint256 amountIn;
        /// @notice Demo knob: ask the operator for an already-expired lock (refund path).
        bool expireLock;
        RequestStatus status;
        /// @notice The pool lock the payment referenced, once executed.
        uint256 lockId;
    }

    IDomainSpoke public immutable SPOKE;
    DemoDomainBridge public immutable NS_BRIDGE;
    /// @notice The L1 ledger this bank's domain ledger wraps (EUR for A, USD for B).
    address public immutable L1_TOKEN;
    /// @notice The L1 liquidity pool payments are withdrawn to.
    address public immutable POOL;
    /// @notice Pool rate mirrored on the domain so quotes are known at request time.
    uint256 public immutable RATE_NUM;
    uint256 public immutable RATE_DEN;
    /// @notice The bank operator (an EOA) - manages the registry and the peer.
    address public immutable BANK;

    uint64 public peerChainId;
    address public peerBank;

    /// @notice Know-your-customer registry: each account's daily limit, and how much of it
    /// they used on `usedOnDay` (a UTC day number); usage from an earlier day no longer counts.
    mapping(address => uint256) public dailyLimit;
    mapping(address => uint256) public usedToday;
    mapping(address => uint64) public usedOnDay;
    /// @notice KYC tier per customer (0 = not onboarded) and the daily limit of each tier.
    mapping(address => uint8) public kycTier;
    mapping(uint8 => uint256) public tierLimit;
    /// @notice The UTC day a payer's order reserved its limit on, so a refund on a later day
    /// does not give back today's limit.
    mapping(uint256 => uint64) public requestDay;

    uint256 public nextRequestId;
    mapping(uint256 => Request) public requests;

    event PeerRegistered(uint64 chainId, address bank);
    event ReceiveAllowanceSet(address indexed user, uint256 limit);
    event TierLimitSet(uint8 indexed tier, uint256 limit);
    event KycTierSet(address indexed user, uint8 tier);
    event TransferRequested(
        uint256 indexed requestId,
        address indexed user,
        address indexed recipient,
        uint256 amountOut,
        uint256 amountIn,
        bool expireLock
    );
    event InquiryAnswered(uint256 indexed requestId, address indexed recipient, uint256 amountOut, bool approved);
    event ReplyReceived(uint256 indexed requestId, bool approved);
    event LockRequested(uint256 indexed requestId, uint256 amountOut);
    event LockFailed(uint256 indexed requestId);
    event PaymentExecuted(uint256 indexed requestId, uint256 amountIn, uint256 lockId);
    event RequestRefunded(uint256 indexed requestId, address indexed user, uint256 amountIn);

    modifier onlyBank() {
        require(msg.sender == BANK, "L2Bank: not the bank");
        _;
    }

    constructor(
        IDomainSpoke spoke,
        DemoDomainBridge nsBridge,
        address l1Token,
        address pool,
        uint256 rateNum,
        uint256 rateDen,
        address bank
    ) {
        require(pool != address(0) && bank != address(0), "L2Bank: zero address");
        require(rateNum > 0 && rateDen > 0, "L2Bank: zero rate");
        SPOKE = spoke;
        NS_BRIDGE = nsBridge;
        L1_TOKEN = l1Token;
        POOL = pool;
        RATE_NUM = rateNum;
        RATE_DEN = rateDen;
        BANK = bank;
    }

    /// @notice Sets the counterpart bank. One-shot: cannot be changed once set.
    function registerPeer(uint64 chainId, address bank) external onlyBank {
        require(bank != address(0), "L2Bank: zero peer");
        require(peerBank == address(0), "L2Bank: peer already registered");
        peerChainId = chainId;
        peerBank = bank;
        emit PeerRegistered(chainId, bank);
    }

    /// @notice Sets `user`'s daily limit directly (outside the tiers). Today's usage stands.
    function setReceiveAllowance(address user, uint256 limit) external onlyBank {
        dailyLimit[user] = limit;
        emit ReceiveAllowanceSet(user, limit);
    }

    /// @notice Sets the daily limit that comes with a KYC tier.
    function setTierLimit(uint8 tier, uint256 limit) external onlyBank {
        tierLimit[tier] = limit;
        emit TierLimitSet(tier, limit);
    }

    /// @notice Puts `user` in a KYC tier: their daily limit becomes the tier's (as set now).
    /// Today's usage stands, so re-onboarding never tops up a day's limit.
    function setKycTier(address user, uint8 tier) external onlyBank {
        kycTier[user] = tier;
        dailyLimit[user] = tierLimit[tier];
        emit KycTierSet(user, tier);
        emit ReceiveAllowanceSet(user, tierLimit[tier]);
    }

    /// @notice What is left of `user`'s daily limit today.
    function receiveAllowance(address user) public view returns (uint256) {
        uint256 used = usedOnDay[user] == _today() ? usedToday[user] : 0;
        uint256 limit = dailyLimit[user];
        return limit > used ? limit - used : 0;
    }

    function _today() internal view returns (uint64) {
        return uint64(block.timestamp / 1 days);
    }

    /// @dev Counts `amount` against today's limit; the caller checked it fits.
    function _useLimit(address user, uint256 amount) internal {
        uint64 today = _today();
        if (usedOnDay[user] != today) {
            usedOnDay[user] = today;
            usedToday[user] = 0;
        }
        usedToday[user] += amount;
    }

    /// @notice The wrapped ledger this bank operates (deployed by the first deposit).
    function ledger() public view returns (IERC20) {
        return IERC20(address(NS_BRIDGE.bridgedTokens(L1_TOKEN)));
    }

    /// @notice The ledger cost of `amountOut` in the peer's currency, mirroring the pool's quote.
    function quoteIn(uint256 amountOut) public view returns (uint256) {
        return (amountOut * RATE_DEN + RATE_NUM - 1) / RATE_NUM;
    }

    // ---------------------------------------------------------------------
    // Payer side
    // ---------------------------------------------------------------------

    /// @notice A customer asks the bank to send `amountOut` (denominated in the PEER bank's
    /// currency) to `recipient` at the peer bank. The quoted ledger amount must fit the
    /// customer's remaining daily limit and is taken into custody now (the customer's prior
    /// ERC20 approval is the mandate); the KYC inquiry is sent to the peer. `expireLock` is
    /// the demo's timeout knob: such a payment is always refunded, so it reserves no limit.
    function requestTransfer(address recipient, uint256 amountOut, bool expireLock)
        external
        returns (uint256 requestId)
    {
        require(peerBank != address(0), "L2Bank: no peer");
        require(recipient != address(0), "L2Bank: zero recipient");
        require(amountOut > 0, "L2Bank: zero amount");
        IERC20 token = ledger();
        require(address(token) != address(0), "L2Bank: ledger not deployed");

        uint256 amountIn = quoteIn(amountOut);
        require(receiveAllowance(msg.sender) >= amountIn, "L2Bank: over your daily limit");
        if (!expireLock) _useLimit(msg.sender, amountIn);
        token.safeTransferFrom(msg.sender, address(this), amountIn);

        requestId = nextRequestId++;
        requestDay[requestId] = _today();
        requests[requestId] = Request({
            user: msg.sender,
            recipient: recipient,
            amountOut: amountOut,
            amountIn: amountIn,
            expireLock: expireLock,
            status: RequestStatus.PendingKyc,
            lockId: 0
        });
        _sendToPeer(abi.encode(KIND_INQUIRY, requestId, msg.sender, recipient, amountOut));
        emit TransferRequested(requestId, msg.sender, recipient, amountOut, amountIn, expireLock);
    }

    // ---------------------------------------------------------------------
    // Message delivery (both sides)
    // ---------------------------------------------------------------------

    /// @notice Receives a message delivered by the protocol: from the peer bank (routed by the
    /// hub) or from the L1 pool. An INQUIRY is answered in the same transaction from the
    /// registry; a REPLY resolves the pending request it references - approved, it asks the
    /// pool for a lock; denied, it refunds the customer. The pool's LOCKED answer pays the
    /// pool in the same transaction; LOCK_FAILED refunds the customer.
    function onDomainMessage(uint64 sourceChainId, address from, bytes calldata data) external {
        require(msg.sender == address(SPOKE), "L2Bank: not spoke");
        uint8 kind = abi.decode(data, (uint8));
        if (sourceChainId == SPOKE.L1_CHAIN_ID() && from == POOL) {
            _onPoolMessage(kind, data);
            return;
        }
        require(sourceChainId == peerChainId && from == peerBank, "L2Bank: not the peer bank");

        if (kind == KIND_INQUIRY) {
            (, uint256 requestId,, address recipient, uint256 amountOut) =
                abi.decode(data, (uint8, uint256, address, address, uint256));
            bool approved = receiveAllowance(recipient) >= amountOut;
            if (approved) _useLimit(recipient, amountOut);
            _sendToPeer(abi.encode(KIND_REPLY, requestId, approved));
            emit InquiryAnswered(requestId, recipient, amountOut, approved);
        } else if (kind == KIND_REPLY) {
            (, uint256 requestId, bool approved) = abi.decode(data, (uint8, uint256, bool));
            Request storage request = requests[requestId];
            require(request.status == RequestStatus.PendingKyc, "L2Bank: request not pending");
            if (approved) {
                request.status = RequestStatus.Approved;
                SPOKE.sendDomainMessage(
                    SPOKE.L1_CHAIN_ID(),
                    POOL,
                    abi.encode(
                        KIND_LOCK, requestId, request.amountOut, request.recipient, request.user, request.expireLock
                    ),
                    _salt(requestId, KIND_LOCK)
                );
                emit LockRequested(requestId, request.amountOut);
            } else {
                request.status = RequestStatus.Denied;
                _refund(requestId, request);
            }
            emit ReplyReceived(requestId, approved);
        } else {
            revert("L2Bank: unknown message kind");
        }
    }

    /// @dev The pool's answer to a lock request. LOCKED with the quote the customer was
    /// charged pays the pool: the custodied amount is withdrawn to it with the lock id as
    /// memo, and the pool settles the lock in the L1 transaction that delivers it.
    function _onPoolMessage(uint8 kind, bytes calldata data) internal {
        if (kind == KIND_LOCKED) {
            (, uint256 requestId, uint256 lockId, uint256 amountIn) =
                abi.decode(data, (uint8, uint256, uint256, uint256));
            Request storage request = requests[requestId];
            require(request.status == RequestStatus.Approved, "L2Bank: request not approved");
            if (amountIn != request.amountIn) {
                // A quote other than the one charged would be rejected at settlement; the
                // unpaid lock expires and anyone can release it (cancelExpiredLock).
                request.status = RequestStatus.Failed;
                emit LockFailed(requestId);
                _refund(requestId, request);
                return;
            }
            request.status = RequestStatus.Paid;
            request.lockId = lockId;
            NS_BRIDGE.bridgeToL1WithMemo(
                POOL, L1_TOKEN, request.amountIn, bytes32(lockId), _salt(requestId, KIND_LOCKED)
            );
            emit PaymentExecuted(requestId, request.amountIn, lockId);
        } else if (kind == KIND_LOCK_FAILED) {
            (, uint256 requestId) = abi.decode(data, (uint8, uint256));
            Request storage request = requests[requestId];
            require(request.status == RequestStatus.Approved, "L2Bank: request not approved");
            request.status = RequestStatus.Failed;
            emit LockFailed(requestId);
            _refund(requestId, request);
        } else {
            revert("L2Bank: unknown message kind");
        }
    }

    /// @dev Returns the custodied amount and the daily limit it reserved.
    function _refund(uint256 requestId, Request storage request) internal {
        // Give back the limit the order reserved - if it was reserved today; an earlier day's
        // usage no longer counts anyway.
        if (!request.expireLock && requestDay[requestId] == _today() && usedOnDay[request.user] == _today()) {
            usedToday[request.user] -= request.amountIn;
        }
        ledger().safeTransfer(request.user, request.amountIn);
        emit RequestRefunded(requestId, request.user, request.amountIn);
    }

    /// @dev Routes `payload` to the peer bank through the hub, sealed to the peer's domain.
    function _sendToPeer(bytes memory payload) internal {
        SPOKE.sendDomainMessage(peerChainId, peerBank, payload, bytes32(0));
    }

    /// @dev Nonzero salt of an L1-bound send. A production sender would use secret randomness.
    function _salt(uint256 requestId, uint8 tag) internal view returns (bytes32) {
        return keccak256(abi.encode(address(this), requestId, tag, block.prevrandao));
    }
}
