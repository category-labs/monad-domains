// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MessageLib} from "../src/libraries/MessageLib.sol";

/// @notice Pins both message hashes to the vectors `offchain/test/conformance.test.ts` checks the
/// TypeScript mirror against (printed by `script/GenVectors.s.sol`), so a change to either
/// implementation fails a test.
contract MessageLibTest is Test {
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
            sourceChainId: 7777,
            destinationChainId: 31337,
            from: address(0x1000),
            to: address(0x2000),
            sourceNonce: 3,
            data: MessageLib.encodeTransfer(address(0x3000), address(0x4000), 1e18)
        });
        assertEq(
            MessageLib.hashDomainMessage(message, 31337, 0x5aAdFB43eF8dAF45DD80F4676345b7676f1D70e3),
            0xe867f835d5347f0a6f0cea6d36500780cd7799407d148df34cc30dde3150a08b
        );
    }
}
