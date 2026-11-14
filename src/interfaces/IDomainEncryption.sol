// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Address of the execution client's encryption precompile on every domain.
address constant DOMAIN_ENCRYPTION_PRECOMPILE = 0x0000000000000000000000000000000000001a7e;

/// @notice Encryption precompile of the domain execution client. It reads destination viewing
/// keys from the spoke's `viewingKeys` and seals with randomness derived from the domain's
/// secret seed and the call's inputs, so every replica computes the same ciphertext. Absent on
/// the L1.
interface IDomainEncryption {
    /// @notice Seals `plaintext` to `destinationChainId`'s viewing key, bound to the executing
    /// domain, the destination and `sequenceNumber` (the spoke's source nonce) so it opens only
    /// as that message. MUST revert for an unknown destination key. MUST NOT be reachable
    /// through DELEGATECALL or CALLCODE.
    function sealMessage(uint64 destinationChainId, uint256 sequenceNumber, bytes calldata plaintext)
        external
        returns (bytes memory ciphertext);
}
