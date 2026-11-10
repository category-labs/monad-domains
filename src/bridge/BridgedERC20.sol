// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IDomainAccessControl} from "../interfaces/IDomainAccessControl.sol";

/// @notice Domain-side representation of a locked L1 token. Mint and burn are
/// restricted to the DomainBridge that deployed it.
/// L1_TOKEN is the counterpart L1 token address, only for metadata purposes.
contract BridgedERC20 is ERC20 {
    error NotBridge();

    address public immutable BRIDGE;
    address public immutable L1_TOKEN;
    uint8 internal immutable _TOKEN_DECIMALS;

    modifier onlyBridge() {
        if (msg.sender != BRIDGE) revert NotBridge();
        _;
    }

    constructor(
        address l1Token,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        IDomainAccessControl spoke,
        address policyOwner,
        address initialPolicy
    ) ERC20(name_, symbol_) {
        BRIDGE = msg.sender;
        L1_TOKEN = l1Token;
        _TOKEN_DECIMALS = decimals_;
        spoke.selfRegisterPolicy(policyOwner, initialPolicy);
    }

    function decimals() public view override returns (uint8) {
        return _TOKEN_DECIMALS;
    }

    function mint(address to, uint256 amount) external onlyBridge {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyBridge {
        _burn(from, amount);
    }
}
