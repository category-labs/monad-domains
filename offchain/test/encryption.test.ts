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
  type EncryptionContext,
} from "../src/encryption.js";

/**
 * Behavioural tests for domain-transaction encryption. The ciphertext built here is the
 * `rlpTx` argument of `sequenceToDomain`; the domain execution client is the component
 * that decrypts it in production.
 */

const SENDER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as Hex;
const DOMAIN_CHAIN_ID = 85679;
const TO = "0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF" as const;
/** Where every ciphertext below is valid unless a test says otherwise. */
const CONTEXT: EncryptionContext = {
  l1ChainId: 20143n,
  hub: "0x5FbDB2315678afecb367f032d93F642f64180aa3",
  domainChainId: BigInt(DOMAIN_CHAIN_ID),
};
/** `CONTEXT` as associated data: l1ChainId (uint64) || hub || domainChainId (uint64). */
const CONTEXT_AAD = "0x0000000000004eaf5fbdb2315678afecb367f032d93f642f64180aa30000000000014eaf" as Hex;
/** The L1 account that calls `sendEncryptedL1Message`. */
const FROM = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" as const;
const STRANGER = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC" as const;
/** Contexts that differ from `CONTEXT` in exactly one field: the L1 chain, the hub, the domain. */
const OTHER_CONTEXTS: EncryptionContext[] = [
  { ...CONTEXT, l1ChainId: 1n },
  { ...CONTEXT, hub: STRANGER },
  { ...CONTEXT, domainChainId: 4444n },
];

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

/** The profile's suite, for tests that spell a seal or open out by hand. */
const suite = new CipherSuite({
  kem: new DhkemP256HkdfSha256(),
  kdf: new HkdfSha256(),
  aead: new Aes128Gcm(),
});

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

  const ciphertext = await encryptTransaction(publicKey, CONTEXT, rawTransaction);
  const recovered = await decryptTransaction(secretKey, CONTEXT, ciphertext);
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

test("encryption is randomized", async () => {
  const { publicKey } = await generateViewingKeyPair();
  const rawTransaction = await signDomainTransaction();

  // A fresh ephemeral key per call: the same transaction never yields the same ciphertext, so
  // nothing on the L1 can be deduplicated or correlated by ciphertext identity.
  assert.notEqual(
    await encryptTransaction(publicKey, CONTEXT, rawTransaction),
    await encryptTransaction(publicKey, CONTEXT, rawTransaction),
  );
});

test("a tampered ciphertext fails to authenticate", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();
  const ciphertext = hexToBytes(
    await encryptTransaction(publicKey, CONTEXT, await signDomainTransaction()),
  );

  const corrupted = Uint8Array.from(ciphertext);
  const lastByte = corrupted.length - 1;
  corrupted[lastByte] = (corrupted[lastByte] ?? 0) ^ 0x80;
  await expectDecryptionFailure(decryptTransaction(secretKey, CONTEXT, bytesToHex(corrupted)));

  const truncated = ciphertext.subarray(0, ciphertext.length - 1);
  await expectDecryptionFailure(decryptTransaction(secretKey, CONTEXT, bytesToHex(truncated)));
});

test("only the domain viewing key opens the ciphertext", async () => {
  const domain = await generateViewingKeyPair();
  const stranger = await generateViewingKeyPair();
  const ciphertext = await encryptTransaction(
    domain.publicKey,
    CONTEXT,
    await signDomainTransaction(),
  );

  await expectDecryptionFailure(decryptTransaction(stranger.secretKey, CONTEXT, ciphertext));
});

test("a plaintext transaction is rejected as a ciphertext", async () => {
  const { secretKey } = await generateViewingKeyPair();
  await expectDecryptionFailure(decryptTransaction(secretKey, CONTEXT, await signDomainTransaction()));
});

test("an invalid viewing key is rejected before encryption", async () => {
  const rawTransaction = await signDomainTransaction();
  await assert.rejects(
    encryptTransaction("0xdeadbeef", CONTEXT, rawTransaction),
    (error) => error instanceof EncryptionError,
  );
});

test("the wire format matches the domain encryption profile", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();
  const rawTransaction = await signDomainTransaction();
  const ciphertext = hexToBytes(await encryptTransaction(publicKey, CONTEXT, rawTransaction));

  // enc[65] || AEAD(0x01 || rawTransaction): a 65-byte encapsulated key, then the AEAD output
  // (16-byte tag) over the version-framed transaction. The associated data adds no bytes.
  assert.equal(ciphertext.length, 65 + 1 + hexToBytes(rawTransaction).length + 16);
  assert.equal(ciphertext[0], 0x04); // the encapsulated key is an uncompressed SEC1 point

  // Re-open the ciphertext with the profile spelled out explicitly, exactly as the reference
  // decrypt does. This pins the layout the execution client depends on.
  const opened = new Uint8Array(
    await suite.open(
      {
        recipientKey: await suite.kem.deserializePrivateKey(hexToBytes(secretKey)),
        enc: ciphertext.subarray(0, 65),
        info: new TextEncoder().encode("private-domain-hpke-rfc9180-v1/transaction"),
      },
      ciphertext.subarray(65),
      hexToBytes(CONTEXT_AAD),
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

  const ciphertext = await encryptMessage(publicKey, CONTEXT, FROM, TO, MESSAGE_DATA);
  const { to, data } = await decryptMessage(secretKey, CONTEXT, FROM, ciphertext);
  assert.equal(to, TO); // returned checksummed, as viem addresses are
  assert.equal(data, MESSAGE_DATA);
});

test("message round trip preserves an empty payload", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();

  const { to, data } = await decryptMessage(
    secretKey,
    CONTEXT,
    FROM,
    await encryptMessage(publicKey, CONTEXT, FROM, TO, "0x"),
  );
  assert.equal(to, TO);
  assert.equal(data, "0x");
});

