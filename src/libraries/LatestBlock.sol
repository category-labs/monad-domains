// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev A domain's latest block word in its input queue:
/// `gasSold(64) | inputWords(64) | l1BlockNumber(64) | domainBlockNumber(64)`. `gasSold` and
/// `inputWords` count what the domain has taken in L1 block `l1BlockNumber`.
type LatestBlock is uint256;

using LatestBlockLib for LatestBlock global;

// Each narrowing cast below picks one field out of the word.
// forge-lint: disable-next-item(unsafe-typecast)
library LatestBlockLib {
    /// @dev The word of domain block `domainBlock`, opened in L1 block `l1Block` with nothing
    /// taken yet.
    function open(uint64 l1Block, uint64 domainBlock) internal pure returns (LatestBlock) {
        return LatestBlock.wrap((uint256(l1Block) << 64) | domainBlock);
    }

    /// @dev `latest` with its counts set to `sold` and `words`, which must fit in 64 bits.
    function withUsage(LatestBlock latest, uint256 sold, uint256 words) internal pure returns (LatestBlock) {
        return LatestBlock.wrap((sold << 192) | (words << 128) | uint128(LatestBlock.unwrap(latest)));
    }

    function gasSold(LatestBlock latest) internal pure returns (uint64) {
        return uint64(LatestBlock.unwrap(latest) >> 192);
    }

    function inputWords(LatestBlock latest) internal pure returns (uint64) {
        return uint64(LatestBlock.unwrap(latest) >> 128);
    }

    function l1BlockNumber(LatestBlock latest) internal pure returns (uint64) {
        return uint64(LatestBlock.unwrap(latest) >> 64);
    }

    function domainBlockNumber(LatestBlock latest) internal pure returns (uint64) {
        return uint64(LatestBlock.unwrap(latest));
    }
}
