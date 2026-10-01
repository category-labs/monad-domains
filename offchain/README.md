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

## Usage

Withdrawals (domain -> L1) are the proof-carrying direction: an anchor commits to the
messages the operator finalized, and `DomainHub.relayDomainMessage` verifies a merkle proof
against it.

```ts
import { createPublicClient, http } from "viem";
import {
  fetchDomainMessages,
  proveMessage,
  isDomainAnchorRecorded,
  domainMessageDeliveryStatus,
} from "@domain-bridging/prover";

const l1 = createPublicClient({ transport: http(L1_RPC_URL) });
const domain = createPublicClient({ transport: http(DOMAIN_RPC_URL) });

// 1. Reconstruct the batch: the recorded withdrawal messages (DomainMessageRecorded
//    events on the spoke). The batch must be exactly the set pending when the operator
//    called finalizeDomainMessages, so the block range must line up with the operator's
//    finalize cadence; a misaligned batch produces an anchor that was never recorded and
//    simply fails the anchor check.
const batch = await fetchDomainMessages(domain, { fromBlock, toBlock }, SPOKE_ADDRESS);

// 2. Build the proof and confirm the anchor was attested onto the hub.
const { message, anchor, proof } = proveMessage(batch, withdrawalMessageHash);
await isDomainAnchorRecorded(l1, DOMAIN_CHAIN_ID, anchor, HUB_ADDRESS); // -> true once attested

// 3. Relay: hub.relayDomainMessage(DOMAIN_CHAIN_ID, message, anchor, proof)
//    from any account. The hub calls L1Bridge.onDomainMessage with the authenticated source.

// 4. Check delivery, since a successful relay transaction may contain a failed callback.
await domainMessageDeliveryStatus(l1, DOMAIN_CHAIN_ID, withdrawalMessageHash, HUB_ADDRESS);
// -> "pending" | "delivered" | "failed". Retry failures with
//    hub.retryDomainMessage(DOMAIN_CHAIN_ID, message), without another proof.
```

Deposits (L1 -> domain) need no proofs and no finalization transaction: the domain
protocol derives one system transaction per hub `L1MessageRecorded` event and delivers it
to the spoke (`relayL1Message`, in event order). The tooling here just indexes and watches:

```ts
import { fetchL1Messages, l1MessageDeliveryStatus } from "@domain-bridging/prover";

const [deposit] = await fetchL1Messages(l1, DOMAIN_CHAIN_ID, { fromBlock, toBlock }, HUB_ADDRESS);
await l1MessageDeliveryStatus(domain, deposit, SPOKE_ADDRESS);
// -> "pending" | "delivered" | "failed"; a failed target call is permissionlessly
//    re-executable via spoke.retryL1Message with the message preimage.
```

## Development

```sh
npm install
npm test          # conformance vectors + round-trip tests
npm run typecheck
```
