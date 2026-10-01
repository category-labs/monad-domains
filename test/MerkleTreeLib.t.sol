// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {MerkleTreeLib} from "../src/libraries/MerkleTreeLib.sol";

contract MerkleTreeLibTest is Test {
    function test_root_singleLeafIsItsOwnRoot() public pure {
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = keccak256("leaf");
        assertEq(MerkleTreeLib.root(leaves), leaves[0]);
        assertEq(MerkleTreeLib.getProof(leaves, 0).length, 0);
    }

    function test_root_emptyReverts() public {
        bytes32[] memory leaves = new bytes32[](0);
        vm.expectRevert("MerkleTreeLib: empty leaves");
        this.rootExternal(leaves);
    }

    function rootExternal(bytes32[] memory leaves) external pure returns (bytes32) {
        return MerkleTreeLib.root(leaves);
    }

    /// @dev Every proof for every leaf must verify with OpenZeppelin MerkleProof, for
    /// even, odd, and power-of-two leaf counts (odd counts exercise the promoted-node path).
    function test_proofs_verifyWithOpenZeppelin_allSizes() public pure {
        for (uint256 n = 1; n <= 9; n++) {
            bytes32[] memory leaves = new bytes32[](n);
            for (uint256 i = 0; i < n; i++) {
                leaves[i] = keccak256(abi.encodePacked("leaf", n, i));
            }
            bytes32 root = MerkleTreeLib.root(leaves);
            for (uint256 i = 0; i < n; i++) {
                bytes32[] memory proof = MerkleTreeLib.getProof(leaves, i);
                assertTrue(MerkleProof.verify(proof, root, leaves[i]), "proof must verify");
            }
        }
    }

    function test_proofs_wrongLeafFails() public pure {
        bytes32[] memory leaves = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            leaves[i] = keccak256(abi.encodePacked(i));
        }
        bytes32 root = MerkleTreeLib.root(leaves);
        bytes32[] memory proof = MerkleTreeLib.getProof(leaves, 2);
        assertFalse(MerkleProof.verify(proof, root, keccak256("not a leaf")));
    }

    function testFuzz_proofs_verify(bytes32[] memory leaves, uint256 index) public pure {
        vm.assume(leaves.length > 0 && leaves.length <= 64);
        index = bound(index, 0, leaves.length - 1);
        bytes32 root = MerkleTreeLib.root(leaves);
        bytes32[] memory proof = MerkleTreeLib.getProof(leaves, index);
        assertTrue(MerkleProof.verify(proof, root, leaves[index]));
    }
}
