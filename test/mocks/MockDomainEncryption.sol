// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDomainSpoke} from "../../src/interfaces/IDomain.sol";
import {IDomainEncryption} from "../../src/interfaces/IDomainEncryption.sol";

/// @dev Test double for the encryption precompile, etched at `DOMAIN_ENCRYPTION_PRECOMPILE`.
/// Reads the destination's key from the calling spoke and "seals" by prefixing the plaintext
/// with the sealer, destination, sequence number and key hash, so a test can open the
/// ciphertext with `openMessage`.
contract MockDomainEncryption is IDomainEncryption {
    /// @dev Number of successful seals.
    uint256 public seals;

    function sealMessage(uint64 destinationChainId, uint256 sequenceNumber, bytes calldata plaintext)
        external
        returns (bytes memory ciphertext)
    {
        bytes memory viewingKey = IDomainSpoke(msg.sender).viewingKeys(destinationChainId);
        require(viewingKey.length != 0, "MockDomainEncryption: unknown viewing key");
        seals++;
        return abi.encode(msg.sender, destinationChainId, sequenceNumber, keccak256(viewingKey), plaintext);
    }

    /// @dev Opens a ciphertext produced by `sealMessage`.
    function openMessage(bytes calldata ciphertext)
        external
        pure
        returns (
            address sealer,
            uint64 destinationChainId,
            uint256 sequenceNumber,
            bytes32 viewingKeyHash,
            bytes memory plaintext
        )
    {
        return abi.decode(ciphertext, (address, uint64, uint256, bytes32, bytes));
    }
}
