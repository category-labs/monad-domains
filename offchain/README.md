# Off-chain prover and relayer

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

## Relayer service

`npm run relayer` (`src/relayer.ts`) is the long-running service a domain needs besides the
execution client. The protocol delivers L1 -> domain messages on its own, but everything that
moves from a domain to the L1 is signed by keys this service holds. For each configured domain
it loops over:

1. indexing `DomainMessageRecorded` events from the spoke (log windows over the domain RPC
   route, up to the finalized head, re-reading a short tail so late-executing blocks are
   never skipped);
2. sequencing `spoke.finalizeDomainMessages()` from the spoke operator through the hub whenever
   the spoke holds pending messages, and cutting the batch at the finalize transaction's
   position in the recorded message list;
3. attesting the finalized domain header (`monad_getDomainHeader` on the domain route returns
   the L1 height it committed at and its state root) onto the hub with the batch anchor
   (`submitStateSignature` from each configured validator until the hub reports
   `DomainStateUpdated`), once the finalize block itself is finalized; or with a zero anchor
   every `ATTEST_INTERVAL_MS` while the domain is idle and no batch is waiting;
4. proving and relaying every finalized message whose anchor the hub has recorded
   (`relayDomainMessage` from the submitter account): an L1 destination executes the receiver
   callback, a domain destination is forwarded by the hub and delivered by the protocol.

Batches are reconstructed from on-chain state, not persisted: the spoke's pending list is
append-only until a finalize clears it, so every batch is a contiguous run of the recorded
messages. Already attested batches are recognised by matching prefix roots against
`hub.domainAnchors`; a batch finalized but not yet attested when the service restarts is
recovered by locating the operator's finalize transactions in the domain receipts
(`eth_getBlockReceipts`) of the blocks the hub sequenced into (`DomainTransactionSequenced`).
A spoke that emits `DomainMessagesFinalized` (the event this branch adds to `DomainSpoke`)
short-circuits the reconstruction. Every step is idempotent against `domainAnchors`,
`hasVotedFor` and `relayedDomainMessages`, so the service can be restarted at any time; it
re-indexes from `RELAYER_<id>_START_BLOCK` (the block the domain was registered in).

Configure it in `.env` (see `.env.example`: `HUB_ADDRESS`, `SUBMITTER_KEY`, `RELAYER_DOMAINS`
and one `RELAYER_<chain id>_*` block per domain) and run:

```sh
set -a && source .env && set +a
npm run relayer
```

`DomainRelayer` is also exported for embedding (`start()` / `stop()` / `tick()` / `status()`).

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
