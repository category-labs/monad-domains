// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Canonical encoding of cross-domain messages and of the token bridge payload
/// carried inside them. Single source of truth shared by both bridges, the hub and spoke,
/// and the off-chain prover.
library MessageLib {
    /// @notice An authenticated domain-origin message. The source spoke assigns origin and nonce.
    /// The hub proves this envelope and assigns a separate destination delivery nonce when forwarding.
    /// The destination selects L1 execution or domain forwarding.
    struct DomainMessage {
        uint64 sourceChainId;
        uint64 destinationChainId;
        address from;
        address to;
        uint256 sourceNonce;
        bytes data;
    }

    /// @notice Binds the envelope to one protocol deployment as well as both domains.
    function hashDomainMessage(DomainMessage memory message, uint256 l1ChainId, address hub)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                l1ChainId,
                hub,
                message.sourceChainId,
                message.destinationChainId,
                message.from,
                message.to,
                message.sourceNonce,
                keccak256(message.data)
            )
        );
    }

    /// @notice Shared delivery envelope for L1-origin and forwarded domain messages.
    /// The hub authenticates sourceChainId/from and assigns a destination queue nonce.
    /// `to` is always the destination application; data is its original payload.
    struct Message {
        uint64 sourceChainId;
        address from;
        address to;
        bytes data;
        uint256 nonce;
    }

    /// @notice Delivery hash binds the authenticated origin, target, payload and queue nonce.
    function hashMessage(Message memory message) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(message.sourceChainId, message.from, message.to, keccak256(message.data), message.nonce)
        );
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
