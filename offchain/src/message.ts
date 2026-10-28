import {
  decodeAbiParameters,
  encodeAbiParameters,
  encodePacked,
  keccak256,
  parseAbiParameters,
  type Address,
  type Hex,
} from "viem";

/** `MessageLib.MessageKind`: what a domain-origin envelope carries. Encoded as `uint8`. */
export enum MessageKind {
  /** `to` is the target, `data` its payload, both readable on the L1. */
  Plain = 0,
  /** `to` is zero and `data` is `to[20] || data` sealed to the destination's viewing key. */
  Encrypted = 1,
}

export const DOMAIN_MESSAGE_PARAMS = parseAbiParameters(
  "(uint8 kind, uint64 sourceChainId, uint64 destinationChainId, address from, address to, uint256 sourceNonce, bytes data) message",
);

export interface MessageContext {
  l1ChainId: bigint;
  hub: Address;
}

export interface DomainMessage {
  kind: MessageKind;
  sourceChainId: bigint;
  destinationChainId: bigint;
  from: Address;
  to: Address;
  sourceNonce: bigint;
  data: Hex;
}

export function hashDomainMessage(message: DomainMessage, context: MessageContext): Hex {
  return keccak256(encodeAbiParameters(
    parseAbiParameters("uint256, address, uint8, uint64, uint64, address, address, uint256, bytes32"),
    [context.l1ChainId, context.hub, message.kind,
      message.sourceChainId, message.destinationChainId, message.from, message.to,
      message.sourceNonce, keccak256(message.data)],
  ));
}

export function encodeDomainMessage(message: DomainMessage): Hex {
  return encodeAbiParameters(DOMAIN_MESSAGE_PARAMS, [message]);
}

export function decodeDomainMessage(data: Hex): DomainMessage {
  const [decoded] = decodeAbiParameters(DOMAIN_MESSAGE_PARAMS, data);
  if (decoded.kind !== MessageKind.Plain && decoded.kind !== MessageKind.Encrypted) {
    throw new Error(`routing: unknown message kind ${decoded.kind}`);
  }
  const message: DomainMessage = { ...decoded, kind: decoded.kind as MessageKind };
  if (encodeDomainMessage(message).toLowerCase() !== data.toLowerCase()) {
    throw new Error("routing: non-canonical envelope");
  }
  return message;
}

/** True for an envelope recorded by `sendEncryptedDomainMessage`. */
export function isEncryptedDomainMessage(message: DomainMessage): boolean {
  return message.kind === MessageKind.Encrypted;
}

/** What an encrypted envelope seals: the arguments its sender gave `encryptMessage`. */
export interface MessagePlaintext {
  to: Address;
  data: Hex;
}

/**
 * Direct application delivery, using the nonce assigned by the destination queue. An
 * encrypted envelope is delivered as the plaintext its sender sealed, so the sender supplies it.
 */
export function domainDeliveryEnvelope(message: DomainMessage, deliveryNonce: bigint, plaintext?: MessagePlaintext): Message {
  if (isEncryptedDomainMessage(message)) {
    if (!plaintext) throw new Error("routing: encrypted envelope needs its plaintext (to, data)");
    return { sourceChainId: message.sourceChainId, from: message.from,
      to: plaintext.to, data: plaintext.data, nonce: deliveryNonce };
  }
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
