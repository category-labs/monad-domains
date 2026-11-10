// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {DomainHub} from "../../src/DomainHub.sol";
import {InputGasTest} from "./InputGas.t.sol";

/// @notice The hub's input paths without their events: what recording an input costs once
/// the queue is the only derivation source.
contract QueueOnlyHub is DomainHub {
    function sequenceToDomainQueueOnly(uint64 domainChainId, bytes calldata rlpTx) external payable {
        _recordInput(_registeredQueue(domainChainId), INPUT_TRANSACTION, msg.value, rlpTx);
    }

    function sendL1MessageQueueOnly(uint64 domainChainId, address to, bytes calldata data) external payable {
        uint256 queue = _registeredQueue(domainChainId);
        require(msg.value >= minDeliveryFee(data.length), "DomainHub: delivery fee too low");
        uint256 nonce = _nextMessageNonce(queue);
        _recordInput(
            queue,
            INPUT_MESSAGE,
            msg.value,
            abi.encodePacked(SafeCast.toUint64(block.chainid), msg.sender, to, uint64(nonce), data)
        );
    }

    function sendEncryptedL1MessageQueueOnly(uint64 domainChainId, bytes calldata ciphertext) external payable {
        uint256 queue = _registeredQueue(domainChainId);
        require(msg.value >= minDeliveryFee(ciphertext.length), "DomainHub: delivery fee too low");
        uint256 nonce = _nextMessageNonce(queue);
        _recordInput(
            queue,
            INPUT_ENCRYPTED_MESSAGE,
            msg.value,
            abi.encodePacked(SafeCast.toUint64(block.chainid), msg.sender, uint64(nonce), ciphertext)
        );
    }
}

contract InputGasQueueOnlyTest is InputGasTest {
    function _deployHub() internal override returns (DomainHub) {
        return new QueueOnlyHub();
    }

    function _variant() internal pure override returns (string memory) {
        return "queue";
    }

    function _sequenceSelector() internal pure override returns (bytes4) {
        return QueueOnlyHub.sequenceToDomainQueueOnly.selector;
    }

    function _messageSelector() internal pure override returns (bytes4) {
        return QueueOnlyHub.sendL1MessageQueueOnly.selector;
    }

    function _encryptedSelector() internal pure override returns (bytes4) {
        return QueueOnlyHub.sendEncryptedL1MessageQueueOnly.selector;
    }
}
