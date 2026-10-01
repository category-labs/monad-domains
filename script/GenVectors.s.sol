// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MessageLib} from "../src/libraries/MessageLib.sol";
import {MerkleTreeLib} from "../src/libraries/MerkleTreeLib.sol";

contract GenVectors is Script {
    function run() external pure {
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
    }
}
