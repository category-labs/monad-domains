// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDomainMessageReceiver} from "../../src/interfaces/IDomain.sol";

/// @dev Test receiver authenticating the local spoke and the complete remote identity.
contract CrossDomainReceiver is IDomainMessageReceiver {
    address public immutable spoke;
    mapping(uint64 => address) public peers;
    bool public reject;
    uint256 public minimumGas;
    uint256 public calls;
    uint64 public source;
    address public sender;
    bytes public payload;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentrySucceeded;

    constructor(address spoke_, uint64 source_, address sender_) {
        spoke = spoke_;
        peers[source_] = sender_;
    }

    function setPeer(uint64 chain, address peer) external {
        peers[chain] = peer;
    }

    function setReject(bool value) external {
        reject = value;
    }

    function setMinimumGas(uint256 value) external {
        minimumGas = value;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function onDomainMessage(uint64 source_, address sender_, bytes calldata data) external {
        require(msg.sender == spoke, "Receiver: not spoke");
        require(peers[source_] != address(0) && peers[source_] == sender_, "Receiver: wrong peer");
        require(!reject, "Receiver: rejected");
        require(gasleft() > minimumGas, "Receiver: insufficient gas");
        calls++;
        source = source_;
        sender = sender_;
        payload = data;
        if (reentryTarget != address(0)) {
            (reentrySucceeded,) = reentryTarget.call(reentryData);
        }
    }
}
