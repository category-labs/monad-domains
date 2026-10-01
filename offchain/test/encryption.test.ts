import assert from "node:assert/strict";
import { test } from "node:test";
import { bytesToHex, hexToBytes, parseTransaction, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { Aes128Gcm, CipherSuite, DhkemP256HkdfSha256, HkdfSha256 } from "@hpke/core";
import {
  EncryptionError,
  decryptMessage,
  decryptTransaction,
  encryptMessage,
  encryptTransaction,
  generateViewingKeyPair,
} from "../src/encryption.js";

/**
 * Behavioural tests for domain-transaction encryption. The ciphertext built here is the
 * `rlpTx` argument of `sequenceToDomain`; the domain execution client is the component
 * that decrypts it in production.
 */

const SENDER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as Hex;
const DOMAIN_CHAIN_ID = 85679;
const TO = "0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF" as const;

/** A realistic domain transaction: signed, EIP-1559, gasless (fees prepaid on the L1). */
async function signDomainTransaction(nonce = 42): Promise<Hex> {
  return privateKeyToAccount(SENDER_KEY).signTransaction({
    type: "eip1559",
    chainId: DOMAIN_CHAIN_ID,
    nonce,
    to: TO,
    data: "0xa9059cbb",
    value: 0n,
    gas: 1_000_000n,
    maxFeePerGas: 2n * 10n ** 9n,
    maxPriorityFeePerGas: 0n,
  });
}

async function expectDecryptionFailure(operation: Promise<unknown>) {
  await assert.rejects(operation, (error) => {
    assert.ok(error instanceof EncryptionError);
    assert.equal(error.message, "decryption failed");
    return true;
  });
}

test("round trip preserves the signed transaction", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();
  const rawTransaction = await signDomainTransaction();

  const ciphertext = await encryptTransaction(publicKey, rawTransaction);
  const recovered = await decryptTransaction(secretKey, ciphertext);
  assert.equal(recovered, rawTransaction);

  // The recovered bytes still parse as the same signed domain transaction.
  const parsed = parseTransaction(recovered);
  assert.equal(parsed.chainId, DOMAIN_CHAIN_ID);
  assert.equal(parsed.nonce, 42);
  // RLP carries no checksum casing, so the parsed address comes back lowercase.
  assert.equal(parsed.to, TO.toLowerCase());
});

test("keys match the fixed profile", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();
  assert.equal(hexToBytes(publicKey).length, 65);
  assert.equal(hexToBytes(publicKey)[0], 0x04); // uncompressed SEC1 point
  assert.equal(hexToBytes(secretKey).length, 32);
});

test("the ciphertext does not leak the plaintext", async () => {
  const { publicKey } = await generateViewingKeyPair();
  const rawTransaction = await signDomainTransaction();
  const ciphertext = await encryptTransaction(publicKey, rawTransaction);

  assert.ok(!ciphertext.slice(2).includes(rawTransaction.slice(2)));
});

test("encryption is randomized", async () => {
  const { publicKey } = await generateViewingKeyPair();
  const rawTransaction = await signDomainTransaction();

  // A fresh ephemeral key per call: the same transaction never yields the same ciphertext, so
  // nothing on the L1 can be deduplicated or correlated by ciphertext identity.
  assert.notEqual(
    await encryptTransaction(publicKey, rawTransaction),
    await encryptTransaction(publicKey, rawTransaction),
  );
});

test("a tampered ciphertext fails to authenticate", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();
  const ciphertext = hexToBytes(
    await encryptTransaction(publicKey, await signDomainTransaction()),
  );

  const corrupted = Uint8Array.from(ciphertext);
  const lastByte = corrupted.length - 1;
  corrupted[lastByte] = (corrupted[lastByte] ?? 0) ^ 0x80;
  await expectDecryptionFailure(decryptTransaction(secretKey, bytesToHex(corrupted)));

  const truncated = ciphertext.subarray(0, ciphertext.length - 1);
  await expectDecryptionFailure(decryptTransaction(secretKey, bytesToHex(truncated)));
});

test("only the domain viewing key opens the ciphertext", async () => {
  const domain = await generateViewingKeyPair();
  const stranger = await generateViewingKeyPair();
  const ciphertext = await encryptTransaction(
    domain.publicKey,
    await signDomainTransaction(),
  );

  await expectDecryptionFailure(decryptTransaction(stranger.secretKey, ciphertext));
});

