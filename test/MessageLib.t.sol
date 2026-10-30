// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MessageLib} from "../src/libraries/MessageLib.sol";

contract MessageLibTest is Test {
    function test_hashMessage_matchesSpecFormat() public view {
        MessageLib.Message memory message = MessageLib.Message({
            sourceChainId: uint64(block.chainid),
            from: address(0xA11CE),
            to: address(0xB0B),
            data: hex"deadbeef",
            nonce: 42
        });
        bytes32 expected = keccak256(
            abi.encodePacked(
                uint64(block.chainid), address(0xA11CE), address(0xB0B), keccak256(hex"deadbeef"), uint256(42)
            )
        );
        assertEq(MessageLib.hashMessage(message), expected);
    }

    function testFuzz_hashMessage_distinctNoncesDistinctHashes(uint256 nonceA, uint256 nonceB) public view {
        vm.assume(nonceA != nonceB);
        MessageLib.Message memory a =
            MessageLib.Message(uint64(block.chainid), address(1), address(2), hex"1234", nonceA);
        MessageLib.Message memory b =
            MessageLib.Message(uint64(block.chainid), address(1), address(2), hex"1234", nonceB);
        assertNotEq(MessageLib.hashMessage(a), MessageLib.hashMessage(b));
    }

    function testFuzz_hashMessage_bindsSourceChain(uint64 sourceA, uint64 sourceB) public pure {
        vm.assume(sourceA != sourceB);
        MessageLib.Message memory message = MessageLib.Message(sourceA, address(1), address(2), hex"1234", 0);
        bytes32 original = MessageLib.hashMessage(message);
        message.sourceChainId = sourceB;
        assertNotEq(original, MessageLib.hashMessage(message));
    }

    function testFuzz_transferPayload_roundTrip(address recipient, address l1Token, uint256 amount) public pure {
        bytes memory data = MessageLib.encodeTransfer(recipient, l1Token, amount);
        (address decodedRecipient, address decodedToken, uint256 decodedAmount) = MessageLib.decodeTransfer(data);
        assertEq(decodedRecipient, recipient);
        assertEq(decodedToken, l1Token);
        assertEq(decodedAmount, amount);
    }

    function testFuzz_hashDomainMessage_bindsKind(address to, bytes memory data) public pure {
        MessageLib.DomainMessage memory plain = MessageLib.DomainMessage({
            kind: MessageLib.MessageKind.Plain,
            sourceChainId: 7777,
            destinationChainId: 8888,
            from: address(0xA11CE),
            to: to,
            sourceNonce: 1,
            data: data
        });
        MessageLib.DomainMessage memory encrypted = abi.decode(abi.encode(plain), (MessageLib.DomainMessage));
        encrypted.kind = MessageLib.MessageKind.Encrypted;
        assertNotEq(
            MessageLib.hashDomainMessage(plain, 1, address(0xB0B)),
            MessageLib.hashDomainMessage(encrypted, 1, address(0xB0B))
        );
    }
}
