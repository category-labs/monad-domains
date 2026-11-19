// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {DomainHub} from "../../src/DomainHub.sol";

/// @notice A later hub implementation for upgrade tests: the current one with a storage
/// variable appended, a one-time migration that sets it and a function the current one lacks.
contract DomainHubV2 is DomainHub {
    uint256 public migrated;

    function migrate(uint256 value) external reinitializer(2) {
        migrated = value;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}
