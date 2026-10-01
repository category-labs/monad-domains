// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Composability probe for domain access control: reads a token balance from
/// inside another contract so the execution client evaluates `canCall(reader, token, ...)`
/// for the nested CALL. `tryRead` swallows the inner failure to show that a denied frame
/// still reverts the whole transaction on the client.
contract BalanceReader {
    uint256 public lastBalance;
    uint256 public reads;

    function read(address token, address subject) external returns (uint256 balance) {
        balance = IERC20(token).balanceOf(subject);
        lastBalance = balance;
        reads += 1;
    }

    function tryRead(address token, address subject) external returns (bool ok, uint256 balance) {
        try IERC20(token).balanceOf(subject) returns (uint256 value) {
            ok = true;
            balance = value;
        } catch {
            ok = false;
        }
        lastBalance = balance;
        reads += 1;
    }
}
