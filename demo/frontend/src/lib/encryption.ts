import { Aes128Gcm, CipherSuite, DhkemX25519HkdfSha256, HkdfSha256 } from "@hpke/core";
import { bytesToHex, encodeAbiParameters, hexToBytes, type Hex } from "viem";

/**
 * Browser port of `offchain/src/encryption.ts` (encryption side only): every sequenced
 * domain transaction is HPKE-sealed to the domain's viewing key, so the L1 only ever
 * carries ciphertext. RFC 9180 base mode, DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 /
 * AES-128-GCM, empty `info`, associated data `abi.encode("monad-transaction-encryption-v1",
 * uint64 domainChainId)`, payload `enc[32] || AEAD(0x01 || tx)`.
 */
const suite = new CipherSuite({
  kem: new DhkemX25519HkdfSha256(),
  kdf: new HkdfSha256(),
  aead: new Aes128Gcm(),
});

const PUBLIC_KEY_SIZE = 32;
const FRAME_VERSION = 0x01;

export async function encryptTransaction(viewingPublicKey: Hex, domainChainId: bigint, rawTransaction: Hex): Promise<Hex> {
  const publicKeyBytes = hexToBytes(viewingPublicKey);
  if (publicKeyBytes.length !== PUBLIC_KEY_SIZE) {
    throw new Error("viewing public key must be a 32-byte X25519 public key");
  }
  const recipientPublicKey = await suite.kem.deserializePublicKey(publicKeyBytes);
  const plaintext = hexToBytes(rawTransaction);
  const framed = new Uint8Array(plaintext.length + 1);
  framed[0] = FRAME_VERSION;
  framed.set(plaintext, 1);
  const aad = hexToBytes(
    encodeAbiParameters([{ type: "string" }, { type: "uint64" }], ["monad-transaction-encryption-v1", domainChainId]),
  );
  const { enc, ct } = await suite.seal({ recipientPublicKey }, framed, aad);
  const ciphertext = new Uint8Array(enc.byteLength + ct.byteLength);
  ciphertext.set(new Uint8Array(enc), 0);
  ciphertext.set(new Uint8Array(ct), enc.byteLength);
  return bytesToHex(ciphertext);
}
