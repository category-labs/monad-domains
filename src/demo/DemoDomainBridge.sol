// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IDomainMessageReceiver, IDomainSpoke} from "../interfaces/IDomain.sol";
import {MessageLib} from "../libraries/MessageLib.sol";
import {BridgedERC20} from "../bridge/BridgedERC20.sol";

/// @notice The bank demo's domain bridge: the reference lock-and-mint DomainBridge, plus a
/// withdrawal that carries a memo for the DemoL1Bridge to hand to a contract recipient.
/// Deposits arrive as protocol system transactions, exactly like the reference bridge.
contract DemoDomainBridge is IDomainMessageReceiver {
    IDomainSpoke public immutable SPOKE;

    /// @notice Counterpart DemoL1Bridge - the only accepted deposit sender.
    address public immutable L1_BRIDGE;

    /// @notice Bridged token per L1 token address.
    mapping(address => BridgedERC20) public bridgedTokens;

    event BridgedTokenDeployed(address indexed l1Token, address token);
    event DepositFinalized(address indexed recipient, address indexed l1Token, uint256 amount);
    event WithdrawalInitiated(
        address indexed sender, address recipient, address indexed l1Token, uint256 amount, bytes32 memo
    );

    constructor(IDomainSpoke spoke, address l1Bridge) {
        require(l1Bridge != address(0), "DemoDomainBridge: zero L1 bridge");
        SPOKE = spoke;
        L1_BRIDGE = l1Bridge;
    }

    /// @notice Receives an L1 deposit delivered by the protocol and mints the bridged token.
    function onDomainMessage(uint64 sourceChainId, address from, bytes calldata data) external {
        require(msg.sender == address(SPOKE), "DemoDomainBridge: not spoke");
        require(sourceChainId == SPOKE.L1_CHAIN_ID(), "DemoDomainBridge: not from L1");
        require(from == L1_BRIDGE, "DemoDomainBridge: not from L1 bridge");

        (address recipient, address l1Token, uint256 amount) = MessageLib.decodeTransfer(data);
        BridgedERC20 token = bridgedTokens[l1Token];
        if (address(token) == address(0)) {
            token = _deployBridgedToken(l1Token);
        }
        token.mint(recipient, amount);
        emit DepositFinalized(recipient, l1Token, amount);
    }

    /// @notice Burns `amount` of the bridged token and sends a plain withdrawal to the L1.
    function bridgeToL1(address recipient, address l1Token, uint256 amount) external {
        _withdraw(recipient, l1Token, amount, MessageLib.encodeTransfer(recipient, l1Token, amount), bytes32(0));
    }

    /// @notice Burns `amount` of the bridged token and sends a withdrawal whose recipient is
    /// notified with `memo` once the L1 bridge has paid it out (see DemoL1Bridge).
    function bridgeToL1WithMemo(address recipient, address l1Token, uint256 amount, bytes32 memo) external {
        _withdraw(recipient, l1Token, amount, abi.encode(recipient, l1Token, amount, memo), memo);
    }

    function _withdraw(address recipient, address l1Token, uint256 amount, bytes memory payload, bytes32 memo)
        internal
    {
        require(recipient != address(0), "DemoDomainBridge: zero recipient");
        require(amount > 0, "DemoDomainBridge: zero amount");
        BridgedERC20 token = bridgedTokens[l1Token];
        require(address(token) != address(0), "DemoDomainBridge: unknown token");

        // Burn before messaging: the withdrawal must never overstate what was destroyed.
        token.burn(msg.sender, amount);
        SPOKE.sendDomainMessage(SPOKE.L1_CHAIN_ID(), L1_BRIDGE, payload);
        emit WithdrawalInitiated(msg.sender, recipient, l1Token, amount, memo);
    }

    /// @dev CREATE2 salted by the L1 token address, so the bridged token address is deterministic.
    function _deployBridgedToken(address l1Token) internal returns (BridgedERC20 token) {
        token = new BridgedERC20{salt: bytes32(uint256(uint160(l1Token)))}(
            l1Token, string.concat("Bridged ", Strings.toHexString(l1Token)), "BRG", 18
        );
        bridgedTokens[l1Token] = token;
        emit BridgedTokenDeployed(l1Token, address(token));
    }
}
