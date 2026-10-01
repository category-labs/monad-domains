import {
  decodeAbiParameters,
  encodeAbiParameters,
  encodePacked,
  keccak256,
  parseAbiParameters,
  type Address,
  type Hex,
} from "viem";

export const DOMAIN_MESSAGE_PARAMS = parseAbiParameters(
  "(uint64 sourceChainId, uint64 destinationChainId, address from, address to, uint256 sourceNonce, bytes data) message",
);

export interface MessageContext {
  l1ChainId: bigint;
  hub: Address;
}

export interface DomainMessage {
  sourceChainId: bigint;
  destinationChainId: bigint;
  from: Address;
  to: Address;
  sourceNonce: bigint;
  data: Hex;
}

export function hashDomainMessage(message: DomainMessage, context: MessageContext): Hex {
  return keccak256(encodeAbiParameters(
    parseAbiParameters("uint256, address, uint64, uint64, address, address, uint256, bytes32"),
    [context.l1ChainId, context.hub,
      message.sourceChainId, message.destinationChainId, message.from, message.to,
      message.sourceNonce, keccak256(message.data)],
  ));
}

export function encodeDomainMessage(message: DomainMessage): Hex {
  return encodeAbiParameters(DOMAIN_MESSAGE_PARAMS, [message]);
}

export function decodeDomainMessage(data: Hex): DomainMessage {
  const [message] = decodeAbiParameters(DOMAIN_MESSAGE_PARAMS, data);
  if (encodeDomainMessage(message).toLowerCase() !== data.toLowerCase()) {
    throw new Error("routing: non-canonical envelope");
  }
  return message;
}

/** Direct application delivery, using the nonce assigned by the destination queue. */
export function domainDeliveryEnvelope(message: DomainMessage, deliveryNonce: bigint): Message {
  return { sourceChainId: message.sourceChainId, from: message.from,
    to: message.to, data: message.data, nonce: deliveryNonce };
}

/**
 * L1 delivery envelope (including hub forwarding). Mirrors `MessageLib.Message`;
 * `hashMessage` must produce byte-identical results to the Solidity implementation.
 */
export interface Message {
  sourceChainId: bigint;
  from: Address;
  to: Address;
  data: Hex;
  nonce: bigint;
}

/** `keccak256(abi.encodePacked(sourceChainId, from, to, keccak256(data), nonce))`. */
export function hashMessage(message: Message): Hex {
  return keccak256(
    encodePacked(
      ["uint64", "address", "address", "bytes32", "uint256"],
      [message.sourceChainId, message.from, message.to, keccak256(message.data), message.nonce],
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