test("message wire format is enc[65] || AEAD(0x01 || to[20] || data)", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();
  const ciphertext = hexToBytes(await encryptMessage(publicKey, CONTEXT, FROM, TO, MESSAGE_DATA));

  // 65-byte encapsulated key, then the AEAD output (16-byte tag) over the version-framed
  // `to[20] || data` plaintext. The associated data adds no bytes.
  assert.equal(ciphertext.length, 65 + 1 + 20 + hexToBytes(MESSAGE_DATA).length + 16);
  assert.equal(ciphertext[0], 0x04);

  // The message profile spelled out: its own info string, and the sender appended to the
  // associated data.
  const opened = new Uint8Array(
    await suite.open(
      {
        recipientKey: await suite.kem.deserializePrivateKey(hexToBytes(secretKey)),
        enc: ciphertext.subarray(0, 65),
        info: new TextEncoder().encode("private-domain-hpke-rfc9180-v1/message"),
      },
      ciphertext.subarray(65),
      hexToBytes(`${CONTEXT_AAD}${FROM.slice(2).toLowerCase()}`),
    ),
  );
  assert.equal(bytesToHex(opened), `0x01${TO.slice(2).toLowerCase()}${MESSAGE_DATA.slice(2)}`);
});

test("a tampered message ciphertext fails to authenticate", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();
  const ciphertext = hexToBytes(await encryptMessage(publicKey, CONTEXT, FROM, TO, MESSAGE_DATA));

  const corrupted = Uint8Array.from(ciphertext);
  corrupted[70] = (corrupted[70] ?? 0) ^ 0x01;
  await expectDecryptionFailure(decryptMessage(secretKey, CONTEXT, FROM, bytesToHex(corrupted)));
});

test("a plaintext shorter than an address is rejected as a message", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();

  // Sealed with the message profile by hand: authenticates fine, but 4 bytes cannot frame a
  // 20-byte target. The failure is the same opaque error as an authentication failure.
  const { enc, ct } = await suite.seal(
    {
      recipientPublicKey: await suite.kem.deserializePublicKey(hexToBytes(publicKey)),
      info: new TextEncoder().encode("private-domain-hpke-rfc9180-v1/message"),
    },
    hexToBytes("0x01deadbeef"),
    hexToBytes(`${CONTEXT_AAD}${FROM.slice(2).toLowerCase()}`),
  );
  const ciphertext = bytesToHex(new Uint8Array([...new Uint8Array(enc), ...new Uint8Array(ct)]));
  await expectDecryptionFailure(decryptMessage(secretKey, CONTEXT, FROM, ciphertext));
});

// ---------------------------------------------------------------------------
// Context binding: a ciphertext copied from L1 calldata opens only at the entry point, hub and
// domain it was made for, and a message only for the account it was made to be sent from.
// ---------------------------------------------------------------------------

test("a transaction ciphertext does not open as a message", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();
  const ciphertext = await encryptTransaction(publicKey, CONTEXT, await signDomainTransaction());

  // Whoever resubmits it through `sendEncryptedL1Message`, the client must not deliver the
  // first 20 bytes of the signed transaction as a message target.
  await expectDecryptionFailure(decryptMessage(secretKey, CONTEXT, FROM, ciphertext));
  await expectDecryptionFailure(decryptMessage(secretKey, CONTEXT, STRANGER, ciphertext));
});

test("a message ciphertext does not open as a transaction", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();
  const ciphertext = await encryptMessage(publicKey, CONTEXT, FROM, TO, MESSAGE_DATA);
  await expectDecryptionFailure(decryptTransaction(secretKey, CONTEXT, ciphertext));
});

test("a transaction ciphertext opens only for its L1 chain, hub and domain", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();
  const ciphertext = await encryptTransaction(publicKey, CONTEXT, await signDomainTransaction());

  for (const other of OTHER_CONTEXTS) {
    await expectDecryptionFailure(decryptTransaction(secretKey, other, ciphertext));
  }
});

test("a message ciphertext opens only for its L1 chain, hub and domain", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();
  const ciphertext = await encryptMessage(publicKey, CONTEXT, FROM, TO, MESSAGE_DATA);

  for (const other of OTHER_CONTEXTS) {
    await expectDecryptionFailure(decryptMessage(secretKey, other, FROM, ciphertext));
  }
});

test("a message ciphertext does not open under a different sender", async () => {
  const { publicKey, secretKey } = await generateViewingKeyPair();
  const ciphertext = await encryptMessage(publicKey, CONTEXT, FROM, TO, MESSAGE_DATA);

  // Replayed from another account, the hub records that account as `from` and the open fails.
  await expectDecryptionFailure(decryptMessage(secretKey, CONTEXT, STRANGER, ciphertext));
});
