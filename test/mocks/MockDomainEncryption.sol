// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IDomainSpoke} from "../../src/interfaces/IDomain.sol";
import {IDomainEncryption} from "../../src/interfaces/IDomainEncryption.sol";

/// @dev Test double for the encryption precompile, etched at `DOMAIN_ENCRYPTION_PRECOMPILE`.
/// Reads the destination's key from the calling spoke's storage, as the client does, and
/// "seals" by prefixing the plaintext with the sealer, its domain, the destination, the
/// sequence number and the key, so a test can open the ciphertext with `openMessage`.
contract MockDomainEncryption is IDomainEncryption {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    /// @dev Slot of the spoke's `viewingKeys` mapping.
    uint256 private constant VIEWING_KEYS_SLOT = 7;

    /// @dev Number of successful seals.
    uint256 public seals;

    function sealMessage(uint64 destinationChainId, uint256 sequenceNumber, bytes calldata plaintext)
        external
        returns (bytes memory ciphertext)
    {
        bytes32 viewingKey = VM.load(msg.sender, keccak256(abi.encode(uint256(destinationChainId), VIEWING_KEYS_SLOT)));
        require(viewingKey != bytes32(0), "MockDomainEncryption: unknown viewing key");
        seals++;
        return abi.encode(
            msg.sender,
            IDomainSpoke(msg.sender).DOMAIN_CHAIN_ID(),
            destinationChainId,
            sequenceNumber,
            viewingKey,
            plaintext
        );
    }

    /// @dev Opens a ciphertext produced by `sealMessage`.
    function openMessage(bytes calldata ciphertext)
        external
        pure
        returns (
            address sealer,
            uint64 sourceChainId,
            uint64 destinationChainId,
            uint256 sequenceNumber,
            bytes32 viewingKey,
            bytes memory plaintext
        )
    {
        return abi.decode(ciphertext, (address, uint64, uint64, uint256, bytes32, bytes));
    }
}
