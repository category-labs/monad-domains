// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

/// @notice Shared hook for L1-origin and domain-origin messages. Authenticate msg.sender
/// (the hub on L1, local spoke on a domain), sourceChainId and from together.
/// @dev Do all the work or revert. Whoever relays, pays for or retries a delivery chooses the
/// gas this call gets. A revert leaves the message retryable; returning normally consumes it
/// for good. A receiver that carries on after a failed inner call (`try/catch`, an unchecked
/// low-level call) can be given just enough gas to finish without that call, so it must
/// first check that `gasleft()` covers it.
interface IDomainMessageReceiver {
    function onDomainMessage(uint64 sourceChainId, address from, bytes calldata data) external;
}
