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

export const DOMAIN_MESSAGE_PARAMS = parseAbiParameters(
  "(uint64 sourceChainId, uint64 destinationChainId, address from, address to, uint256 sourceNonce, bytes32 salt, bytes data) message",
);

export interface MessageContext {
  l1ChainId: bigint;
  hub: Address;
}

/**
 * A domain-origin envelope. Bound for the L1, `from`, `to` and `data` are the sender, target and
 * payload. Bound for another domain, `from`, `to` and `salt` are zero and `data` is
 * `encodePlaintext(from, to, data)` sealed to that domain's encryption public key.
 */
export interface DomainMessage {
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
    parseAbiParameters("uint256, address, uint64, uint64, address, address, uint256, bytes32, bytes32"),
    [context.l1ChainId, context.hub,
      message.sourceChainId, message.destinationChainId, message.from, message.to,
      message.sourceNonce, message.salt, keccak256(message.data)],
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

/** What a domain-bound envelope seals. Mirrors the arguments of `MessageLib.encodePlaintext`. */
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

/** Decodes a plaintext produced by `encodePlaintext`, as the destination client does. */
export function decodePlaintext(plaintext: Hex): MessagePlaintext {
  const [from, to, data] = decodeAbiParameters(PLAINTEXT_PARAMS, plaintext);
  return { from, to, data };
}

const ENCRYPTION_PUB_KEY_PARAMS = parseAbiParameters("uint64 domainChainId, bytes32 encryptionPubKey");

/** Mirrors `MessageLib.encodeEncryptionPubKey`: the payload of the hub's encryption public key message to a spoke. */
export function encodeEncryptionPubKey(domainChainId: bigint, encryptionPubKey: Hex): Hex {
  return encodeAbiParameters(ENCRYPTION_PUB_KEY_PARAMS, [domainChainId, encryptionPubKey]);
}

/** Mirrors `MessageLib.decodeEncryptionPubKey`. */
export function decodeEncryptionPubKey(data: Hex): { domainChainId: bigint; encryptionPubKey: Hex } {
  const [domainChainId, encryptionPubKey] = decodeAbiParameters(ENCRYPTION_PUB_KEY_PARAMS, data);
  return { domainChainId, encryptionPubKey };
}

/**
 * The delivery a forwarded envelope becomes on its destination, under the nonce the destination
 * queue assigned. The envelope is sealed, so the caller supplies the plaintext.
 */
export function domainDeliveryEnvelope(message: DomainMessage, deliveryNonce: bigint, plaintext: MessagePlaintext): Message {
  return { sourceChainId: message.sourceChainId, from: plaintext.from,
    to: plaintext.to, data: plaintext.data, nonce: deliveryNonce };
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
