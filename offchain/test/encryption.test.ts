import assert from "node:assert/strict";
import { test } from "node:test";
import { bytesToHex, hexToBytes, parseTransaction, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  EncryptionError,
  decryptTransaction,
  encryptTransaction,
  generateViewingKeyPair,
} from "../src/encryption.js";
import { viewingPublicKeyFromPem, viewingSecretKeyFromPem, viewingSecretKeyToPem } from "../src/viewing-key.js";

/**
 * Behavioural tests for domain-transaction encryption. The ciphertext built here is the
 * `rlpTx` argument of `sequenceToDomain`; the domain execution client is the component
 * that decrypts it in production.
 */

const SENDER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as Hex;
const DOMAIN_CHAIN_ID = 85679n;
const TO = "0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF" as const;

// Fixtures of the execution client's HPKE tests: its key file (secret key 0x11 * 32), and the
// transaction `0x02c0` sealed to it for CLIENT_DOMAIN by an independent HPKE implementation.
const CLIENT_KEY_PEM = `-----BEGIN PRIVATE KEY-----
MC4CAQAwBQYDK2VuBCIEIBERERERERERERERERERERERERERERERERERERERERER
-----END PRIVATE KEY-----
`;
const CLIENT_DOMAIN = 0x510000004eafn;
const CLIENT_PAYLOAD =
  "0xa04588b74683334f6e7670db45cca1288fc2c1499d78715d9456f5d99261a823a3c6898d05630de04949dbf70f2e544a52814e" as Hex;

/** A realistic domain transaction: signed, EIP-1559, gasless (fees prepaid on the L1). */
async function signDomainTransaction(nonce = 42): Promise<Hex> {
  return privateKeyToAccount(SENDER_KEY).signTransaction({
    type: "eip1559",
    chainId: Number(DOMAIN_CHAIN_ID),
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

  const ciphertext = await encryptTransaction(publicKey, DOMAIN_CHAIN_ID, rawTransaction);
  const recovered = await decryptTransaction(secretKey, DOMAIN_CHAIN_ID, ciphertext);
  assert.equal(recovered, rawTransaction);

  // The recovered bytes still parse as the same signed domain transaction.
  const parsed = parseTransaction(recovered);
  assert.equal(parsed.chainId, Number(DOMAIN_CHAIN_ID));
  assert.equal(parsed.nonce, 42);
  // RLP carries no checksum casing, so the parsed address comes back lowercase.
  assert.equal(parsed.to, TO.toLowerCase());
});

test("keys match the fixed profile", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();
  assert.equal(hexToBytes(publicKey).length, 32);
  assert.equal(hexToBytes(secretKey).length, 32);
});

test("viewing key encodings match the execution client's key file", () => {
  const secretKey = `0x${"11".repeat(32)}` as const;
  assert.equal(viewingSecretKeyFromPem(CLIENT_KEY_PEM), secretKey);
  assert.equal(viewingSecretKeyToPem(secretKey), CLIENT_KEY_PEM);
  assert.equal(
    viewingPublicKeyFromPem(CLIENT_KEY_PEM),
    "0x7b4e909bbe7ffe44c465a220037d608ee35897d31ef972f07f74892cb0f73f13",
  );
});

test("encryption is randomized", async () => {
  const { publicKey } = await generateViewingKeyPair();
  const rawTransaction = await signDomainTransaction();

  // A fresh ephemeral key per call: the same transaction never yields the same ciphertext, so
  // nothing on the L1 can be deduplicated or correlated by ciphertext identity.
  assert.notEqual(
    await encryptTransaction(publicKey, DOMAIN_CHAIN_ID, rawTransaction),
    await encryptTransaction(publicKey, DOMAIN_CHAIN_ID, rawTransaction),
  );
});

test("a tampered ciphertext fails to authenticate", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();
  const ciphertext = hexToBytes(
    await encryptTransaction(publicKey, DOMAIN_CHAIN_ID, await signDomainTransaction()),
  );

  const corrupted = Uint8Array.from(ciphertext);
  const lastByte = corrupted.length - 1;
  corrupted[lastByte] = (corrupted[lastByte] ?? 0) ^ 0x80;
  await expectDecryptionFailure(decryptTransaction(secretKey, DOMAIN_CHAIN_ID, bytesToHex(corrupted)));

  const truncated = ciphertext.subarray(0, ciphertext.length - 1);
  await expectDecryptionFailure(decryptTransaction(secretKey, DOMAIN_CHAIN_ID, bytesToHex(truncated)));
});

test("only the domain viewing key opens the ciphertext", async () => {
  const domain = await generateViewingKeyPair();
  const stranger = await generateViewingKeyPair();
  const ciphertext = await encryptTransaction(
    domain.publicKey,
    DOMAIN_CHAIN_ID,
    await signDomainTransaction(),
  );

  await expectDecryptionFailure(decryptTransaction(stranger.secretKey, DOMAIN_CHAIN_ID, ciphertext));
});

test("a transaction opens only in the domain it was sealed for", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();
  const ciphertext = await encryptTransaction(publicKey, DOMAIN_CHAIN_ID, await signDomainTransaction());

  await expectDecryptionFailure(decryptTransaction(secretKey, DOMAIN_CHAIN_ID + 1n, ciphertext));
});

test("a plaintext transaction is rejected as a ciphertext", async () => {
  const { secretKey } = await generateViewingKeyPair();
  await expectDecryptionFailure(decryptTransaction(secretKey, DOMAIN_CHAIN_ID, await signDomainTransaction()));
});

test("an invalid viewing key is rejected before encryption", async () => {
  const rawTransaction = await signDomainTransaction();
  // Wrong length, then a low-order point.
  for (const viewingKey of ["0xdeadbeef", `0x${"00".repeat(32)}`] as const) {
    await assert.rejects(
      encryptTransaction(viewingKey, DOMAIN_CHAIN_ID, rawTransaction),
      (error) => error instanceof EncryptionError,
    );
  }
});

test("the wire format matches the domain encryption profile", async () => {
  const { publicKey } = await generateViewingKeyPair();
  const rawTransaction = await signDomainTransaction();
  const ciphertext = hexToBytes(await encryptTransaction(publicKey, DOMAIN_CHAIN_ID, rawTransaction));

  // enc[32] || AEAD(0x01 || rawTransaction): a 32-byte encapsulated key, then the AEAD output
  // (16-byte tag) over the version-framed transaction.
  assert.equal(ciphertext.length, 32 + 1 + hexToBytes(rawTransaction).length + 16);

  // The same decrypt opens what the execution client opens, which pins the whole profile.
  assert.equal(
    await decryptTransaction(viewingSecretKeyFromPem(CLIENT_KEY_PEM), CLIENT_DOMAIN, CLIENT_PAYLOAD),
    "0x02c0",
  );
});
