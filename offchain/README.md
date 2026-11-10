# Off-chain tooling

## Domain setup

`npm run setup` (`src/setup.ts`) brings up a fully L1-sequenced domain end-to-end — deploying the
hub + L1Bridge, registering the validator set, and seeding the spoke + bridge by sequencing their
creation transactions.

## Fees

Every sequencing or message call on the hub carries a fee in L1 native tokens for the domain's fee
recipient. `hub.DOMAIN_GAS_PRICE()` (50 gwei, read with `readDomainGasPrice`) prices one unit of
domain gas: `npm run sequence` and `npm run setup` attach `gas * DOMAIN_GAS_PRICE` so the client
executes the transaction. A `sendL1Message` / `bridgeToDomain` / domain-bound `relayDomainMessage`
call must attach the fee of the gas its delivery needs, since the delivery runs with exactly that
much. The hub rejects anything below `hub.minDeliveryFee(payload length)`, the gas that lets the
spoke deliver or record a retryable failure, so a recorded message can be delayed by a stingy
relayer but never lost, as long as its receiver reverts instead of skipping work (see Receivers
in `PROTOCOL.md`). The hub also sells at most `DOMAIN_BLOCK_GAS_LIMIT` gas per domain per L1
block; a call that does not fit reverts and can be sent again in a later block.

## Transaction encryption

Every domain transaction handed to `sequenceToDomain` can be HPKE-encrypted to the
domain's *viewing key*, so the L1 only ever sees ciphertext and the domain execution
client — the holder of the viewing secret key — decrypts before executing. `src/encryption.ts`
implements the fixed RFC 9180 Base-mode profile the client expects:

- KEM `DHKEM(X25519, HKDF-SHA256)`, KDF `HKDF-SHA256`, AEAD `AES-128-GCM`
- empty `info`, associated data = `abi.encode("monad-transaction-encryption-v1", uint64 domainChainId)`
- payload = `enc[32] || AEAD(0x01 || signed_transaction)`; the domain still indexes the
  transaction by the hash of its plaintext bytes

The execution client and senders must use the exact same associated data.

`npm run setup` publishes `VIEWING_KEY` and uses it to encrypt the deployment transactions.
`npm run sequence` uses `VIEWING_KEY` or reads the key from the hub. It rejects a missing key
instead of sending plaintext. A node started with a receiver key for the domain
(`--private-domain <id> <spoke> <key.pem>`) decrypts every payload and drops plaintext.

The two sides use different key encodings — the client loads an unencrypted PKCS#8 PEM, senders
use the raw 32-byte public key — and `npm run viewing-key` bridges them:

```sh
npm run viewing-key -- generate domain-85679.pem   # new key: writes the PEM (mode 0600), prints VIEWING_KEY
npm run viewing-key -- public  domain-85679.pem    # VIEWING_KEY for an existing PEM (e.g. from openssl genpkey)
```

Programmatic equivalents are exported (`generateViewingKeyFiles`, `viewingPublicKeyFromPem`,
`viewingSecretKeyFromPem`, `viewingSecretKeyToPem`), alongside `encryptTransaction` /
`decryptTransaction` for tests and local tooling.

## Checkpoints

Validators attest the domain on a schedule: at every L1 height that is a multiple of the
domain's checkpoint interval, each validator reads the domain state root there and the root
of the domain-origin messages recorded since the previous checkpoint, signs the hub's EIP-712
`StateTransition` digest and submits it. `npm run checkpoint` (`src/checkpoint-cli.ts`) is one
such pass; `src/checkpoint.ts` exports the pieces (`nextCheckpointHeight`, `buildCheckpoint`,
`stateTransitionDigest`, `attestCheckpoint`). Every validator runs it independently with its
own key; the hub advances once a quorum signed the same proposal.

## Domain messages

All domain-origin operations use `spoke.sendDomainMessage(destinationChainId, to, data, salt)`.
The destination chain ID selects L1 application execution or native forwarding to
another domain. The spoke stores every message id by nonce; a checkpoint anchors the nonce
range recorded since the previous checkpoint, so a batch is identified by the two attested
heights.

Every domain-bound message is sealed on chain: the spoke hands
`encodePlaintext(msg.sender, to, data)` to the execution client's encryption precompile, which
seals it to the destination's viewing key bound to the source domain, the destination and the
envelope's nonce. The envelope has kind `Encrypted`, names neither sender nor target and carries
no salt: the ciphertext already hides its content, so `salt` is ignored for a domain destination
and only an L1 destination needs one. The hub forwards the envelope as an
`EncryptedL1MessageRecorded` delivery carrying only the ciphertext, which the destination client
opens into `(from, to, data)` before deriving the system transaction. A
spoke learns another domain's key through `hub.sendViewingKey(domainChainId, spoke, keyChainId)`,
which anyone may call for the delivery fee: the hub records the key as an L1 message from itself
and the spoke stores it only from such a delivery.
Tracking such a message needs that plaintext (`encodePlaintext` / `decodePlaintext`; see
`routedMessageDeliveryStatus` below). `npm run e2e:routing` (`e2e/e2e-routing-cli.ts`) runs the
route against a fresh two-domain devnet whose client provides the precompile (needs
`VIEWING_KEY_A` and `VIEWING_KEY_B`).

```ts
import {
  findBatchForNonce, fetchDomainBatch, proveMessage, isDomainAnchorRecorded,
  domainMessageDeliveryStatus, domainDeliveryEnvelope, routedMessageDeliveryStatus,
} from "@domain-bridging/prover";

const context = { l1ChainId: L1_CHAIN_ID, hub: HUB_ADDRESS };
// Locate the attested batch covering the message's source nonce (hub DomainStateUpdated
// events + the spoke's message count at each attested height), then rebuild it from the
// spoke's events, each id cross-checked against the spoke's stored id at the attested height.
// Include ALL destinations: filtering the batch before computing its root produces an
// invalid proof.
const located = await findBatchForNonce(l1, domainA, HUB_ADDRESS, SPOKE_A, domainAChainId, sourceNonce, { fromBlock, toBlock });
const batch = await fetchDomainBatch(domainA, SPOKE_A, located, context);
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
  // An encrypted envelope (isEncryptedDomainMessage) is delivered as the plaintext its source
  // spoke sealed, so pass the { from, to, data } it was sent with as the last argument.
  const destinationStatus = await routedMessageDeliveryStatus(
    domainB, message, SPOKE_B, deliveryNonce, /* plaintext */
  ); // "pending" | "failed" | "delivered"
  if (destinationStatus === "failed") {
    const deliveryEnvelope = domainDeliveryEnvelope(message, deliveryNonce /* , plaintext */);
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
npm test          # unit tests, including conformance vectors from script/GenVectors.s.sol
npm run typecheck
npm run e2e       # deposit, withdrawal, access control and log access against a live devnet node
npm run e2e:routing  # sealed domain -> domain route against a two-domain devnet whose client has the precompile
```

`npm run e2e` (`e2e/e2e-cli.ts`) expects a fresh single-node devnet started with the domain flags
for `DOMAIN_CHAIN_ID`; the header of that file lists the environment it reads.
