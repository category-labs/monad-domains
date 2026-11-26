// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

/// @notice Errors many of the protocol's contracts share. Every interface that outside contracts
/// call inherits it, so these errors appear in its ABI.
/// @dev Errors only the hub and the spoke share sit in `IMessagingErrors`. Any other error sits
/// with the function that throws it: in the interface that declares the function, otherwise in
/// the contract. Interfaces that outside contracts implement, such as
/// `IDomainMessageReceiver`, declare no errors, so their names cannot clash with an
/// implementer's own errors.
interface ICommonErrors {
    /// @notice `caller` may not make this call.
    error Unauthorized(address caller);
    /// @notice A required address is zero.
    error ZeroAddress();
    /// @notice The amount is zero.
    error ZeroAmount();
    /// @notice `chainId` cannot be used here: a domain with the L1's chain id, a message whose
    /// source and destination are the same, a message from a chain the receiver does not accept,
    /// or the destination of a message retried on another chain.
    error InvalidChainId(uint64 chainId);
}
