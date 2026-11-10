// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDomainEncryption} from "../../src/interfaces/IDomainEncryption.sol";

/// @dev Test double for the encryption precompile, etched at `DOMAIN_ENCRYPTION_PRECOMPILE`.
/// "Seals" by prefixing the plaintext with the sealer, destination and sequence number, so a
/// test can open the ciphertext with `openMessage`.
contract MockDomainEncryption is IDomainEncryption {
    /// @dev Viewing key of each domain this precompile can seal to.
    mapping(uint64 => bytes) public viewingKeys;
    /// @dev Number of successful seals.
    uint256 public seals;

    function setViewingKey(uint64 domainChainId, bytes calldata viewingKey) external {
        viewingKeys[domainChainId] = viewingKey;
    }

    function sealMessage(uint64 destinationChainId, uint256 sequenceNumber, bytes calldata plaintext)
        external
        returns (bytes memory ciphertext)
    {
        require(viewingKeys[destinationChainId].length != 0, "MockDomainEncryption: unknown viewing key");
        seals++;
        return abi.encode(msg.sender, destinationChainId, sequenceNumber, plaintext);
    }

    /// @dev Opens a ciphertext produced by `sealMessage`.
    function openMessage(bytes calldata ciphertext)
        external
        pure
        returns (address sealer, uint64 destinationChainId, uint256 sequenceNumber, bytes memory plaintext)
    {
        return abi.decode(ciphertext, (address, uint64, uint256, bytes));
    }
}
