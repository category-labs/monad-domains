// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MessageLib} from "../src/libraries/MessageLib.sol";

/// @notice Pins both message hashes to the vectors `offchain/test/conformance.test.ts` checks the
/// TypeScript mirror against (printed by `script/GenVectors.s.sol`), so a change to either
/// implementation fails a test.
contract MessageLibTest is Test {
    bytes32 internal constant ENCRYPTED_VECTOR = 0x18d50d21546cb7d9b2b9b6698d478e5ff665f8f5b6e07c32bd3eaff0179ad661;
    bytes32 internal constant PLAINTEXT_VECTOR = 0x7a9c9eb956b730e4846f08c2553b355ef73f56830298acb60d4666b3b5f8b0ef;

    function test_hashMessage_matchesConformanceVector() public pure {
        MessageLib.Message memory message = MessageLib.Message({
            sourceChainId: 1,
            from: address(0x1000),
            to: address(0x2000),
            data: MessageLib.encodeTransfer(address(0x3000), address(0x4000), 1e18),
            nonce: 0
        });
        assertEq(MessageLib.hashMessage(message), 0x5f9026553b479ab6c7f6634745aafb4b320183912787adc801e2b85d4ccdefc2);
    }

    function test_hashDomainMessage_matchesConformanceVector() public pure {
        MessageLib.DomainMessage memory message = MessageLib.DomainMessage({
            kind: MessageLib.MessageKind.Plain,
            sourceChainId: 7777,
            destinationChainId: 31337,
            from: address(0x1000),
            to: address(0x2000),
            salt: bytes32(uint256(1)),
            sourceNonce: 3,
            data: MessageLib.encodeTransfer(address(0x3000), address(0x4000), 1e18)
        });
        assertEq(
            MessageLib.hashDomainMessage(message, 31337, 0x5aAdFB43eF8dAF45DD80F4676345b7676f1D70e3),
            0xea37ae163db35e3a8be7e9b55592f402e55809f5b155a4ce1388f37d1ebf1de4
        );

        message.kind = MessageLib.MessageKind.Encrypted;
        message.destinationChainId = 8888;
        message.from = address(0);
        message.to = address(0);
        message.salt = bytes32(0);
        message.data = hex"04c0ffee";
        assertEq(
            MessageLib.hashDomainMessage(message, 31337, 0x5aAdFB43eF8dAF45DD80F4676345b7676f1D70e3), ENCRYPTED_VECTOR
        );
    }

    function test_plaintext_matchesConformanceVector() public pure {
        bytes memory plaintext = MessageLib.encodePlaintext(address(0x1000), address(0x2000), hex"1234");
        assertEq(keccak256(plaintext), PLAINTEXT_VECTOR);
        (address from, address to, bytes memory data) = MessageLib.decodePlaintext(plaintext);
        assertEq(from, address(0x1000));
        assertEq(to, address(0x2000));
        assertEq(data, hex"1234");
    }

    function testFuzz_hashDomainMessage_bindsKind(address to, bytes memory data) public pure {
        MessageLib.DomainMessage memory plain = MessageLib.DomainMessage({
            kind: MessageLib.MessageKind.Plain,
            sourceChainId: 7777,
            destinationChainId: 8888,
            from: address(0xA11CE),
            to: to,
            sourceNonce: 1,
            salt: bytes32(uint256(1)),
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
