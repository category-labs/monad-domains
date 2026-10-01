// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Canonical encoding of cross-domain messages and of the token bridge payload
/// carried inside them. Single source of truth shared by both bridges, the hub and spoke,
/// and the off-chain prover.
library MessageLib {
    /// @notice Preimage of a recorded message hash. This is what a prover submits when
    /// consuming a message on the destination chain.
    /// @param from  The account that called the hub/spoke send function on the source chain.
    /// @param to    The target contract on the destination chain (for the token bridge,
    ///              always the counterpart bridge contract).
    /// @param data  Application calldata; the token bridge carries an encoded payload here.
    /// @param nonce Nonce assigned by the hub/spoke at recording time.
    struct Message {
        address from;
        address to;
        bytes data;
        uint256 nonce;
    }

    /// @notice Message hash format defined by the MIP for both directions.
    function hashMessage(Message memory message) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(message.from, message.to, keccak256(message.data), message.nonce));
    }

    /// @notice Encodes the token bridge payload placed in `Message.data`. The recipient
    /// lives here (not in `Message.to`) so the receiving bridge can authenticate both
    /// `from` and `to` as the two bridge contracts.
    function encodeTransfer(address recipient, address l1Token, uint256 amount) internal pure returns (bytes memory) {
        return abi.encode(recipient, l1Token, amount);
    }

    /// @notice Decodes a token bridge payload produced by `encodeTransfer`.
    function decodeTransfer(bytes memory data)
        internal
        pure
        returns (address recipient, address l1Token, uint256 amount)
    {
        (recipient, l1Token, amount) = abi.decode(data, (address, address, uint256));
    }
}
