// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {ICommonErrors} from "./ICommonErrors.sol";
import {IDomainHub} from "./IDomain.sol";

/// @notice L1 side of the lock-and-mint token bridge, as other L1 contracts use it: deposits to
/// the domain, and the configuration a caller can check first.
interface IL1Bridge is ICommonErrors {
    event DomainBridgeRegistered(address bridge);
    event TokenAllowlistUpdated(address indexed token, bool allowed);
    event BridgeInitiated(address indexed sender, address recipient, address indexed token, uint256 amount);
    event WithdrawalFinalized(address indexed recipient, address indexed token, uint256 amount);

    /// @notice No counterpart DomainBridge is registered yet.
    error CounterpartNotRegistered();
    /// @notice The token is not allowed for new deposits.
    error TokenNotAllowed();
    /// @notice The bridge's balance did not grow by exactly the amount: fee-on-transfer tokens are
    /// not supported.
    error FeeOnTransferTokenNotSupported();

    /// @notice Hub that carries this bridge's messages.
    function HUB() external view returns (IDomainHub);

    /// @notice The single domain this bridge serves.
    function DOMAIN_CHAIN_ID() external view returns (uint64);

    /// @notice Counterpart DomainBridge on `DOMAIN_CHAIN_ID`, or zero until it is registered.
    function domainBridge() external view returns (address);

    /// @notice Whether `token` is accepted for new deposits. Never checked on withdrawals.
    function allowedTokens(address token) external view returns (bool);

    /// @notice Locks `amount` of `token` and sends a transfer message to the counterpart
    /// bridge, which mints the bridged token to `recipient` on the domain. `msg.value` is the
    /// delivery fee forwarded to the hub; it must buy enough gas for the mint.
    /// @dev The hub's errors, such as `IDomainHub.DeliveryFeeTooLow`, reach the caller unchanged.
    function bridgeToDomain(address recipient, address token, uint256 amount) external payable;
}
