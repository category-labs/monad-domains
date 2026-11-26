// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDomainHub} from "../interfaces/IDomain.sol";
import {IDomainMessageReceiver} from "../interfaces/IDomainMessageReceiver.sol";
import {IL1Bridge} from "../interfaces/IL1Bridge.sol";
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
contract L1Bridge is IL1Bridge, Ownable, IDomainMessageReceiver {
    /// @notice The counterpart DomainBridge is already registered.
    error BridgeAlreadyRegistered();
    /// @notice The message was not sent by the counterpart DomainBridge.
    error NotDomainBridge();

    using SafeERC20 for IERC20;

    IDomainHub public immutable HUB;

    /// @notice The single domain this bridge serves.
    uint64 public immutable DOMAIN_CHAIN_ID;

    /// @notice Counterpart DomainBridge on `DOMAIN_CHAIN_ID`.
    address public domainBridge;

    /// @notice Tokens accepted for new deposits. Never checked on withdrawals.
    mapping(address token => bool allowed) public allowedTokens;

    constructor(IDomainHub hub, uint64 domainChainId) Ownable(msg.sender) {
        HUB = hub;
        DOMAIN_CHAIN_ID = domainChainId;
    }

    /// @notice Sets the counterpart bridge. One-shot: cannot be changed once set.
    function registerDomainBridge(address bridge) external onlyOwner {
        if (bridge == address(0)) revert ZeroAddress();
        if (domainBridge != address(0)) revert BridgeAlreadyRegistered();
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

    function bridgeToDomain(address recipient, address token, uint256 amount) external payable {
        address counterpart = domainBridge;
        if (counterpart == address(0)) revert CounterpartNotRegistered();
        if (!allowedTokens[token]) revert TokenNotAllowed();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // The locked amount must equal the messaged amount, or withdrawals would be
        // undercollateralized - reject fee-on-transfer tokens.
        IERC20 asset = IERC20(token);
        uint256 balanceBefore = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        if (asset.balanceOf(address(this)) - balanceBefore != amount) revert FeeOnTransferTokenNotSupported();

        HUB.sendL1Message{value: msg.value}(
            DOMAIN_CHAIN_ID, counterpart, MessageLib.encodeTransfer(recipient, token, amount)
        );
        emit BridgeInitiated(msg.sender, recipient, token, amount);
    }

    /// @notice Receives a withdrawal authenticated and delivered by the hub. The protocol
    /// verifies inclusion and prevents replay; the bridge authorizes its source and releases
    /// collateral. Reverting leaves the message retryable at the hub, and every step here
    /// reverts on failure, so a relay with too little gas can never consume the withdrawal
    /// without releasing the tokens.
    function onDomainMessage(uint64 domainChainId, address from, bytes calldata data) external {
        if (msg.sender != address(HUB)) revert Unauthorized(msg.sender);
        if (domainChainId != DOMAIN_CHAIN_ID) revert InvalidChainId(domainChainId);
        address counterpart = domainBridge;
        if (counterpart == address(0)) revert CounterpartNotRegistered();
        if (from != counterpart) revert NotDomainBridge();

        (address recipient, address token, uint256 amount) = MessageLib.decodeTransfer(data);
        IERC20(token).safeTransfer(recipient, amount);
        emit WithdrawalFinalized(recipient, token, amount);
    }
}
