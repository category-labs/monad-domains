// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDomainAccessPolicy} from "../../src/interfaces/IDomainAccessControl.sol";

/// @notice Answers the same verdict to every question.
contract ConstantPolicy is IDomainAccessPolicy {
    bool public immutable VERDICT;

    constructor(bool verdict) {
        VERDICT = verdict;
    }

    function canCall(address, address, bytes calldata) external view returns (bool) {
        return VERDICT;
    }
}

/// @notice Admits exactly one (caller, context, calldata) triple, fixed at construction, so a
/// test can check that the spoke forwards its arguments untouched.
contract ExpectingPolicy is IDomainAccessPolicy {
    address public immutable CALLER;
    address public immutable CONTEXT;
    bytes32 public immutable DATA_HASH;

    constructor(address caller, address context, bytes memory data) {
        CALLER = caller;
        CONTEXT = context;
        DATA_HASH = keccak256(data);
    }

    function canCall(address caller, address context, bytes calldata data) external view returns (bool) {
        return caller == CALLER && context == CONTEXT && keccak256(data) == DATA_HASH;
    }
}

/// @notice Misbehaves in the way chosen at construction. The spoke must deny for every variant.
contract BrokenPolicy {
    enum Fault {
        Reverts,
        RunsOutOfGas,
        ReturnsTwo,
        ReturnsTwoWords,
        ReturnsNothing,
        ReturnsLongBuffer,
        WritesState
    }

    Fault public immutable FAULT;
    uint256 public writes;

    constructor(Fault fault) {
        FAULT = fault;
    }

    /// @dev Same selector as `IDomainAccessPolicy.canCall`, deliberately not a view: the
    /// WritesState variant stores, which the spoke's static call forbids.
    function canCall(address, address, bytes calldata) external returns (bool) {
        if (FAULT == Fault.Reverts) revert("BrokenPolicy: no");
        if (FAULT == Fault.RunsOutOfGas) {
            assembly ("memory-safe") {
                for {} 1 {} {}
            }
        }
        if (FAULT == Fault.ReturnsTwo) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        if (FAULT == Fault.ReturnsTwoWords) {
            assembly ("memory-safe") {
                mstore(0, 1)
                mstore(32, 0)
                return(0, 64)
            }
        }
        if (FAULT == Fault.ReturnsNothing) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (FAULT == Fault.ReturnsLongBuffer) {
            // A canonical true padded to a kilobyte: the length is wrong.
            bytes memory buffer = new bytes(1024);
            buffer[31] = 0x01;
            assembly ("memory-safe") {
                return(add(buffer, 32), mload(buffer))
            }
        }
        writes += 1;
        return true;
    }
}
