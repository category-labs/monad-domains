// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IDomainMessageReceiver, IDomainSpoke} from "../interfaces/IDomain.sol";
import {MessageLib} from "../libraries/MessageLib.sol";
import {BridgedERC20} from "./BridgedERC20.sol";

/// @notice Domain side of the reference lock-and-mint token bridge. L1 deposit messages
/// are delivered by the protocol: the spoke invokes `onDomainMessage` and the bridge mints
/// the corresponding bridged token. Exactly-once delivery is the protocol's guarantee.
contract DomainBridge is IDomainMessageReceiver {
    error ZeroL1Bridge();
    error NotSpoke();
    error NotFromL1();
    error NotL1Bridge();
    error ZeroRecipient();
    error ZeroAmount();
    error UnknownToken();

    IDomainSpoke public immutable SPOKE;
    uint64 public immutable L1_CHAIN_ID;

    /// @notice Counterpart L1Bridge - the only accepted message sender.
    address public immutable L1_BRIDGE;

    /// @notice Bridged token per L1 token address.
    mapping(address => BridgedERC20) public bridgedTokens;

    event BridgedTokenDeployed(address indexed l1Token, address token);
    event DepositFinalized(address indexed recipient, address indexed l1Token, uint256 amount);
    event WithdrawalInitiated(address indexed sender, address recipient, address indexed l1Token, uint256 amount);

    constructor(IDomainSpoke spoke, address l1Bridge) {
        if (l1Bridge == address(0)) revert ZeroL1Bridge();
        SPOKE = spoke;
        L1_CHAIN_ID = spoke.L1_CHAIN_ID();
        L1_BRIDGE = l1Bridge;
    }

    /// @notice Receives an L1 deposit message delivered by the protocol and mints the bridged
    /// token to the recipient encoded in the payload. The bridged token is deployed on first
    /// use. Only the spoke may deliver, and only messages the counterpart L1Bridge sent count -
    /// anyone can send arbitrary payloads through the hub.
    function onDomainMessage(uint64 sourceChainId, address from, bytes calldata data) external {
        if (msg.sender != address(SPOKE)) revert NotSpoke();
        if (sourceChainId != L1_CHAIN_ID) revert NotFromL1();
        if (from != L1_BRIDGE) revert NotL1Bridge();

        (address recipient, address l1Token, uint256 amount) = MessageLib.decodeTransfer(data);
        BridgedERC20 token = bridgedTokens[l1Token];
        if (address(token) == address(0)) {
            token = _deployBridgedToken(l1Token);
        }
        token.mint(recipient, amount);
        emit DepositFinalized(recipient, l1Token, amount);
    }

    /// @notice Burns `amount` of the bridged token for `l1Token` and sends a withdrawal
    /// message to the counterpart L1Bridge, which releases the locked L1 tokens to
    /// `recipient` once the message is proven there.
    function bridgeToL1(address recipient, address l1Token, uint256 amount) external {
        if (recipient == address(0)) revert ZeroRecipient();
        if (amount == 0) revert ZeroAmount();
        BridgedERC20 token = bridgedTokens[l1Token];
        if (address(token) == address(0)) revert UnknownToken();

        // Burn before messaging: the withdrawal message must never overstate what was
        // actually destroyed on the domain.
        token.burn(msg.sender, amount);
        SPOKE.sendDomainMessage(L1_CHAIN_ID, L1_BRIDGE, MessageLib.encodeTransfer(recipient, l1Token, amount));
        emit WithdrawalInitiated(msg.sender, recipient, l1Token, amount);
    }

    /// @dev CREATE2 salted by the L1 token address, with metadata derived from it, so the
    /// bridged token address is fully deterministic.
    function _deployBridgedToken(address l1Token) internal returns (BridgedERC20 token) {
        token = new BridgedERC20{salt: bytes32(uint256(uint160(l1Token)))}(
            l1Token, string.concat("Bridged ", Strings.toHexString(l1Token)), "BRG", 18
        );
        bridgedTokens[l1Token] = token;
        emit BridgedTokenDeployed(l1Token, address(token));
    }
}
