// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Rules stored and evaluated by the spoke for the modified execution client.
interface IDomainAccessControl {
    struct AccessRule {
        bool requireSubjectMatch;
        /// @dev Zero-based index of a top-level static address argument (one ABI word).
        uint16 subjectArgumentIndex;
    }

    event ContractDeployed(address indexed target, address indexed deployer, address indexed policyOwner);
    event AccessControlSet(
        address indexed target, bytes4 indexed selector, bool requireSubjectMatch, uint16 subjectArgumentIndex
    );
    event ReaderAllowedSet(
        address indexed target, bytes4 indexed selector, address indexed subject, address reader, bool allowed
    );

    /// @notice Deploy using CREATE and assign a nonzero owner of the new contract's access rules.
    /// @param initCode Creation bytecode including ABI-encoded constructor arguments.
    /// @param policyOwner Account authorized to configure access rules and reader grants.
    function deployContract(bytes calldata initCode, address policyOwner) external returns (address deployed);
    function policyOwners(address target) external view returns (address);

    /// @notice Policy-owner-only. Restrict calls to the subject or their approved readers.
    function setAccessControl(address target, bytes4 selector, bool requireSubjectMatch, uint16 subjectArgumentIndex)
        external;
    function accessControl(address target, bytes4 selector)
        external
        view
        returns (bool requireSubjectMatch, uint16 subjectArgumentIndex);

    /// @notice Policy-owner-only. Grant/revoke a reader for this target, selector, and subject.
    /// @dev Grants apply only when the selector's subject restriction is enabled.
    function setReaderAllowed(address target, bytes4 selector, address subject, address reader, bool allowed) external;
    function approvedReaders(address target, bytes4 selector, address subject, address reader)
        external
        view
        returns (bool);

    /// @notice Evaluate stored rules without executing the proposed call or calling other contracts.
    /// @param caller Effective msg.sender in the proposed execution frame.
    /// @param context Address whose storage/balance the code will use (address(this)).
    /// @param data Original calldata of the proposed call.
    /// @dev Check only context's rules: the destination for CALL/STATICCALL or the current
    /// execution account for DELEGATECALL/CALLCODE. Code-address rules do not apply unless
    /// that address is also the context. Malformed subject address words deny access.
    /// The client must authenticate these arguments.
    function canCall(address caller, address context, bytes calldata data) external view returns (bool);
}
