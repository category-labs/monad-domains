// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDomainHub, IDomainMessageReceiver} from "../interfaces/IDomain.sol";
import {MessageLib} from "../libraries/MessageLib.sol";

/// @notice L1 side of the lock-and-mint token bridge. Locks ERC20 tokens and
/// sends a transfer message to the counterpart DomainBridge through the domain hub.
///
/// One L1Bridge is deployed per domain, so locked assets are isolated: this contract
/// only ever holds collateral for `DOMAIN_CHAIN_ID`.
///
/// The owner controls which tokens may be bridged (deposit allowlist) and performs the
/// one-shot counterpart registration. Deliberately, the owner can only gate NEW
/// deposits: `onDomainMessage` never consults the allowlist, so already-locked
/// collateral can always be withdrawn and the owner can never freeze user funds.
contract L1Bridge is Ownable, IDomainMessageReceiver {
    using SafeERC20 for IERC20;

    IDomainHub public immutable HUB;

    /// @notice The single domain this bridge serves.
    uint64 public immutable DOMAIN_CHAIN_ID;

    /// @notice Counterpart DomainBridge on `DOMAIN_CHAIN_ID`.
    address public domainBridge;

    /// @notice Tokens accepted for new deposits. Never checked on withdrawals.
    mapping(address => bool) public allowedTokens;

    event DomainBridgeRegistered(address bridge);
    event TokenAllowlistUpdated(address indexed token, bool allowed);
    event BridgeInitiated(address indexed sender, address recipient, address indexed token, uint256 amount);
    event WithdrawalFinalized(address indexed recipient, address indexed token, uint256 amount);

    constructor(IDomainHub hub, uint64 domainChainId) Ownable(msg.sender) {
        HUB = hub;
        DOMAIN_CHAIN_ID = domainChainId;
    }

    /// @notice Sets the counterpart bridge. One-shot: cannot be changed once set.
    function registerDomainBridge(address bridge) external onlyOwner {
        require(bridge != address(0), "L1Bridge: zero bridge");
        require(domainBridge == address(0), "L1Bridge: already registered");
        domainBridge = bridge;
        emit DomainBridgeRegistered(bridge);
    }

    /// @notice Allows or disallows a token for new deposits. Disallowing a token stops
    /// future `bridgeToDomain` calls for it but has no effect on withdrawals of
    /// already-locked collateral.
    function setTokenAllowed(address token, bool allowed) external onlyOwner {
        allowedTokens[token] = allowed;
        emit TokenAllowlistUpdated(token, allowed);
    }

    /// @notice Locks `amount` of `token` and sends a transfer message to the counterpart
    /// bridge, which mints the bridged token to `recipient` on the domain.
    function bridgeToDomain(address recipient, address token, uint256 amount) external {
        address counterpart = domainBridge;
        require(counterpart != address(0), "L1Bridge: counterpart not registered");
        require(allowedTokens[token], "L1Bridge: token not allowed");
        require(recipient != address(0), "L1Bridge: zero recipient");
        require(amount > 0, "L1Bridge: zero amount");

        // The locked amount must equal the messaged amount, or withdrawals would be
        // undercollateralized - reject fee-on-transfer tokens.
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        require(
            IERC20(token).balanceOf(address(this)) - balanceBefore == amount,
            "L1Bridge: fee-on-transfer token not supported"
        );

        HUB.sendL1Message(DOMAIN_CHAIN_ID, counterpart, MessageLib.encodeTransfer(recipient, token, amount));
        emit BridgeInitiated(msg.sender, recipient, token, amount);
    }

    /// @notice Receives a withdrawal authenticated and delivered by the hub. The protocol
    /// verifies inclusion and prevents replay; the bridge authorizes its source and releases
    /// collateral. Reverting leaves the message retryable at the hub.
    function onDomainMessage(uint64 domainChainId, address from, bytes calldata data) external {
        require(msg.sender == address(HUB), "L1Bridge: not hub");
        require(domainChainId == DOMAIN_CHAIN_ID, "L1Bridge: wrong domain");
        address counterpart = domainBridge;
        require(counterpart != address(0), "L1Bridge: counterpart not registered");
        require(from == counterpart, "L1Bridge: not from domain bridge");

        (address recipient, address token, uint256 amount) = MessageLib.decodeTransfer(data);
        IERC20(token).safeTransfer(recipient, amount);
        emit WithdrawalFinalized(recipient, token, amount);
    }
}
