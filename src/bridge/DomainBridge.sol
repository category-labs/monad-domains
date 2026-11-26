// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IDomainSpoke} from "../interfaces/IDomain.sol";
import {IDomainMessageReceiver} from "../interfaces/IDomainMessageReceiver.sol";
import {IDomainAccessControl} from "../interfaces/IDomainAccessControl.sol";
import {IDomainBridge} from "../interfaces/IDomainBridge.sol";
import {MessageLib} from "../libraries/MessageLib.sol";
import {BridgedERC20} from "./BridgedERC20.sol";

/// @notice Domain side of the reference lock-and-mint token bridge. L1 deposit messages
/// are delivered by the protocol: the spoke invokes `onDomainMessage` and the bridge mints
/// the corresponding bridged token. Exactly-once delivery is the protocol's guarantee.
contract DomainBridge is IDomainBridge, IDomainMessageReceiver {
    /// @notice The spoke address has no code.
    error SpokeHasNoCode();
    /// @notice The message was not sent by the counterpart L1Bridge.
    error NotL1Bridge();

    IDomainSpoke public immutable SPOKE;

    /// @notice Counterpart L1Bridge - the only accepted message sender.
    address public immutable L1_BRIDGE;

    /// @notice Policy administrator and initial policy shared by newly created bridged tokens.
    address public immutable TOKEN_POLICY_OWNER;
    address public immutable INITIAL_TOKEN_POLICY;

    /// @dev Safe to cache: the spoke's L1 chain id is immutable too.
    uint64 internal immutable _L1_CHAIN_ID;

    /// @notice Bridged token per L1 token address.
    mapping(address l1Token => address token) public bridgedTokens;

    constructor(IDomainSpoke spoke, address l1Bridge, address tokenPolicyOwner, address initialTokenPolicy) {
        if (l1Bridge == address(0)) revert ZeroAddress();
        if (address(spoke).code.length == 0) revert SpokeHasNoCode();
        if (tokenPolicyOwner == address(0)) revert ZeroAddress();
        if (initialTokenPolicy.code.length == 0 || initialTokenPolicy == address(spoke)) {
            revert IDomainAccessControl.InvalidPolicy(initialTokenPolicy);
        }
        SPOKE = spoke;
        _L1_CHAIN_ID = spoke.L1_CHAIN_ID();
        L1_BRIDGE = l1Bridge;
        TOKEN_POLICY_OWNER = tokenPolicyOwner;
        INITIAL_TOKEN_POLICY = initialTokenPolicy;
    }

    /// @notice Receives an L1 deposit message delivered by the protocol and mints the bridged
    /// token to the recipient encoded in the payload. The bridged token is deployed on first
    /// use. Only the spoke may deliver, and only messages the counterpart L1Bridge sent count -
    /// anyone can send arbitrary payloads through the hub.
    function onDomainMessage(uint64 sourceChainId, address from, bytes calldata data) external {
        if (msg.sender != address(SPOKE)) revert Unauthorized(msg.sender);
        if (sourceChainId != _L1_CHAIN_ID) revert InvalidChainId(sourceChainId);
        if (from != L1_BRIDGE) revert NotL1Bridge();

        (address recipient, address l1Token, uint256 amount) = MessageLib.decodeTransfer(data);
        BridgedERC20 token = BridgedERC20(bridgedTokens[l1Token]);
        if (address(token) == address(0)) {
            token = _deployBridgedToken(l1Token);
        }
        token.mint(recipient, amount);
        emit DepositFinalized(recipient, l1Token, amount);
    }

    function bridgeToL1(address recipient, address l1Token, uint256 amount, bytes32 salt) external {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        BridgedERC20 token = BridgedERC20(bridgedTokens[l1Token]);
        if (address(token) == address(0)) revert UnknownToken();

        // Burn before messaging: the withdrawal message must never overstate what was
        // actually destroyed on the domain.
        token.burn(msg.sender, amount);
        bytes32 messageId = SPOKE.sendDomainMessage(
            _L1_CHAIN_ID, L1_BRIDGE, MessageLib.encodeTransfer(recipient, l1Token, amount), salt
        );
        emit WithdrawalInitiated(msg.sender, recipient, l1Token, amount, messageId);
    }

    /// @dev CREATE2 salted by the L1 token address, with metadata derived from it, so the
    /// bridged token address is fully deterministic.
    function _deployBridgedToken(address l1Token) internal returns (BridgedERC20 token) {
        token = new BridgedERC20{salt: bytes32(uint256(uint160(l1Token)))}(
            l1Token,
            string.concat("Bridged ", Strings.toHexString(l1Token)),
            "BRG",
            18,
            SPOKE,
            TOKEN_POLICY_OWNER,
            INITIAL_TOKEN_POLICY
        );
        bridgedTokens[l1Token] = address(token);
        emit BridgedTokenDeployed(l1Token, address(token));
    }
}
