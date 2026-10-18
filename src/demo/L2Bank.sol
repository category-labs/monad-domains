// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDomainMessageReceiver, IDomainSpoke} from "../interfaces/IDomain.sol";
import {DemoDomainBridge} from "./DemoDomainBridge.sol";

/// @notice A bank on a domain, operating that domain's wrapped ledger for its customers.
/// Two banks on different domains talk to each other through the hub's native domain ->
/// domain routing: a bank's `sendDomainMessage` to its peer is proven on the hub by the
/// relayer and delivered to the peer as a protocol system transaction (`onDomainMessage`).
///
///   - The PAYER side (e.g. Bank A on domain A, EUR ledger): a customer files a payment
///     order (`requestTransfer`) - the bank takes the quoted EUR into custody and sends the
///     peer bank a KYC inquiry: does the recipient exist and may they receive this amount?
///     On a positive reply the bank's operator locks liquidity at the L1 pool and
///     `executePayment` withdraws the EUR to the pool with the lock id as memo; the pool's
///     settlement delivers the swapped currency on the peer's domain. A negative reply
///     refunds the customer.
///   - The PAYEE side (e.g. Bank B on domain B, USD ledger): keeps the know-your-depositor
///     registry (`receiveAllowance`) and answers inquiries in the delivery transaction.
///
/// One contract implements both roles so each domain deploys the same code. Any account can
/// be a customer: the registry is per address and the bank operator onboards addresses.
contract L2Bank is IDomainMessageReceiver {
    using SafeERC20 for IERC20;

    uint8 internal constant KIND_INQUIRY = 1;
    uint8 internal constant KIND_REPLY = 2;

    enum RequestStatus {
        None,
        PendingKyc,
        Approved,
        Denied,
        Paid
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
    /// @notice The bank operator (an EOA) - manages the registry and executes payments.
    address public immutable BANK;

    uint64 public peerChainId;
    address public peerBank;

    /// @notice Know-your-depositor registry: how much each account may still receive.
    mapping(address => uint256) public receiveAllowance;

    uint256 public nextRequestId;
    mapping(uint256 => Request) public requests;

    event PeerRegistered(uint64 chainId, address bank);
    event ReceiveAllowanceSet(address indexed user, uint256 limit);
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

    /// @notice Bank maintains the registry of who may receive funds, and up to how much.
    function setReceiveAllowance(address user, uint256 limit) external onlyBank {
        receiveAllowance[user] = limit;
        emit ReceiveAllowanceSet(user, limit);
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
    /// currency) to `recipient` at the peer bank. The quoted ledger amount is taken into
    /// custody now (the customer's prior ERC20 approval is the mandate) and the KYC inquiry
    /// is sent to the peer. `expireLock` is the demo's timeout knob.
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
        token.safeTransferFrom(msg.sender, address(this), amountIn);

        requestId = nextRequestId++;
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

    /// @notice After a positive KYC reply and once the operator has reserved liquidity at
    /// the pool (`lockId`), withdraws the custodied ledger amount to the pool with the lock
    /// id as memo. The pool settles the lock in the L1 transaction that delivers it.
    function executePayment(uint256 requestId, uint256 lockId) external onlyBank {
        Request storage request = requests[requestId];
        require(request.status == RequestStatus.Approved, "L2Bank: request not approved");
        request.status = RequestStatus.Paid;
        request.lockId = lockId;
        NS_BRIDGE.bridgeToL1WithMemo(POOL, L1_TOKEN, request.amountIn, bytes32(lockId));
        emit PaymentExecuted(requestId, request.amountIn, lockId);
    }

    // ---------------------------------------------------------------------
    // Message delivery (both sides)
    // ---------------------------------------------------------------------

    /// @notice Receives a routed message from the peer bank, delivered by the protocol. An
    /// INQUIRY is answered in the same transaction from the registry; a REPLY resolves the
    /// pending request it references, refunding the customer when denied.
    function onDomainMessage(uint64 sourceChainId, address from, bytes calldata data) external {
        require(msg.sender == address(SPOKE), "L2Bank: not spoke");
        require(sourceChainId == peerChainId && from == peerBank, "L2Bank: not the peer bank");

        uint8 kind = abi.decode(data, (uint8));
        if (kind == KIND_INQUIRY) {
            (, uint256 requestId,, address recipient, uint256 amountOut) =
                abi.decode(data, (uint8, uint256, address, address, uint256));
            bool approved = receiveAllowance[recipient] >= amountOut;
            if (approved) receiveAllowance[recipient] -= amountOut;
            _sendToPeer(abi.encode(KIND_REPLY, requestId, approved));
            emit InquiryAnswered(requestId, recipient, amountOut, approved);
        } else if (kind == KIND_REPLY) {
            (, uint256 requestId, bool approved) = abi.decode(data, (uint8, uint256, bool));
            Request storage request = requests[requestId];
            require(request.status == RequestStatus.PendingKyc, "L2Bank: request not pending");
            if (approved) {
                request.status = RequestStatus.Approved;
            } else {
                request.status = RequestStatus.Denied;
                ledger().safeTransfer(request.user, request.amountIn);
                emit RequestRefunded(requestId, request.user, request.amountIn);
            }
            emit ReplyReceived(requestId, approved);
        } else {
            revert("L2Bank: unknown message kind");
        }
    }

    /// @dev Routes `payload` to the peer bank through the hub.
    function _sendToPeer(bytes memory payload) internal {
        SPOKE.sendDomainMessage(peerChainId, peerBank, payload);
    }
}
