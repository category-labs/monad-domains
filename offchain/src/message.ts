import { randomBytes } from "node:crypto";
import {
  bytesToHex,
  decodeAbiParameters,
  encodeAbiParameters,
  encodePacked,
  keccak256,
  parseAbiParameters,
  type Address,
  type Hex,
} from "viem";

/** `MessageLib.MessageKind`: the shape of a domain-origin envelope. Encoded as `uint8`. */
export enum MessageKind {
  /** The destination is the L1: `to` and `data` are the target and payload, readable there. */
  Plain = 0,
  /**
   * The destination is another domain: `from`, `to` and `salt` are zero and `data` is
   * `encodePlaintext(from, to, data)` sealed to that domain's viewing key.
   */
  Encrypted = 1,
}

export const DOMAIN_MESSAGE_PARAMS = parseAbiParameters(
  "(uint8 kind, uint64 sourceChainId, uint64 destinationChainId, address from, address to, uint256 sourceNonce, bytes32 salt, bytes data) message",
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
  salt: Hex;
  data: Hex;
}

export function generateMessageSalt(): Hex {
  return bytesToHex(randomBytes(32));
}

export function hashDomainMessage(message: DomainMessage, context: MessageContext): Hex {
  return keccak256(encodeAbiParameters(
    parseAbiParameters("uint256, address, uint8, uint64, uint64, address, address, uint256, bytes32, bytes32"),
    [context.l1ChainId, context.hub, message.kind,
      message.sourceChainId, message.destinationChainId, message.from, message.to,
      message.sourceNonce, message.salt, keccak256(message.data)],
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

/** True for an envelope sealed for another domain. */
export function isEncryptedDomainMessage(message: DomainMessage): boolean {
  return message.kind === MessageKind.Encrypted;
}

/** What an encrypted envelope seals. Mirrors the arguments of `MessageLib.encodePlaintext`. */
export interface MessagePlaintext {
  from: Address;
  to: Address;
  data: Hex;
}

const PLAINTEXT_PARAMS = parseAbiParameters("address from, address to, bytes data");

/** Mirrors `MessageLib.encodePlaintext`. */
export function encodePlaintext(plaintext: MessagePlaintext): Hex {
  return encodeAbiParameters(PLAINTEXT_PARAMS, [plaintext.from, plaintext.to, plaintext.data]);
}

/** Mirrors `MessageLib.decodePlaintext`. */
export function decodePlaintext(plaintext: Hex): MessagePlaintext {
  const [from, to, data] = decodeAbiParameters(PLAINTEXT_PARAMS, plaintext);
  return { from, to, data };
}

const VIEWING_KEY_PARAMS = parseAbiParameters("uint64 domainChainId, bytes viewingKey");

/** Mirrors `MessageLib.encodeViewingKey`: the payload of the hub's viewing key message to a spoke. */
export function encodeViewingKey(domainChainId: bigint, viewingKey: Hex): Hex {
  return encodeAbiParameters(VIEWING_KEY_PARAMS, [domainChainId, viewingKey]);
}

/** Mirrors `MessageLib.decodeViewingKey`. */
export function decodeViewingKey(data: Hex): { domainChainId: bigint; viewingKey: Hex } {
  const [domainChainId, viewingKey] = decodeAbiParameters(VIEWING_KEY_PARAMS, data);
  return { domainChainId, viewingKey };
}

/**
 * Direct application delivery, using the nonce assigned by the destination queue. An
 * encrypted envelope is delivered as the plaintext it seals, which the caller supplies.
 */
export function domainDeliveryEnvelope(message: DomainMessage, deliveryNonce: bigint, plaintext?: MessagePlaintext): Message {
  if (isEncryptedDomainMessage(message)) {
    if (!plaintext) throw new Error("routing: encrypted envelope needs its plaintext (from, to, data)");
    return { sourceChainId: message.sourceChainId, from: plaintext.from,
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
