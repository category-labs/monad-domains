import { createPrivateKey, createPublicKey, generateKeyPairSync } from "node:crypto";
import { bytesToHex, hexToBytes, type Hex } from "viem";
import { EncryptionError } from "./encryption.js";

/**
 * Conversions between the two encodings of a domain viewing key.
 *
 * The domain execution client loads the viewing SECRET key from an unencrypted PKCS#8 PEM
 * file. Senders pass the viewing PUBLIC key to `encryptTransaction` as its raw 32 bytes, and
 * the offchain decrypt helpers take the raw 32-byte secret key. These helpers move between the
 * two so a key generated on either side can be used on the other.
 */

/** A viewing keypair in every encoding the system needs. */
export interface ViewingKeyFiles {
  /** Unencrypted PKCS#8 PEM — what the execution client loads. */
  privateKeyPem: string;
  /** SubjectPublicKeyInfo PEM, for distribution alongside the hex form. */
  publicKeyPem: string;
  /** 32-byte X25519 public key — what senders pass to `encryptTransaction`. */
  publicKey: Hex;
  /** 32-byte X25519 secret key — what the offchain decrypt helpers take. */
  secretKey: Hex;
}

const CURVE = "X25519";
const KEY_SIZE = 32;
/** DER encoding of an X25519 PKCS#8 private key, up to the 32 key bytes that end it. */
const PKCS8_PREFIX = Buffer.from("302e020100300506032b656e04220420", "hex");

interface OkpJwk {
  kty?: string;
  crv?: string;
  x?: string;
  d?: string;
}

function keyBytes(jwk: OkpJwk, member: "x" | "d"): Hex {
  if (jwk.kty !== "OKP" || jwk.crv !== CURVE) {
    throw new EncryptionError("viewing key must be an X25519 key");
  }
  const bytes = new Uint8Array(Buffer.from(jwk[member] ?? "", "base64url"));
  if (bytes.length !== KEY_SIZE) {
    throw new EncryptionError(`viewing key must be ${KEY_SIZE} bytes`);
  }
  return bytesToHex(bytes);
}

/**
 * Derives the 32-byte viewing public key from an X25519 PEM. Accepts either the public-key PEM
 * or the private-key PEM the client loads.
 */
export function viewingPublicKeyFromPem(pem: string): Hex {
  let jwk: OkpJwk;
  try {
    jwk = createPublicKey(pem).export({ format: "jwk" }) as OkpJwk;
  } catch {
    throw new EncryptionError("not a readable X25519 PEM key");
  }
  return keyBytes(jwk, "x");
}

/** Extracts the raw 32-byte secret key from an X25519 private-key PEM, for the offchain decrypt helpers. */
export function viewingSecretKeyFromPem(pem: string): Hex {
  let jwk: OkpJwk;
  try {
    jwk = createPrivateKey(pem).export({ format: "jwk" }) as OkpJwk;
  } catch {
    throw new EncryptionError("not a readable X25519 private-key PEM");
  }
  return keyBytes(jwk, "d");
}

/**
 * Wraps a raw 32-byte secret key (as `generateViewingKeyPair` returns it) into the unencrypted
 * PKCS#8 PEM the execution client loads.
 */
export function viewingSecretKeyToPem(secretKey: Hex): string {
  const key = hexToBytes(secretKey);
  if (key.length !== KEY_SIZE) {
    throw new EncryptionError(`viewing secret key must be ${KEY_SIZE} bytes`);
  }
  return createPrivateKey({ key: Buffer.concat([PKCS8_PREFIX, key]), format: "der", type: "pkcs8" }).export({
    type: "pkcs8",
    format: "pem",
  }) as string;
}

/** Generates a fresh viewing keypair with the platform CSPRNG, in every encoding. */
export function generateViewingKeyFiles(): ViewingKeyFiles {
  const { privateKey, publicKey } = generateKeyPairSync("x25519");
  const privateKeyPem = privateKey.export({ type: "pkcs8", format: "pem" }) as string;
  const publicKeyPem = publicKey.export({ type: "spki", format: "pem" }) as string;
  return {
    privateKeyPem,
    publicKeyPem,
    publicKey: viewingPublicKeyFromPem(publicKeyPem),
    secretKey: viewingSecretKeyFromPem(privateKeyPem),
  };
}
