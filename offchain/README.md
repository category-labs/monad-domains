# Off-chain prover

## Domain setup

`npm run setup` (`src/setup.ts`) brings up a fully L1-sequenced domain end-to-end — deploying the
hub + L1Bridge, registering the validator set, and seeding the spoke + bridge by sequencing their
creation transactions.

## Transaction encryption

Every domain transaction handed to `sequenceToDomain` can be HPKE-encrypted to the
domain's *viewing key*, so the L1 only ever sees ciphertext and the domain execution
client — the holder of the viewing secret key — decrypts before executing. `src/encryption.ts`
implements the fixed RFC 9180 Base-mode profile the client expects:

- KEM `DHKEM(P-256, HKDF-SHA256)`, KDF `HKDF-SHA256`, AEAD `AES-128-GCM`
- `info` = `private-domain-hpke-rfc9180-v1`, no associated data
- payload = `enc[65] || AEAD(0x01 || signed_transaction)`; the domain still indexes the
  transaction by the hash of its plaintext bytes

The execution client and senders must use the exact same `info` value.

`npm run setup` and `npm run sequence` encrypt whenever `VIEWING_KEY` is set. A node started
with a receiver key for the domain (`--private-domain <id> <spoke> <key.pem>`) decrypts every
payload and drops plaintext, so set `VIEWING_KEY` whenever the node has one.

The two sides use different key encodings — the client loads an unencrypted PKCS#8 PEM, senders
use the 65-byte uncompressed public point — and `npm run viewing-key` bridges them:

```sh
npm run viewing-key -- generate domain-85679.pem   # new key: writes the PEM (mode 0600), prints VIEWING_KEY
npm run viewing-key -- public  domain-85679.pem    # VIEWING_KEY for an existing PEM (e.g. from openssl genpkey)
```

Programmatic equivalents are exported (`generateViewingKeyFiles`, `viewingPublicKeyFromPem`,
`viewingSecretKeyFromPem`, `viewingSecretKeyToPem`), alongside `encryptTransaction` /
`decryptTransaction` for tests and local tooling.

## Domain messages

All domain-origin operations use `spoke.sendDomainMessage(destinationChainId, to, data)`.
The destination chain ID selects L1 application execution or native forwarding to
another domain.

```ts
import {
  fetchDomainMessages, proveMessage, isDomainAnchorRecorded,
  domainMessageDeliveryStatus, domainDeliveryEnvelope, routedMessageDeliveryStatus,
} from "@domain-bridging/prover";

const context = { l1ChainId: L1_CHAIN_ID, hub: HUB_ADDRESS };
// Use the exact range of messages included in one finalized source batch. Include ALL
// destinations: filtering the batch before computing its root produces an invalid proof.
const batch = await fetchDomainMessages(domainA, { fromBlock, toBlock }, SPOKE_A, context);
const { message, anchor, proof } = proveMessage(batch, messageId);
await isDomainAnchorRecorded(l1, message.sourceChainId, anchor, HUB_ADDRESS);
// Permissionlessly submit hub.relayDomainMessage(message, anchor, proof).

const status = await domainMessageDeliveryStatus(l1, message, context);
// L1 destination: "pending" | "failed" | "delivered".
// Other domain: "pending" | "queued". Queued does not mean executed.

if (message.destinationChainId === L1_CHAIN_ID) {
  // A failed L1 callback is retried with hub.retryDomainMessage(message).
} else {
  // Read deliveryNonce from DomainMessageRouted; SPOKE_B is local client configuration.
  const destinationStatus = await routedMessageDeliveryStatus(
    domainB, message, SPOKE_B, deliveryNonce,
  ); // "pending" | "failed" | "delivered"
  if (destinationStatus === "failed") {
    const deliveryEnvelope = domainDeliveryEnvelope(message, deliveryNonce);
    // Submit spokeB.retryL1Message(deliveryEnvelope) with enough gas.
  }
}
```

```ts
import { fetchL1Messages, l1MessageDeliveryStatus } from "@domain-bridging/prover";
const [deposit] = await fetchL1Messages(l1, DOMAIN_CHAIN_ID, { fromBlock, toBlock }, HUB_ADDRESS);
await l1MessageDeliveryStatus(domain, deposit, SPOKE_ADDRESS);
// "pending" | "delivered" | "failed" for this recorded L1 transport envelope.
```

## Development

```sh
npm install
npm test          # conformance vectors + round-trip tests
npm run typecheck
npm run test:integration # requires forge + anvil; builds contracts and starts three local EVM chains
```
