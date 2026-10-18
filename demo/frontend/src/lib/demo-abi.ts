import { parseAbi } from "viem";

/**
 * The slices of the demo contract ABIs the operator service and the frontend use. Kept
 * inline so the long-running service needs no Foundry artifacts at runtime; the deploy
 * script (which needs bytecode) loads the full artifacts instead.
 */
export const L2_BANK_ABI = parseAbi([
  "function BANK() view returns (address)",
  "function POOL() view returns (address)",
  "function L1_TOKEN() view returns (address)",
  "function peerChainId() view returns (uint64)",
  "function peerBank() view returns (address)",
  "function receiveAllowance(address user) view returns (uint256)",
  "function nextRequestId() view returns (uint256)",
  "function requests(uint256 requestId) view returns (address user, address recipient, uint256 amountOut, uint256 amountIn, bool expireLock, uint8 status, uint256 lockId)",
  "function ledger() view returns (address)",
  "function quoteIn(uint256 amountOut) view returns (uint256)",
  "function registerPeer(uint64 chainId, address bank)",
  "function setReceiveAllowance(address user, uint256 limit)",
  "function requestTransfer(address recipient, uint256 amountOut, bool expireLock) returns (uint256 requestId)",
  "function executePayment(uint256 requestId, uint256 lockId)",
  "event PeerRegistered(uint64 chainId, address bank)",
  "event ReceiveAllowanceSet(address indexed user, uint256 limit)",
  "event TransferRequested(uint256 indexed requestId, address indexed user, address indexed recipient, uint256 amountOut, uint256 amountIn, bool expireLock)",
  "event InquiryAnswered(uint256 indexed requestId, address indexed recipient, uint256 amountOut, bool approved)",
  "event ReplyReceived(uint256 indexed requestId, bool approved)",
  "event PaymentExecuted(uint256 indexed requestId, uint256 amountIn, uint256 lockId)",
  "event RequestRefunded(uint256 indexed requestId, address indexed user, uint256 amountIn)",
]);

/** `L2Bank.RequestStatus`. */
export const REQUEST_STATUS = ["none", "pendingKyc", "approved", "denied", "paid"] as const;
export type RequestStatus = (typeof REQUEST_STATUS)[number];

export const POOL_ABI = parseAbi([
  "function TOKEN_IN() view returns (address)",
  "function TOKEN_OUT() view returns (address)",
  "function RATE_NUM() view returns (uint256)",
  "function RATE_DEN() view returns (uint256)",
  "function locker() view returns (address)",
  "function nextLockId() view returns (uint256)",
  "function locks(uint256 lockId) view returns (uint256 amountIn, uint256 amountOut, address recipientOnDest, address refundTo, uint64 expiry, uint8 state)",
  "function lockedOut() view returns (uint256)",
  "function lockIdByRequest(bytes32 requestKey) view returns (uint256)",
  "function availableOut() view returns (uint256)",
  "function quoteIn(uint256 amountOut) view returns (uint256)",
  "function lockLiquidity(uint256 amountOut, address recipientOnDest, address refundTo, uint64 ttlSeconds, bytes32 requestKey) returns (uint256 lockId, uint256 amountIn)",
  "function cancelExpiredLock(uint256 lockId)",
  "function setLocker(address locker)",
  "event LiquidityLocked(uint256 indexed lockId, bytes32 indexed requestKey, uint256 amountIn, uint256 amountOut, address indexed recipientOnDest, address refundTo, uint64 expiry)",
  "event LockSettled(uint256 indexed lockId, address indexed recipientOnDest, uint256 amountOut)",
  "event LockRefunded(uint256 indexed lockId, address indexed refundTo, uint256 amountIn)",
  "event LockCancelled(uint256 indexed lockId)",
]);

/** `LockingLiquidityPool.LockState`. */
export const LOCK_STATE = ["none", "pending", "settled", "refunded", "cancelled"] as const;
export type LockState = (typeof LOCK_STATE)[number];

export const DEMO_L1_BRIDGE_ABI = parseAbi([
  "function DOMAIN_CHAIN_ID() view returns (uint64)",
  "function domainBridge() view returns (address)",
  "function allowedTokens(address token) view returns (bool)",
  "function registerDomainBridge(address bridge)",
  "function setTokenAllowed(address token, bool allowed)",
  "function bridgeToDomain(address recipient, address token, uint256 amount)",
  "event BridgeInitiated(address indexed sender, address recipient, address indexed token, uint256 amount)",
  "event WithdrawalFinalized(address indexed recipient, address indexed token, uint256 amount, bytes32 memo)",
]);

export const DEMO_DOMAIN_BRIDGE_ABI = parseAbi([
  "function L1_BRIDGE() view returns (address)",
  "function bridgedTokens(address l1Token) view returns (address)",
  "function bridgeToL1(address recipient, address l1Token, uint256 amount)",
  "function bridgeToL1WithMemo(address recipient, address l1Token, uint256 amount, bytes32 memo)",
  "event BridgedTokenDeployed(address indexed l1Token, address token)",
  "event DepositFinalized(address indexed recipient, address indexed l1Token, uint256 amount)",
  "event WithdrawalInitiated(address indexed sender, address recipient, address indexed l1Token, uint256 amount, bytes32 memo)",
]);

export const ERC20_ABI = parseAbi([
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function transfer(address to, uint256 amount) returns (bool)",
  "function mint(address to, uint256 amount)",
  "event Transfer(address indexed from, address indexed to, uint256 value)",
]);

export const SPOKE_EVENTS_ABI = parseAbi([
  "event DomainMessageRecorded(bytes32 indexed messageId, bytes message)",
  "event L1MessageRelayed(bytes32 indexed messageHash, uint64 sourceChainId, address indexed from, address indexed to, uint256 nonce, bool success)",
]);

export const HUB_ABI = parseAbi([
  "function sequenceToDomain(uint64 domainChainId, bytes rlpTx) payable",
  "function domainBlockNumbers(uint64 domainChainId) view returns (uint64)",
  "function relayedDomainMessages(uint64 domainChainId, bytes32 messageHash) view returns (bool)",
  "function failedDomainMessages(uint64 domainChainId, bytes32 messageHash) view returns (bool)",
  "event DomainTransactionSequenced(uint64 indexed domainChainId, bytes rlpTx, uint256 fee)",
  "event DomainStateUpdated(uint64 indexed domainChainId, uint256 stateNonce, uint64 domainBlockNumber, bytes32 newStateRoot, bytes32 domainAnchor)",
  "event DomainMessageRouted(bytes32 indexed messageId, uint64 indexed sourceChainId, uint64 indexed destinationChainId, uint256 deliveryNonce)",
  "event DomainMessageRelayed(uint64 indexed domainChainId, bytes32 indexed messageHash, address indexed from, address to, uint256 nonce, bool success)",
  "event L1MessageRecorded(uint64 indexed domainChainId, uint64 sourceChainId, address indexed from, address indexed to, bytes data, uint256 nonce, bytes32 messageHash)",
]);

export const SPOKE_ABI = parseAbi([
  "event DomainMessageRecorded(bytes32 indexed messageId, bytes message)",
  "event L1MessageRelayed(bytes32 indexed messageHash, uint64 sourceChainId, address indexed from, address indexed to, uint256 nonce, bool success)",
]);
