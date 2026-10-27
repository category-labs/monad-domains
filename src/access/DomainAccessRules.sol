// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDomainAccessControl, IDomainAccessPolicy} from "../interfaces/IDomainAccessControl.sol";

contract DomainAccessRules is IDomainAccessPolicy {
    enum AccessMode {
        Open,
        SubjectMatch,
        ReadersOnly
    }

    struct AccessRule {
        AccessMode mode;
        /// @dev SubjectMatch only: bit i set admits a caller equal to the address in calldata
        /// head word i (bytes 4 + 32i to 36 + 32i, one static address argument) of the first 16.
        uint16 subjectArguments;
    }

    event AccessControlSet(address indexed target, bytes4 indexed selector, AccessMode mode, uint16 subjectArguments);
    event ReaderAllowedSet(address indexed target, bytes4 indexed selector, address indexed reader, bool allowed);

    /// @notice Spoke whose `policyOwners` decide who may configure each target.
    IDomainAccessControl public immutable SPOKE;

    mapping(address => mapping(bytes4 => AccessRule)) public accessControl;
    mapping(address => mapping(bytes4 => mapping(address => bool))) public approvedReaders;

    modifier onlyPolicyOwner(address target) {
        address policyOwner = SPOKE.policyOwners(target);
        require(policyOwner != address(0) && msg.sender == policyOwner, "DomainAccessRules: not policy owner");
        _;
    }

    constructor(IDomainAccessControl spoke) {
        require(address(spoke) != address(0), "DomainAccessRules: zero spoke");
        SPOKE = spoke;
    }

    function setAccessControl(address target, bytes4 selector, AccessMode mode, uint16 subjectArguments)
        external
        onlyPolicyOwner(target)
    {
        require(mode != AccessMode.SubjectMatch || subjectArguments != 0, "DomainAccessRules: no subject arguments");
        uint16 subjects = mode == AccessMode.SubjectMatch ? subjectArguments : 0;
        accessControl[target][selector] = AccessRule(mode, subjects);
        emit AccessControlSet(target, selector, mode, subjects);
    }

    function setReaderAllowed(address target, bytes4 selector, address reader, bool allowed)
        external
        onlyPolicyOwner(target)
    {
        approvedReaders[target][selector][reader] = allowed;
        emit ReaderAllowedSet(target, selector, reader, allowed);
    }

    /// @inheritdoc IDomainAccessPolicy
    /// @dev Applies the rule stored for `context` and the calldata selector; no rule means allow.
    function canCall(address caller, address context, bytes calldata data) external view returns (bool) {
        bytes4 selector = data.length < 4 ? bytes4(0) : bytes4(data[:4]);
        AccessRule memory rule = accessControl[context][selector];
        if (rule.mode == AccessMode.Open) return true;
        if (approvedReaders[context][selector][caller]) return true;
        if (rule.mode == AccessMode.ReadersOnly) return false;

        // The caller must be the address in one of the rule's listed argument words. Listed
        // words are visited by increasing offset, so the first one the calldata does not reach
        // in full ends the scan. Every reached listed word must be a canonical ABI address,
        // rejected rather than truncated, even when another listed word already matched.
        bool matched;
        uint256 subjects = rule.subjectArguments;
        for (uint256 offset = 4; subjects != 0; (offset, subjects) = (offset + 32, subjects >> 1)) {
            if ((subjects & 1) == 0) continue;
            if (data.length < offset + 32) break;
            uint256 word;
            assembly ("memory-safe") {
                word := calldataload(add(data.offset, offset))
            }
            if (word > type(uint160).max) return false;
            // forge-lint: disable-next-line(unsafe-typecast)
            if (address(uint160(word)) == caller) matched = true;
        }
        return matched;
    }
}
