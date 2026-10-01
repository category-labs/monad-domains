import { createECDH, createPrivateKey, createPublicKey, generateKeyPairSync } from "node:crypto";
import { bytesToHex, hexToBytes, type Hex } from "viem";
import { EncryptionError } from "./encryption.js";

/**
 * Conversions between the two encodings of a domain viewing key.
 *
 * The domain execution client loads the viewing SECRET key from an unencrypted PKCS#8 PEM
 * file. Senders pass the viewing PUBLIC key to `encryptTransaction` as a 65-byte uncompressed
 * SEC1 point, and the offchain decrypt helpers take the raw 32-byte scalar. These helpers move 
 * between the two so a key generated on either side can be used on the other.
 */

/** A viewing keypair in every encoding the system needs. */
export interface ViewingKeyFiles {
  /** Unencrypted PKCS#8 PEM — what the execution client loads. */
  privateKeyPem: string;
  /** SubjectPublicKeyInfo PEM, for distribution alongside the hex form. */
  publicKeyPem: string;
  /** 65-byte uncompressed P-256 point — what senders pass to `encryptTransaction`. */
  publicKey: Hex;
  /** 32-byte scalar — what the offchain decrypt helpers take. */
  secretKey: Hex;
}

const CURVE = "P-256";
const COORDINATE_SIZE = 32;

interface EcJwk {
  kty?: string;
  crv?: string;
  x?: string;
  y?: string;
  d?: string;
}

function coordinate(value: string | undefined, name: string): Uint8Array {
  const bytes = value === undefined ? new Uint8Array() : new Uint8Array(Buffer.from(value, "base64url"));
  if (bytes.length !== COORDINATE_SIZE) {
    throw new EncryptionError(`viewing key ${name} coordinate must be ${COORDINATE_SIZE} bytes`);
  }
  return bytes;
}

function assertP256(jwk: EcJwk): void {
  if (jwk.kty !== "EC" || jwk.crv !== CURVE) {
    throw new EncryptionError("viewing key must be a P-256 EC key");
  }
}

/**
 * Derives the 65-byte uncompressed viewing public key from a P-256 PEM. Accepts either the
 * public-key PEM or the private-key PEM the client loads.
 */
export function viewingPublicKeyFromPem(pem: string): Hex {
  let jwk: EcJwk;
  try {
    jwk = createPublicKey(pem).export({ format: "jwk" }) as EcJwk;
  } catch {
    throw new EncryptionError("not a readable P-256 PEM key");
  }
  assertP256(jwk);
  const point = new Uint8Array(1 + 2 * COORDINATE_SIZE);
  point[0] = 0x04;
  point.set(coordinate(jwk.x, "x"), 1);
  point.set(coordinate(jwk.y, "y"), 1 + COORDINATE_SIZE);
  return bytesToHex(point);
}

/** Extracts the raw 32-byte scalar from a P-256 private-key PEM, for the offchain decrypt helpers. */
export function viewingSecretKeyFromPem(pem: string): Hex {
  let jwk: EcJwk;
  try {
    jwk = createPrivateKey(pem).export({ format: "jwk" }) as EcJwk;
  } catch {
    throw new EncryptionError("not a readable P-256 private-key PEM");
  }
  assertP256(jwk);
  return bytesToHex(coordinate(jwk.d, "d"));
}

/**
 * Wraps a raw 32-byte scalar (as `generateViewingKeyPair` returns it) into the unencrypted
 * PKCS#8 PEM the execution client loads.
 */
export function viewingSecretKeyToPem(secretKey: Hex): string {
  const scalar = hexToBytes(secretKey);
  if (scalar.length !== COORDINATE_SIZE) {
    throw new EncryptionError(`viewing secret key must be ${COORDINATE_SIZE} bytes`);
  }
  // PKCS#8 carries the public point too; recover it from the scalar.
  const ecdh = createECDH("prime256v1");
  let point: Buffer;
  try {
    ecdh.setPrivateKey(Buffer.from(scalar));
    point = ecdh.getPublicKey();
  } catch {
    throw new EncryptionError("viewing secret key is not a valid P-256 scalar");
  }
  const jwk = {
    kty: "EC",
    crv: CURVE,
    d: Buffer.from(scalar).toString("base64url"),
    x: point.subarray(1, 1 + COORDINATE_SIZE).toString("base64url"),
    y: point.subarray(1 + COORDINATE_SIZE).toString("base64url"),
  };
  return createPrivateKey({ key: jwk, format: "jwk" }).export({ type: "pkcs8", format: "pem" }) as string;
}

/** Generates a fresh viewing keypair with the platform CSPRNG, in every encoding. */
export function generateViewingKeyFiles(): ViewingKeyFiles {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: CURVE });
  const privateKeyPem = privateKey.export({ type: "pkcs8", format: "pem" }) as string;
  const publicKeyPem = publicKey.export({ type: "spki", format: "pem" }) as string;
  return {
    privateKeyPem,
    publicKeyPem,
    publicKey: viewingPublicKeyFromPem(publicKeyPem),
    secretKey: viewingSecretKeyFromPem(privateKeyPem),
  };
}
