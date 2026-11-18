// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev A domain's config word in its input queue:
/// `zero(24) | maxUnattestedPeriods(8) | checkpointInterval(64) | feeRecipient(160)`; zero for an
/// unregistered domain.
type QueueConfig is uint256;

using QueueConfigLib for QueueConfig global;

// Each narrowing cast below picks one field out of the word.
// forge-lint: disable-next-item(unsafe-typecast)
library QueueConfigLib {
    function pack(address recipient, uint64 interval, uint8 maxPeriods) internal pure returns (QueueConfig) {
        return QueueConfig.wrap((uint256(maxPeriods) << 224) | (uint256(interval) << 160) | uint160(recipient));
    }

    function isRegistered(QueueConfig config) internal pure returns (bool) {
        return QueueConfig.unwrap(config) != 0;
    }

    function feeRecipient(QueueConfig config) internal pure returns (address) {
        return address(uint160(QueueConfig.unwrap(config)));
    }

    function checkpointInterval(QueueConfig config) internal pure returns (uint64) {
        return uint64(QueueConfig.unwrap(config) >> 160);
    }

    function maxUnattestedPeriods(QueueConfig config) internal pure returns (uint8) {
        return uint8(QueueConfig.unwrap(config) >> 224);
    }
}
