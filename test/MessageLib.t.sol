// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MessageLib} from "../src/libraries/MessageLib.sol";

contract MessageLibTest is Test {
    function test_hashMessage_matchesSpecFormat() public pure {
        MessageLib.Message memory message =
            MessageLib.Message({from: address(0xA11CE), to: address(0xB0B), data: hex"deadbeef", nonce: 42});
        bytes32 expected =
            keccak256(abi.encodePacked(address(0xA11CE), address(0xB0B), keccak256(hex"deadbeef"), uint256(42)));
        assertEq(MessageLib.hashMessage(message), expected);
    }

    function testFuzz_hashMessage_distinctNoncesDistinctHashes(uint256 nonceA, uint256 nonceB) public pure {
        vm.assume(nonceA != nonceB);
        MessageLib.Message memory a = MessageLib.Message(address(1), address(2), hex"1234", nonceA);
        MessageLib.Message memory b = MessageLib.Message(address(1), address(2), hex"1234", nonceB);
        assertNotEq(MessageLib.hashMessage(a), MessageLib.hashMessage(b));
    }

    function testFuzz_transferPayload_roundTrip(address recipient, address l1Token, uint256 amount) public pure {
        bytes memory data = MessageLib.encodeTransfer(recipient, l1Token, amount);
        (address decodedRecipient, address decodedToken, uint256 decodedAmount) = MessageLib.decodeTransfer(data);
        assertEq(decodedRecipient, recipient);
        assertEq(decodedToken, l1Token);
        assertEq(decodedAmount, amount);
    }
}
