import {
  decodeAbiParameters,
  encodeAbiParameters,
  encodePacked,
  keccak256,
  type Address,
  type Hex,
} from "viem";

/**
 * Preimage of a recorded cross-domain message. Mirrors `MessageLib.Message`;
 * `hashMessage` must produce byte-identical results to the Solidity implementation.
 */
export interface Message {
  from: Address;
  to: Address;
  data: Hex;
  nonce: bigint;
}

/** `keccak256(abi.encodePacked(from, to, keccak256(data), nonce))` — the MIP hash format. */
export function hashMessage(message: Message): Hex {
  return keccak256(
    encodePacked(
      ["address", "address", "bytes32", "uint256"],
      [message.from, message.to, keccak256(message.data), message.nonce],
    ),
  );
}

const TRANSFER_PARAMS = [
  { name: "recipient", type: "address" },
  { name: "l1Token", type: "address" },
  { name: "amount", type: "uint256" },
] as const;

/** Token bridge payload carried in `Message.data`. Mirrors `MessageLib.encodeTransfer`. */
export function encodeTransfer(recipient: Address, l1Token: Address, amount: bigint): Hex {
  return encodeAbiParameters(TRANSFER_PARAMS, [recipient, l1Token, amount]);
}

/** Mirrors `MessageLib.decodeTransfer`. */
export function decodeTransfer(data: Hex): { recipient: Address; l1Token: Address; amount: bigint } {
  const [recipient, l1Token, amount] = decodeAbiParameters(TRANSFER_PARAMS, data);
  return { recipient, l1Token, amount };
}
