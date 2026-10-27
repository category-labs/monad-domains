// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Decides whether a call into a domain contract may run. A contract's policy owner
/// names one on the spoke with `setAccessPolicy`; the spoke forwards `canCall` to it.
interface IDomainAccessPolicy {
    /// @notice Verdict for one proposed call frame, evaluated without executing it.
    /// @param caller Effective msg.sender in the proposed execution frame.
    /// @param context Address whose storage/balance the code will use (address(this)).
    /// @param data Original calldata of the proposed call.
    /// @dev Reached through a static call within the client's stipend (50,000 gas for the
    /// whole check). The client denies any call the policy makes, so decide from storage and
    /// the arguments alone. Anything but a canonical ABI `true` denies.
    function canCall(address caller, address context, bytes calldata data) external view returns (bool);
}

/// @notice Spoke side of access control: the policy owner of each deployed contract and the
/// policy it named. The spoke's `canCall` is what the execution client queries before every
/// call frame.
interface IDomainAccessControl is IDomainAccessPolicy {
    event ContractDeployed(address indexed target, address indexed deployer, address indexed policyOwner);
    /// @notice A zero `policy` opens the contract to every caller.
    event AccessPolicySet(address indexed target, address indexed policy);

    /// @notice Deploy using CREATE and assign a nonzero owner of the new contract's access policy.
    /// @param initCode Creation bytecode including ABI-encoded constructor arguments.
    /// @param policyOwner Account authorized to name the contract's access policy.
    function deployContract(bytes calldata initCode, address policyOwner) external returns (address deployed);
    function policyOwners(address target) external view returns (address);

    /// @notice Policy-owner-only. Name the contract that decides calls into `target`, or the
    /// zero address to admit every caller. A nonzero policy must have code. Verify a policy
    /// before naming it: it decides the target's access.
    function setAccessPolicy(address target, address policy) external;
    function accessPolicies(address target) external view returns (address);
}
