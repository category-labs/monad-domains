// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MessageLib} from "../src/libraries/MessageLib.sol";

/// @notice Pins the message hashes and payload encodings to the vectors
/// `offchain/test/conformance.test.ts` checks the TypeScript mirror against (printed by
/// `script/GenVectors.s.sol`), so a change to either implementation fails a test.
contract MessageLibTest is Test {
    /// @dev The hub `script/GenVectors.s.sol` deploys on chain 31337.
    address internal constant VECTOR_HUB = 0xf13D09eD3cbdD1C930d4de74808de1f33B6b3D4f;
    bytes32 internal constant L1_BOUND_VECTOR = 0xa0e7d092669d8549053b94ad7d773382718f697c90b97d1518cf69062af286b2;
    bytes32 internal constant DOMAIN_BOUND_VECTOR = 0x0006269e652eae44fcce4ec4b8c40d704df704e015584ce0749d3fe1eac3c4ef;
    bytes32 internal constant VIEWING_KEY_VECTOR = 0xc94518b602b208060b5fe015a92d0442be3ae61b05396f639d647da9721e10b8;
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
            sourceChainId: 7777,
            destinationChainId: 31337,
            from: address(0x1000),
            to: address(0x2000),
            salt: bytes32(uint256(1)),
            sourceNonce: 3,
            data: MessageLib.encodeTransfer(address(0x3000), address(0x4000), 1e18)
        });
        assertEq(MessageLib.hashDomainMessage(message, 31337, VECTOR_HUB), L1_BOUND_VECTOR);

        message.destinationChainId = 8888;
        message.from = address(0);
        message.to = address(0);
        message.salt = bytes32(0);
        message.data = hex"04c0ffee";
        assertEq(MessageLib.hashDomainMessage(message, 31337, VECTOR_HUB), DOMAIN_BOUND_VECTOR);
    }

    function test_plaintext_matchesConformanceVector() public pure {
        bytes memory plaintext = MessageLib.encodePlaintext(address(0x1000), address(0x2000), hex"1234");
        assertEq(keccak256(plaintext), PLAINTEXT_VECTOR);
        (address from, address to, bytes memory data) = abi.decode(plaintext, (address, address, bytes));
        assertEq(from, address(0x1000));
        assertEq(to, address(0x2000));
        assertEq(data, hex"1234");
    }

    function test_viewingKeyPayload_matchesConformanceVector() public pure {
        bytes memory data = MessageLib.encodeViewingKey(8888, keccak256("viewing key"));
        assertEq(keccak256(data), VIEWING_KEY_VECTOR);
        (uint64 domainChainId, bytes32 viewingKey) = MessageLib.decodeViewingKey(data);
        assertEq(domainChainId, 8888);
        assertEq(viewingKey, keccak256("viewing key"));
    }
}
