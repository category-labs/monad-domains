// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {ICommonErrors} from "./ICommonErrors.sol";
import {IDomainSpoke} from "./IDomain.sol";

/// @notice Domain side of the lock-and-mint token bridge, as other domain contracts use it:
/// withdrawals to the L1, and the configuration a caller can check first.
interface IDomainBridge is ICommonErrors {
    event BridgedTokenDeployed(address indexed l1Token, address token);
    event DepositFinalized(address indexed recipient, address indexed l1Token, uint256 amount);
    event WithdrawalInitiated(
        address indexed sender, address recipient, address indexed l1Token, uint256 amount, bytes32 indexed messageId
    );

    /// @notice No bridged token exists for the L1 token.
    error UnknownToken();

    /// @notice Spoke that delivers deposits to this bridge and records its withdrawals.
    function SPOKE() external view returns (IDomainSpoke);

    /// @notice Counterpart L1Bridge: the only sender this bridge takes deposits from.
    function L1_BRIDGE() external view returns (address);

    /// @notice Policy owner of every bridged token this bridge deploys.
    function TOKEN_POLICY_OWNER() external view returns (address);

    /// @notice Access policy every bridged token starts with.
    function INITIAL_TOKEN_POLICY() external view returns (address);

    /// @notice Bridged token for `l1Token`, or zero until the first deposit of `l1Token` deploys it.
    function bridgedTokens(address l1Token) external view returns (address);

    /// @notice Burns `amount` of the bridged token for `l1Token` and sends a withdrawal
    /// message to the counterpart L1Bridge, which releases the locked L1 tokens to
    /// `recipient` once the message is proven there.
    /// @param salt Fresh cryptographically random bytes, kept private until relay.
    /// @dev The spoke's errors, such as `IDomainSpoke.ZeroSalt`, reach the caller unchanged.
    function bridgeToL1(address recipient, address l1Token, uint256 amount, bytes32 salt) external;
}
