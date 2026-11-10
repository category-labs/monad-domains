import { Aes128Gcm, CipherSuite, DhkemP256HkdfSha256, HkdfSha256 } from "@hpke/core";
import { bytesToHex, encodePacked, getAddress, hexToBytes, type Address, type Hex } from "viem";

/**
 * HPKE (RFC 9180, Base mode) encryption of domain transactions and L1 -> domain messages to a
 * domain's viewing key. Ciphertext format: `enc[65] || AEAD(0x01 || plaintext)`.
 *
 * Every ciphertext is bound to where it is valid, so one copied from L1 calldata opens nowhere
 * else: the `info` string names the payload type, and the associated data names the L1 chain,
 * the hub and the domain — plus, for a message, the L1 account that sends it.
 */

const suite = new CipherSuite({
  kem: new DhkemP256HkdfSha256(),
  kdf: new HkdfSha256(),
  aead: new Aes128Gcm(),
});

/** Profile identifiers, one per payload type; decryption must use the same value. */
const TRANSACTION_INFO = new TextEncoder().encode("private-domain-hpke-rfc9180-v1/transaction");
const MESSAGE_INFO = new TextEncoder().encode("private-domain-hpke-rfc9180-v1/message");

/** Uncompressed P-256 SEC1 point, as RFC 9180 serializes public and encapsulated keys. */
const PUBLIC_KEY_SIZE = 65;
/** Big-endian P-256 scalar. */
const SECRET_KEY_SIZE = 32;
/** AES-128-GCM authentication tag. */
const TAG_SIZE = 16;

/**
 * Version byte sealed ahead of the message. OpenSSL rejects a zero-length HPKE plaintext, so
 * every implementation of this profile encrypts `0x01 || message`; the byte is checked and
 * stripped only after the AEAD tag has verified.
 */
const FRAME_VERSION = 0x01;

/** An L1 -> domain message plaintext is `to[20] || data`. */
const ADDRESS_SIZE = 20;

/** Raised for every encryption and decryption failure. */
export class EncryptionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "EncryptionError";
  }
}

/** Where a ciphertext is valid: the hub that records it and the domain it is addressed to. */
export interface EncryptionContext {
  /** Chain id of the L1 the hub lives on. */
  l1ChainId: bigint;
  /** The DomainHub address on the L1. */
  hub: Address;
  /** Chain id of the destination domain. */
  domainChainId: bigint;
}

/**
 * The HPKE associated data, which the execution client must rebuild byte for byte. Fixed-width
 * fields, concatenated with no padding or length prefixes (Solidity `abi.encodePacked`):
 *
 *   transaction: l1ChainId (uint64, big-endian) || hub (20 bytes) || domainChainId (uint64, big-endian)
 *   message:     the same 36 bytes || from (20 bytes)
 *
 * `from` is the `msg.sender` of `sendEncryptedL1Message`, which the hub emits. A transaction
 * binds no sender: whoever pays for `sequenceToDomain` need not be its signer.
 */
function associatedData(context: EncryptionContext, from?: Address): Uint8Array {
  const { l1ChainId, hub, domainChainId } = context;
  return hexToBytes(
    from === undefined
      ? encodePacked(["uint64", "address", "uint64"], [l1ChainId, hub, domainChainId])
      : encodePacked(["uint64", "address", "uint64", "address"], [l1ChainId, hub, domainChainId, from]),
  );
}

/**
 * The domain viewing keypair. Distinct from any signing key: it grants the ability to read
 * sequenced transactions and encrypted messages.
 */
export interface ViewingKeyPair {
  /** 65-byte uncompressed P-256 point. Public — every sender needs it. */
  publicKey: Hex;
  /** 32-byte P-256 scalar. Held by the domain execution client. */
  secretKey: Hex;
}

/** Generates a domain viewing keypair with the platform CSPRNG. */
export async function generateViewingKeyPair(): Promise<ViewingKeyPair> {
  const keypair = await suite.kem.generateKeyPair();
  return {
    publicKey: bytesToHex(new Uint8Array(await suite.kem.serializePublicKey(keypair.publicKey))),
    secretKey: bytesToHex(new Uint8Array(await suite.kem.serializePrivateKey(keypair.privateKey))),
  };
}

/** Encrypts `0x01 || plaintext` to the viewing key and returns `enc[65] || aead_output`. */
async function encrypt(
  viewingPublicKey: Hex,
  info: Uint8Array,
  aad: Uint8Array,
  plaintext: Uint8Array,
): Promise<Hex> {
  const publicKeyBytes = hexToBytes(viewingPublicKey);
  if (publicKeyBytes.length !== PUBLIC_KEY_SIZE || publicKeyBytes[0] !== 0x04) {
    throw new EncryptionError("viewing public key must be a 65-byte uncompressed P-256 point");
  }

  const recipientPublicKey = await suite.kem
    .deserializePublicKey(publicKeyBytes)
    .catch(() => {
      throw new EncryptionError("viewing public key is not a valid P-256 point");
    });

  const framed = new Uint8Array(plaintext.length + 1);
  framed[0] = FRAME_VERSION;
  framed.set(plaintext, 1);

  try {
    const { enc, ct } = await suite.seal({ recipientPublicKey, info }, framed, aad);

    const ciphertext = new Uint8Array(enc.byteLength + ct.byteLength);
    ciphertext.set(new Uint8Array(enc), 0);
    ciphertext.set(new Uint8Array(ct), enc.byteLength);
    return bytesToHex(ciphertext);
  } finally {
    framed.fill(0);
  }
}

/**
 * Authenticates and decrypts one encrypted payload, returning the frame-stripped plaintext.
 * The caller must wipe the returned buffer once done with it. Throws on any failure; the
 * public wrappers collapse every cause into one opaque error.
 */
