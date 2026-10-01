import { concat, keccak256, type Hex } from "viem";

/**
 * Canonical merkle tree construction for message anchors, byte-identical to
 * `MerkleTreeLib.sol`: sorted-pair keccak256 (OpenZeppelin `MerkleProof`-compatible)
 * over the raw message hashes as leaves, with an odd node promoted unchanged to the
 * next level. A single leaf is its own root.
 */

/** Sorted-pair hash: `keccak256(min ‖ max)`. */
function hashPair(a: Hex, b: Hex): Hex {
  const [lo, hi] = a.toLowerCase() < b.toLowerCase() ? [a, b] : [b, a];
  return keccak256(concat([lo, hi]));
}

function nextLayer(layer: Hex[]): Hex[] {
  const next: Hex[] = [];
  for (let i = 0; i + 1 < layer.length; i += 2) {
    next.push(hashPair(layer[i]!, layer[i + 1]!));
  }
  if (layer.length % 2 === 1) {
    next.push(layer[layer.length - 1]!);
  }
  return next;
}

/** Computes the root over `leaves` (the anchor value the protocol records). */
export function root(leaves: readonly Hex[]): Hex {
  if (leaves.length === 0) throw new Error("merkle: empty leaves");
  let layer = [...leaves];
  while (layer.length > 1) layer = nextLayer(layer);
  return layer[0]!;
}

/** Generates the merkle path for `leaves[index]`, verifiable on-chain with OZ `MerkleProof`. */
export function getProof(leaves: readonly Hex[], index: number): Hex[] {
  if (index < 0 || index >= leaves.length) throw new Error("merkle: index out of bounds");
  const proof: Hex[] = [];
  let layer = [...leaves];
  while (layer.length > 1) {
    const sibling = index ^ 1;
    if (sibling < layer.length) proof.push(layer[sibling]!);
    // A promoted odd node keeps its position (last, even index) and moves to
    // index/2 in the next layer, same as a hashed pair.
    index = Math.floor(index / 2);
    layer = nextLayer(layer);
  }
  return proof;
}

/** Mirrors OpenZeppelin `MerkleProof.verify` (sorted-pair processProof). */
export function verify(proof: readonly Hex[], expectedRoot: Hex, leaf: Hex): boolean {
  let computed = leaf;
  for (const sibling of proof) computed = hashPair(computed, sibling);
  return computed.toLowerCase() === expectedRoot.toLowerCase();
}
