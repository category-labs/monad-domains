// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Rules stored and evaluated by the spoke for the modified execution client.
interface IDomainAccessControl {
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

    event ContractDeployed(address indexed target, address indexed deployer, address indexed policyOwner);
    event AccessControlSet(address indexed target, bytes4 indexed selector, AccessMode mode, uint16 subjectArguments);
    event ReaderAllowedSet(address indexed target, bytes4 indexed selector, address indexed reader, bool allowed);

    /// @notice Deploy using CREATE and assign a nonzero owner of the new contract's access rules.
    /// @param initCode Creation bytecode including ABI-encoded constructor arguments.
    /// @param policyOwner Account authorized to configure access rules and reader grants.
    function deployContract(bytes calldata initCode, address policyOwner) external returns (address deployed);
    function policyOwners(address target) external view returns (address);

    /// @notice Policy-owner-only. Open admits every caller. SubjectMatch admits a caller equal to the
    /// address in any calldata head word listed in `subjectArguments` (bit i for head word i: `3`
    /// lists words 0 and 1, the owner or the spender of `allowance(owner, spender)`; a rule meant for
    /// the single argument index i is the mask `1 << i`), and approved readers. The set must be
    /// nonempty, and every listed word must hold a static address argument, since any other value
    /// there denies the call. ReadersOnly admits only approved readers. `subjectArguments` is stored
    /// as zero unless the mode is SubjectMatch.
    function setAccessControl(address target, bytes4 selector, AccessMode mode, uint16 subjectArguments) external;
    function accessControl(address target, bytes4 selector)
        external
        view
        returns (AccessMode mode, uint16 subjectArguments);

    /// @notice Policy-owner-only. Grant/revoke a reader that bypasses the restriction on this target and selector.
    function setReaderAllowed(address target, bytes4 selector, address reader, bool allowed) external;
    function approvedReaders(address target, bytes4 selector, address reader) external view returns (bool);

    /// @notice Evaluate stored rules without executing the proposed call or calling other contracts.
    /// @param caller Effective msg.sender in the proposed execution frame.
    /// @param context Address whose storage/balance the code will use (address(this)).
    /// @param data Original calldata of the proposed call.
    /// @dev Check only context's rules: the destination for CALL/STATICCALL or the current
    /// execution account for DELEGATECALL/CALLCODE. Code-address rules do not apply unless
    /// that address is also the context. A listed word the calldata does not reach in full cannot
    /// match; a listed word that is not a canonical address denies access even if another listed
    /// word matches, unless the caller is an approved reader. The client must authenticate these
    /// arguments.
    function canCall(address caller, address context, bytes calldata data) external view returns (bool);
}