test("a plaintext transaction is rejected as a ciphertext", async () => {
  const { secretKey } = await generateViewingKeyPair();
  await expectDecryptionFailure(decryptTransaction(secretKey, await signDomainTransaction()));
});

test("an invalid viewing key is rejected before encryption", async () => {
  const rawTransaction = await signDomainTransaction();
  await assert.rejects(
    encryptTransaction("0xdeadbeef", rawTransaction),
    (error) => error instanceof EncryptionError,
  );
});

test("the wire format matches the domain encryption profile", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();
  const rawTransaction = await signDomainTransaction();
  const ciphertext = hexToBytes(await encryptTransaction(publicKey, rawTransaction));

  // enc[65] || AEAD(0x01 || rawTransaction): a 65-byte encapsulated key, then the AEAD output
  // (16-byte tag) over the version-framed transaction, with no associated data.
  assert.equal(ciphertext.length, 65 + 1 + hexToBytes(rawTransaction).length + 16);
  assert.equal(ciphertext[0], 0x04); // the encapsulated key is an uncompressed SEC1 point

  // Re-open the ciphertext with the profile spelled out explicitly, exactly as the reference
  // decrypt does. This pins the layout the execution client depends on.
  const suite = new CipherSuite({
    kem: new DhkemP256HkdfSha256(),
    kdf: new HkdfSha256(),
    aead: new Aes128Gcm(),
  });
  const opened = new Uint8Array(
    await suite.open(
      {
        recipientKey: await suite.kem.deserializePrivateKey(hexToBytes(secretKey)),
        enc: ciphertext.subarray(0, 65),
        info: new TextEncoder().encode("private-domain-hpke-rfc9180-v1"),
      },
      ciphertext.subarray(65),
    ),
  );

  assert.equal(opened[0], 0x01); // the profile's frame byte
  assert.equal(bytesToHex(opened.subarray(1)), rawTransaction);
});

// ---------------------------------------------------------------------------
// L1 -> domain messages: the ciphertext built here is the `ciphertext` argument of
// `sendEncryptedL1Message`, sealing `to[20] || data`.
// ---------------------------------------------------------------------------

const MESSAGE_DATA = "0xa9059cbb000000000000000000000000000000000000000000000000000000000000002a" as Hex;

test("message round trip preserves target and payload", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();

  const ciphertext = await encryptMessage(publicKey, TO, MESSAGE_DATA);
  const { to, data } = await decryptMessage(secretKey, ciphertext);
  assert.equal(to, TO); // returned checksummed, as viem addresses are
  assert.equal(data, MESSAGE_DATA);
});

test("message round trip preserves an empty payload", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();

  const { to, data } = await decryptMessage(
    secretKey,
    await encryptMessage(publicKey, TO, "0x"),
  );
  assert.equal(to, TO);
  assert.equal(data, "0x");
});

test("message wire format is enc[65] || AEAD(0x01 || to[20] || data)", async () => {
  const { publicKey } = await generateViewingKeyPair();
  const ciphertext = hexToBytes(await encryptMessage(publicKey, TO, MESSAGE_DATA));

  // 65-byte encapsulated key, then the AEAD output (16-byte tag) over the version-framed
  // `to[20] || data` plaintext, with no associated data. Same profile as transactions.
  assert.equal(ciphertext.length, 65 + 1 + 20 + hexToBytes(MESSAGE_DATA).length + 16);
  assert.equal(ciphertext[0], 0x04);
});

test("a tampered message ciphertext fails to authenticate", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();
  const ciphertext = hexToBytes(await encryptMessage(publicKey, TO, MESSAGE_DATA));

  const corrupted = Uint8Array.from(ciphertext);
  corrupted[70] = (corrupted[70] ?? 0) ^ 0x01;
  await expectDecryptionFailure(decryptMessage(secretKey, bytesToHex(corrupted)));
});

test("a plaintext shorter than an address is rejected as a message", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();

  // Sealed through the transaction pathway: authenticates fine, but 4 bytes cannot frame a
  // 20-byte target. The failure is the same opaque error as an authentication failure.
  const ciphertext = await encryptTransaction(publicKey, "0xdeadbeef");
  await expectDecryptionFailure(decryptMessage(secretKey, ciphertext));
});
