import { Aes128Gcm, CipherSuite, DhkemP256HkdfSha256, HkdfSha256 } from "@hpke/core";
import { bytesToHex, hexToBytes, type Hex } from "viem";

/**
 * Browser port of `offchain/src/encryption.ts` (encryption side only): every sequenced
 * domain transaction is HPKE-sealed to the domain's viewing key, so the L1 only ever
 * carries ciphertext. RFC 9180 base mode, DHKEM(P-256, HKDF-SHA256) / HKDF-SHA256 /
 * AES-128-GCM, `info` = `private-domain-hpke-rfc9180-v1`, payload `enc[65] || AEAD(0x01 || tx)`.
 */
const suite = new CipherSuite({
  kem: new DhkemP256HkdfSha256(),
  kdf: new HkdfSha256(),
  aead: new Aes128Gcm(),
});

const INFO = new TextEncoder().encode("private-domain-hpke-rfc9180-v1");
const PUBLIC_KEY_SIZE = 65;
const FRAME_VERSION = 0x01;

export async function encryptTransaction(viewingPublicKey: Hex, rawTransaction: Hex): Promise<Hex> {
  const publicKeyBytes = hexToBytes(viewingPublicKey);
  if (publicKeyBytes.length !== PUBLIC_KEY_SIZE || publicKeyBytes[0] !== 0x04) {
    throw new Error("viewing public key must be a 65-byte uncompressed P-256 point");
  }
  const recipientPublicKey = await suite.kem.deserializePublicKey(publicKeyBytes);
  const plaintext = hexToBytes(rawTransaction);
  const framed = new Uint8Array(plaintext.length + 1);
  framed[0] = FRAME_VERSION;
  framed.set(plaintext, 1);
  const { enc, ct } = await suite.seal({ recipientPublicKey, info: INFO }, framed);
  const ciphertext = new Uint8Array(enc.byteLength + ct.byteLength);
  ciphertext.set(new Uint8Array(enc), 0);
  ciphertext.set(new Uint8Array(ct), enc.byteLength);
  return bytesToHex(ciphertext);
}
