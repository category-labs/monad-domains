// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice L1 ledger token for the bank demo: freely mintable so every visitor can fund an
/// account from the faucet. Demo-only trust model: minting is deliberately permissionless.
contract DemoLedger is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
