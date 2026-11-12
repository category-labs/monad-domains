import { Aes128Gcm, CipherSuite, DhkemX25519HkdfSha256, HkdfSha256 } from "@hpke/core";
import { bytesToHex, encodeAbiParameters, getAddress, hexToBytes, type Address, type Hex } from "viem";

/**
 * HPKE (RFC 9180, Base mode) encryption of domain transactions and L1 -> domain messages to a
 * domain's viewing key, with empty `info`. Ciphertext format: `enc[32] || AEAD(0x01 || plaintext)`.
 */

const suite = new CipherSuite({
  kem: new DhkemX25519HkdfSha256(),
  kdf: new HkdfSha256(),
  aead: new Aes128Gcm(),
});

/** X25519 public key, which is also the size of the encapsulated key. */
const PUBLIC_KEY_SIZE = 32;
/** X25519 secret key. */
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

/**
 * Associated data of a sequenced transaction: `abi.encode("monad-transaction-encryption-v1",
 * uint64 domainChainId)`, so a ciphertext opens only as a transaction of the domain it was
 * sealed for.
 */
function transactionAssociatedData(domainChainId: bigint): Uint8Array {
  return hexToBytes(
    encodeAbiParameters(
      [{ type: "string" }, { type: "uint64" }],
      ["monad-transaction-encryption-v1", domainChainId],
    ),
  );
}

/** Raised for every encryption and decryption failure. */
export class EncryptionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "EncryptionError";
  }
}

/**
 * The domain viewing keypair. Distinct from any signing key: it grants the ability to read
 * sequenced transactions and encrypted messages.
 */
export interface ViewingKeyPair {
  /** 32-byte X25519 public key. Public — every sender needs it. */
  publicKey: Hex;
  /** 32-byte X25519 secret key. Held by the domain execution client. */
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

/** Encrypts `0x01 || plaintext` to the viewing key and returns `enc[32] || aead_output`. */
async function encrypt(viewingPublicKey: Hex, plaintext: Uint8Array, aad?: Uint8Array): Promise<Hex> {
  const publicKeyBytes = hexToBytes(viewingPublicKey);
  if (publicKeyBytes.length !== PUBLIC_KEY_SIZE) {
    throw new EncryptionError("viewing public key must be a 32-byte X25519 public key");
  }
  const recipientPublicKey = await suite.kem.deserializePublicKey(publicKeyBytes);

  const framed = new Uint8Array(plaintext.length + 1);
  framed[0] = FRAME_VERSION;
  framed.set(plaintext, 1);

  try {
    // A low-order point yields an all-zero shared secret, which X25519 rejects.
    const { enc, ct } = await suite.seal({ recipientPublicKey }, framed, aad).catch(() => {
      throw new EncryptionError("viewing public key is not a valid X25519 public key");
    });

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
async function decrypt(viewingSecretKey: Hex, ciphertext: Hex, aad?: Uint8Array): Promise<Uint8Array> {
  const secretKeyBytes = hexToBytes(viewingSecretKey);
  const ciphertextBytes = hexToBytes(ciphertext);

  if (secretKeyBytes.length !== SECRET_KEY_SIZE || ciphertextBytes.length < PUBLIC_KEY_SIZE + 1 + TAG_SIZE) {
    throw new Error("invalid input");
  }

  const recipientKey = await suite.kem.deserializePrivateKey(secretKeyBytes);
  const opened = new Uint8Array(
    await suite.open(
      { recipientKey, enc: ciphertextBytes.subarray(0, PUBLIC_KEY_SIZE) },
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
 * @param viewingPublicKey The domain's 32-byte X25519 public key.
 * @param domainChainId    The domain the transaction will be sequenced to.
 * @param rawTransaction   A signed transaction, as `signTransaction` returns it.
 * @returns The `rlpTx` argument to pass to `sequenceToDomain`: `enc[32] || AEAD(0x01 || rawTransaction)`.
 */
export async function encryptTransaction(
  viewingPublicKey: Hex,
  domainChainId: bigint,
  rawTransaction: Hex,
): Promise<Hex> {
  return encrypt(viewingPublicKey, hexToBytes(rawTransaction), transactionAssociatedData(domainChainId));
}

/**
 * Authenticates and decrypts one ciphertext produced by {@link encryptTransaction}.
 *
 * Provided for tests and local tooling; in production this runs inside the domain
 * execution client, which is the only holder of the viewing secret key.
 *
 * @throws {EncryptionError} Always `decryption failed`, whatever went wrong.
 */
export async function decryptTransaction(
  viewingSecretKey: Hex,
  domainChainId: bigint,
  ciphertext: Hex,
): Promise<Hex> {
  try {
    const plaintext = await decrypt(viewingSecretKey, ciphertext, transactionAssociatedData(domainChainId));
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
 * domain target and the payload. A message has no associated data.
 *
 * @param viewingPublicKey The domain's 32-byte X25519 public key.
 * @param to               The domain target the client will deliver to.
 * @param data             The message payload, as `sendL1Message` would carry it.
 * @returns The `ciphertext` argument to pass to `sendEncryptedL1Message`:
 *          `enc[32] || AEAD(0x01 || to[20] || data)`.
 */
export async function encryptMessage(viewingPublicKey: Hex, to: Address, data: Hex): Promise<Hex> {
  const dataBytes = hexToBytes(data);
  const plaintext = new Uint8Array(ADDRESS_SIZE + dataBytes.length);
  plaintext.set(hexToBytes(getAddress(to)), 0);
  plaintext.set(dataBytes, ADDRESS_SIZE);
  return encrypt(viewingPublicKey, plaintext);
}

/**
 * Authenticates and decrypts one ciphertext produced by {@link encryptMessage}, recovering
 * the `(to, data)` the client packages into the `relayL1Message` system transaction.
 *
 * Provided for tests and local tooling; in production this runs inside the domain
 * execution client.
 *
 * @throws {EncryptionError} Always `decryption failed`, whatever went wrong — including a
 *         plaintext too short to carry a target address.
 */
export async function decryptMessage(
  viewingSecretKey: Hex,
  ciphertext: Hex,
): Promise<{ to: Address; data: Hex }> {
  try {
    const plaintext = await decrypt(viewingSecretKey, ciphertext);
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
