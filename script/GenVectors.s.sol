// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MessageLib} from "../src/libraries/MessageLib.sol";
import {MerkleTreeLib} from "../src/libraries/MerkleTreeLib.sol";
import {DomainHub} from "../src/DomainHub.sol";

/// @notice Prints the conformance vectors `offchain/test/conformance.test.ts` pins: message
/// hashes, merkle roots and proofs, and the EIP-712 state transition digest of a hub deployed
/// at a known chain id. Run with `forge script script/GenVectors.s.sol`.
contract GenVectors is Script {
    uint64 internal constant VECTOR_CHAIN_ID = 31337;
    uint64 internal constant VECTOR_DOMAIN = 7777;
    uint64 internal constant VECTOR_BLOCK = 10;

    function run() external {
        bytes32[] memory leaves = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            MessageLib.Message memory m = MessageLib.Message({
                sourceChainId: 1,
                from: address(uint160(0x1000 + i)),
                to: address(uint160(0x2000 + i)),
                data: MessageLib.encodeTransfer(
                    address(uint160(0x3000 + i)), address(uint160(0x4000 + i)), (i + 1) * 1e18
                ),
                nonce: i
            });
            leaves[i] = MessageLib.hashMessage(m);
            console.log("leaf", i);
            console.logBytes32(leaves[i]);
        }
        for (uint256 n = 1; n <= 5; n++) {
            bytes32[] memory sub = new bytes32[](n);
            for (uint256 i = 0; i < n; i++) {
                sub[i] = leaves[i];
            }
            console.log("root n=", n);
            console.logBytes32(MerkleTreeLib.root(sub));
        }
        for (uint256 i = 0; i < 5; i++) {
            bytes32[] memory proof = MerkleTreeLib.getProof(leaves, i);
            console.log("proof for leaf", i, "len", proof.length);
            for (uint256 j = 0; j < proof.length; j++) {
                console.logBytes32(proof[j]);
            }
        }

        // EIP-712 state transition digest: a fresh hub (stateNonce 0) at a fixed chain id,
        // attesting block 10 with the root of all five leaves as the anchor.
        vm.chainId(VECTOR_CHAIN_ID);
        DomainHub hub = new DomainHub();
        bytes32 stateRoot = keccak256("state root");
        bytes32 anchor = MerkleTreeLib.root(leaves);
        console.log("hub chain id", VECTOR_CHAIN_ID);
        console.log("hub address");
        console.logAddress(address(hub));
        console.log("digest domain", VECTOR_DOMAIN, "block", VECTOR_BLOCK);
        console.log("digest state root");
        console.logBytes32(stateRoot);
        console.log("digest anchor");
        console.logBytes32(anchor);
        console.log("stateTransitionDigest");
        console.logBytes32(hub.stateTransitionDigest(VECTOR_DOMAIN, VECTOR_BLOCK, stateRoot, anchor));
    }
}
