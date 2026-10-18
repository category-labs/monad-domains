// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDomainHub, IDomainMessageReceiver} from "../interfaces/IDomain.sol";
import {MessageLib} from "../libraries/MessageLib.sol";

/// @notice Receives the notification a memo withdrawal carries, after the tokens arrived.
interface IBridgedTokenReceiver {
    /// @notice Called by the DemoL1Bridge once `amount` of `token` has been transferred to
    /// the receiver by a withdrawal that carried `memo`. Reverting leaves the whole
    /// withdrawal retryable at the hub; nothing is released.
    function onBridgedTokens(address token, uint256 amount, bytes32 memo) external;
}

/// @notice The bank demo's L1 bridge: the reference lock-and-mint L1Bridge, plus a withdrawal
/// payload variant that carries a memo and notifies a contract recipient in the same
/// transaction. That hook is what lets the liquidity pool settle a lock atomically with the
/// withdrawal that pays for it.
///
/// Payloads: a plain withdrawal is `MessageLib.encodeTransfer` (96 bytes). A memo withdrawal
/// is `abi.encode(recipient, token, amount, memo)` (128 bytes); after the transfer the
/// recipient's `onBridgedTokens` runs if it has code.
contract DemoL1Bridge is Ownable, IDomainMessageReceiver {
    using SafeERC20 for IERC20;

    IDomainHub public immutable HUB;

    /// @notice The single domain this bridge serves.
    uint64 public immutable DOMAIN_CHAIN_ID;

    /// @notice Counterpart DemoDomainBridge on `DOMAIN_CHAIN_ID`.
    address public domainBridge;

    /// @notice Tokens accepted for new deposits. Never checked on withdrawals.
    mapping(address => bool) public allowedTokens;

    event DomainBridgeRegistered(address bridge);
    event TokenAllowlistUpdated(address indexed token, bool allowed);
    event BridgeInitiated(address indexed sender, address recipient, address indexed token, uint256 amount);
    event WithdrawalFinalized(address indexed recipient, address indexed token, uint256 amount, bytes32 memo);

    constructor(IDomainHub hub, uint64 domainChainId) Ownable(msg.sender) {
        HUB = hub;
        DOMAIN_CHAIN_ID = domainChainId;
    }

    /// @notice Sets the counterpart bridge. One-shot: cannot be changed once set.
    function registerDomainBridge(address bridge) external onlyOwner {
        require(bridge != address(0), "DemoL1Bridge: zero bridge");
        require(domainBridge == address(0), "DemoL1Bridge: already registered");
        domainBridge = bridge;
        emit DomainBridgeRegistered(bridge);
    }

    /// @notice Allows or disallows a token for new deposits.
    function setTokenAllowed(address token, bool allowed) external onlyOwner {
        allowedTokens[token] = allowed;
        emit TokenAllowlistUpdated(token, allowed);
    }

    /// @notice Locks `amount` of `token` and sends a transfer message to the counterpart
    /// bridge; the protocol delivers it and the bridged token is minted to `recipient`.
    function bridgeToDomain(address recipient, address token, uint256 amount) external {
        address counterpart = domainBridge;
        require(counterpart != address(0), "DemoL1Bridge: counterpart not registered");
        require(allowedTokens[token], "DemoL1Bridge: token not allowed");
        require(recipient != address(0), "DemoL1Bridge: zero recipient");
        require(amount > 0, "DemoL1Bridge: zero amount");

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        require(
            IERC20(token).balanceOf(address(this)) - balanceBefore == amount,
            "DemoL1Bridge: fee-on-transfer token not supported"
        );

        HUB.sendL1Message(DOMAIN_CHAIN_ID, counterpart, MessageLib.encodeTransfer(recipient, token, amount));
        emit BridgeInitiated(msg.sender, recipient, token, amount);
    }

    /// @notice Receives a withdrawal authenticated and delivered by the hub, releases the
    /// collateral, and - for memo withdrawals - notifies a contract recipient.
    function onDomainMessage(uint64 domainChainId, address from, bytes calldata data) external {
        require(msg.sender == address(HUB), "DemoL1Bridge: not hub");
        require(domainChainId == DOMAIN_CHAIN_ID, "DemoL1Bridge: wrong domain");
        address counterpart = domainBridge;
        require(counterpart != address(0), "DemoL1Bridge: counterpart not registered");
        require(from == counterpart, "DemoL1Bridge: not from domain bridge");

        (address recipient, address token, uint256 amount, bytes32 memo) = decodeWithdrawal(data);
        IERC20(token).safeTransfer(recipient, amount);
        if (data.length == 128 && recipient.code.length != 0) {
            IBridgedTokenReceiver(recipient).onBridgedTokens(token, amount, memo);
        }
        emit WithdrawalFinalized(recipient, token, amount, memo);
    }

    /// @notice Payload of a memo withdrawal, as the DemoDomainBridge records it.
    function encodeMemoWithdrawal(address recipient, address token, uint256 amount, bytes32 memo)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(recipient, token, amount, memo);
    }

    /// @notice Decodes either withdrawal payload; a plain transfer has a zero memo.
    function decodeWithdrawal(bytes calldata data)
        public
        pure
        returns (address recipient, address token, uint256 amount, bytes32 memo)
    {
        if (data.length == 128) {
            (recipient, token, amount, memo) = abi.decode(data, (address, address, uint256, bytes32));
        } else {
            require(data.length == 96, "DemoL1Bridge: bad withdrawal payload");
            (recipient, token, amount) = MessageLib.decodeTransfer(data);
        }
    }
}
