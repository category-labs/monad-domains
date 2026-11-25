// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

// Address of the execution client's encryption precompile on every domain.
address constant DOMAIN_ENCRYPTION_PRECOMPILE = 0x0000000000000000000000000000000000001a7e;

/// @notice Encryption precompile of the domain execution client. It reads destination encryption
/// public keys from the spoke's `encryptionPubKeys` and seals deterministically, so every replica
/// computes the same ciphertext. Absent on the L1.
interface IDomainEncryption {
    /// @notice Seals `plaintext` to `destinationChainId`'s encryption public key, with the
    /// executing domain, the destination and `sequenceNumber` (the spoke's source nonce) as
    /// associated data, so it opens only as that message.
    /// @dev The randomness MUST be derived from the domain's secret seed, the caller, the
    /// destination key, the associated data and the whole plaintext. Binding the caller keeps
    /// any other contract from reproducing a ciphertext the spoke recorded, which would confirm
    /// a guess of the sender, target and payload it seals. Binding the plaintext matters because
    /// a reverted send leaves its sequence number to the next one. MUST revert for an unknown
    /// destination key and on any other failure, never return an empty ciphertext. MUST NOT be
    /// reachable through DELEGATECALL, CALLCODE or STATICCALL, or with value.
    function sealMessage(uint64 destinationChainId, uint256 sequenceNumber, bytes calldata plaintext)
        external
        returns (bytes memory ciphertext);
}
