# Off-chain tooling

## Domain setup

`npm run setup` (`src/setup.ts`) brings up a fully L1-sequenced domain end-to-end — deploying the
hub (an upgradeable proxy owned by `HUB_OWNER`, by default the admin) + L1Bridge, registering the validator set, and seeding the spoke, default token policy and bridge by sequencing their
creation transactions. `TOKEN_POLICY_OWNER` defaults to the admin; `INITIAL_TOKEN_POLICY`
can supply an existing domain policy instead of deploying `DomainAccessRules`. Its unconfigured
selectors are open. After a token is created, the policy owner can restrict `balanceOf` with
`SubjectMatch` and mask `1`, and `allowance` with `SubjectMatch` and mask `3`. Setup registers
policy ownership and installs the policy; it does not configure per-token read rules.

## Fees

Every sequencing or message call on the hub carries a fee in L1 native tokens for the domain's fee
recipient. `hub.DOMAIN_GAS_PRICE()` (50 gwei, read with `readDomainGasPrice`) prices one unit of
domain gas: `npm run sequence` and `npm run setup` attach `gas * DOMAIN_GAS_PRICE` so the client
executes the transaction. The same price is every domain block's base fee: nothing is charged
on the domain, but a domain transaction must offer it as `maxFeePerGas` (`domainFeeCaps`), or
the client includes it as failed without executing it. A `sendL1Message` / `bridgeToDomain` / domain-bound `relayDomainMessage`
call must attach the fee of the gas its delivery needs, since the delivery runs with exactly that
much. The hub rejects anything below `hub.minDeliveryFee(payload length)`, the gas that lets the
spoke deliver or record a retryable failure, so a recorded message can be delayed by a stingy
relayer but never lost, as long as its receiver reverts instead of skipping work (see Receivers
in `PROTOCOL.md`). The hub also sells at most `DOMAIN_BLOCK_GAS_LIMIT` gas per domain per L1
block; a call that does not fit reverts and can be sent again in a later block.

A call that records a domain input costs more L1 gas when it is the domain's first of its L1
block (it opens the domain's next block in the hub's input queue) and the first of a
checkpoint period. An estimate runs against the latest block, where both may already be open,
so the tools add `HUB_INPUT_GAS_HEADROOM` to it; do the same for your own `sendL1Message`,
`bridgeToDomain` and `sequenceToDomain` calls.

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
instead of sending plaintext. The domain's execution client holds the receiver key
(`monad-domain --domain <id> <key.pem>`), decrypts every payload and drops plaintext.

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
domain's checkpoint interval, each validator reads the hash of the domain's last block there and the root
of the domain-origin messages recorded since the previous checkpoint, signs the hub's EIP-712
`StateTransition` digest and submits it. `npm run checkpoint` (`src/checkpoint-cli.ts`) is one
such pass, or with `POLL_INTERVAL_MS` a process that attests every checkpoint as it comes due;
`src/checkpoint.ts` exports the pieces (`nextCheckpointHeight`, `buildCheckpoint`,
`stateTransitionDigest`, `attestCheckpoint`). Every validator runs it independently with its
own key; the hub advances once a quorum signed the same proposal.

The domain's own chain is numbered by domain block: block 0 is derived from the L1 block that
registered the domain, and every later L1 block that recorded an input for it yields the next.
A checkpoint names an L1 height, so the tools locate it on the domain through the hub:
`hub.latestDomainBlock(domainChainId)` read at that height names the domain's latest block
there (`domainBlockAt`), and the domain's RPC (`DOMAIN_RPC_URL`, an RPC serving the domain
client's db) serves that block's hash and state (`getDomainHeader`). A pass fails, and
is simply repeated, while the domain client has not executed that block yet.

The domain's RPC answers no request without an access token, and serves blocks and the spoke's
logs to the domain's operators only. `DOMAIN_RPC_KEY` is the key of one: the tools sign
the token with it (`signDomainAccessToken`; `npm run access-token` prints one).

## Relaying

A message a domain records for the L1 is executed there once its checkpoint is attested and
someone proves it to the hub. `npm run relay` (`src/relay-cli.ts`) does that for every attested
message of one domain the hub has not seen, in one pass or with `POLL_INTERVAL_MS` as a
process; `relayPending` in `src/relay.ts` is the library form. The hub verifies each proof,
and marks a failed L1 callback for `retryDomainMessage`, so the L1 side needs no privileged
key; reading the messages from the domain's RPC takes an operator's token (`DOMAIN_RPC_KEY`).
`DomainRelayer` in `src/relayer.ts` runs the validator's and the relayer's passes for several
domains in one service.

## Domain messages

All domain-origin operations use `spoke.sendDomainMessage(destinationChainId, to, data, salt)`.
The destination chain ID selects L1 application execution or native forwarding to
another domain. The spoke stores every message id by nonce; a checkpoint anchors the nonce
range recorded since the previous checkpoint, so a batch is identified by the two attested
heights (`fetchBatches` lists them, with the domain blocks each one spans).

Every domain-bound message is sealed on chain: the spoke hands
`encodePlaintext(msg.sender, to, data)` to the execution client's encryption precompile, which
seals it to the destination's viewing key bound to the source domain, the destination and the
envelope's nonce. The envelope names neither sender nor target and carries
no salt: the ciphertext already hides its content, so `salt` is ignored for a domain destination
and only an L1 destination needs one. The hub forwards the envelope as an
`EncryptedMessageRecorded` delivery carrying only the ciphertext, which the destination client
opens into `(from, to, data)` before deriving the system transaction. A
spoke learns another domain's key through `hub.sendViewingKey(domainChainId, spoke, keyChainId)`,
which anyone may call for the delivery fee: the hub records the key as an L1 message from itself
and the spoke stores it only from such a delivery. Sending to a domain whose key the spoke does
not hold reverts, so a domain registered without a viewing key cannot receive domain messages.
Tracking a sealed message on its destination needs its plaintext, the `{ from, to, data }` it was
sent with (see `routedMessageDeliveryStatus` below). `npm run e2e:routing` (`e2e/e2e-routing-cli.ts`) runs the
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
  // The envelope is delivered as the plaintext its source spoke sealed: `plaintext` is the
  // { from, to, data } it was sent with.
  const destinationStatus = await routedMessageDeliveryStatus(
    domainB, message, SPOKE_B, deliveryNonce, plaintext,
  ); // "pending" | "failed" | "delivered"
  if (destinationStatus === "failed") {
    const deliveryEnvelope = domainDeliveryEnvelope(message, deliveryNonce, plaintext);
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
npm run e2e:bridge   # token bridge domain A -> L1 -> domain B against a two-domain devnet
npm run e2e          # deposit, withdrawal, access control and log access; expects a /domain/<id> route on the L1 RPC
npm run e2e:routing  # sealed domain -> domain route; needs a client that has the encryption precompile
```

`npm run e2e:bridge` (`e2e/e2e-bridge-cli.ts`) expects a fresh single-node devnet with one
`monad-domain` client and one domain RPC per domain: the clients started for the hub address the
admin's deployment yields, and the admin an operator of both RPCs. The header of that file lists
the environment it reads. After setup it starts validator and relayer processes and then only
acts as the user. The other two expect a `/domain/<id>` route on the L1 RPC and a spoke created
by a sequenced transaction, which `monad-domain` does not provide.

`npm run e2e` (`e2e/e2e-cli.ts`) expects a fresh single-node devnet started with the domain flags
for `DOMAIN_CHAIN_ID`; the header of that file lists the environment it reads.