async function decrypt(
  viewingSecretKey: Hex,
  info: Uint8Array,
  aad: Uint8Array,
  ciphertext: Hex,
): Promise<Uint8Array> {
  const secretKeyBytes = hexToBytes(viewingSecretKey);
  const ciphertextBytes = hexToBytes(ciphertext);

  if (
    secretKeyBytes.length !== SECRET_KEY_SIZE ||
    ciphertextBytes.length < PUBLIC_KEY_SIZE + 1 + TAG_SIZE ||
    ciphertextBytes[0] !== 0x04
  ) {
    throw new Error("invalid input");
  }

  const recipientKey = await suite.kem.deserializePrivateKey(secretKeyBytes);
  const opened = new Uint8Array(
    await suite.open(
      {
        recipientKey,
        enc: ciphertextBytes.subarray(0, PUBLIC_KEY_SIZE),
        info,
      },
      ciphertextBytes.subarray(PUBLIC_KEY_SIZE),
      aad,
    ),
  );

  if (opened.length === 0 || opened[0] !== FRAME_VERSION) {
    opened.fill(0);
    throw new Error("invalid frame");
  }

  // `slice` copies the plaintext out before the framed buffer is wiped.
  const plaintext = opened.slice(1);
  opened.fill(0);
  return plaintext;
}

/**
 * Encrypts one signed domain transaction to the domain viewing key.
 *
 * @param viewingPublicKey The domain's 65-byte uncompressed P-256 public key.
 * @param context          The L1 chain, hub and domain the ciphertext will be sequenced to.
 * @param rawTransaction   A signed transaction, as `signTransaction` returns it.
 * @returns The `rlpTx` argument to pass to `sequenceToDomain`: `enc[65] || AEAD(0x01 || rawTransaction)`.
 */
export async function encryptTransaction(
  viewingPublicKey: Hex,
  context: EncryptionContext,
  rawTransaction: Hex,
): Promise<Hex> {
  return encrypt(viewingPublicKey, TRANSACTION_INFO, associatedData(context), hexToBytes(rawTransaction));
}

/**
 * Authenticates and decrypts one ciphertext produced by {@link encryptTransaction}.
 *
 * Provided for tests and local tooling; in production this runs inside the domain
 * execution client, which is the only holder of the viewing secret key.
 *
 * @throws {EncryptionError} Always `decryption failed`, whatever went wrong — including a
 *         ciphertext made for another hub, domain or entry point.
 */
export async function decryptTransaction(
  viewingSecretKey: Hex,
  context: EncryptionContext,
  ciphertext: Hex,
): Promise<Hex> {
  try {
    const plaintext = await decrypt(viewingSecretKey, TRANSACTION_INFO, associatedData(context), ciphertext);
    const rawTransaction = bytesToHex(plaintext);
    plaintext.fill(0);
    return rawTransaction;
  } catch {
    // One opaque error keeps parsing, key and authentication failures indistinguishable, so a
    // caller cannot use this function as a decryption oracle.
    throw new EncryptionError("decryption failed");
  }
}

/**
 * Encrypts one L1 -> domain message to the domain viewing key, hiding both the
 * domain target and the payload.
 *
 * @param viewingPublicKey The domain's 65-byte uncompressed P-256 public key.
 * @param context          The L1 chain, hub and domain the ciphertext will be sent to.
 * @param from             The L1 account that will call `sendEncryptedL1Message` — a contract's
 *                         own address if a contract makes the call. Sent from any other
 *                         account, the ciphertext does not open and the message is dropped.
 * @param to               The domain target the client will deliver to.
 * @param data             The message payload, as `sendL1Message` would carry it.
 * @returns The `ciphertext` argument to pass to `sendEncryptedL1Message`:
 *          `enc[65] || AEAD(0x01 || to[20] || data)`.
 */
export async function encryptMessage(
  viewingPublicKey: Hex,
  context: EncryptionContext,
  from: Address,
  to: Address,
  data: Hex,
): Promise<Hex> {
  const dataBytes = hexToBytes(data);
  const plaintext = new Uint8Array(ADDRESS_SIZE + dataBytes.length);
  plaintext.set(hexToBytes(getAddress(to)), 0);
  plaintext.set(dataBytes, ADDRESS_SIZE);
  return encrypt(viewingPublicKey, MESSAGE_INFO, associatedData(context, from), plaintext);
}

/**
 * Authenticates and decrypts one ciphertext produced by {@link encryptMessage}, recovering
 * the `(to, data)` the client packages into the `relayL1Message` system transaction. `from` is
 * the sender the hub recorded in `EncryptedL1MessageRecorded`.
 *
 * Provided for tests and local tooling; in production this runs inside the domain
 * execution client.
 *
 * @throws {EncryptionError} Always `decryption failed`, whatever went wrong — including a
 *         plaintext too short to carry a target address.
 */
export async function decryptMessage(
  viewingSecretKey: Hex,
  context: EncryptionContext,
  from: Address,
  ciphertext: Hex,
): Promise<{ to: Address; data: Hex }> {
  try {
    const plaintext = await decrypt(viewingSecretKey, MESSAGE_INFO, associatedData(context, from), ciphertext);
    if (plaintext.length < ADDRESS_SIZE) {
      plaintext.fill(0);
      throw new Error("plaintext too short for a message");
    }
    const to = getAddress(bytesToHex(plaintext.subarray(0, ADDRESS_SIZE)));
    const data = bytesToHex(plaintext.subarray(ADDRESS_SIZE));
    plaintext.fill(0);
    return { to, data };
  } catch {
    throw new EncryptionError("decryption failed");
  }
}
