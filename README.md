# Monad Domains

## Setting up a domain

Brings up a fully L1-sequenced domain end-to-end. Every domain transaction flows
through `DomainHub.sequenceToDomain`, so the system contracts are created by *sequencing* 
their deployment transactions as the seed deployer's first two domain transactions.

The setup tool (`offchain/src/setup.ts`, run via `npm run setup`) performs, in order:

1. deploy `DomainHub` on the L1 and `registerDomain(...)` with the validator set + quorum, the
   fee recipient, the viewing public key (published for senders) and the
   checkpoint interval;
2. deploy `L1Bridge(hub, chainId)` (admin becomes owner);
3. precompute the domain `DomainSpoke` = `CREATE(seed, 0)` and `DomainBridge` = `CREATE(seed, 1)`;
4. sign the two domain creation transactions (gasless) and `sequenceToDomain` them through the hub;
   the spoke constructor binds `(domainChainId, l1ChainId, hub)`;
5. `L1Bridge.registerDomainBridge(domainBridge)` (one-shot) against the precomputed address;
6. optionally `setTokenAllowed(token)` — e.g. the wrapped-MON ERC20 used for deposits.

Domain transactions are HPKE-encrypted to the domain's viewing key before they are
sequenced: the execution client is started with the viewing secret key
(`--private-domain <chain id> <spoke address> <key.pem>`) and decrypts every payload, so the L1 only carries
ciphertext. Create the key and print the matching `VIEWING_KEY` with
`npm run viewing-key -- generate <key.pem>` (or `-- public <key.pem>` for an existing PEM), and set
`VIEWING_KEY` in `.env`; the setup tool then encrypts the two seeded creation transactions
(a node holding a key drops plaintext payloads).

Build the contracts so the artifacts exist, then configure and run the setup from `offchain/`:

```sh
forge build

cd offchain && npm install
cp .env.example .env           # then fill in .env (see the file for every variable)
set -a && source .env && set +a
npm run setup
```

## Submitting a domain transaction

Since the domain has no mempool of its own, a user transaction is a normal signed domain
transaction whose raw bytes are handed to `DomainHub.sequenceToDomain` on the L1. The
`npm run sequence` tool (`offchain/src/sequence.ts`) builds and signs that domain transaction (gasless —
fees are prepaid on the L1), submits it through the hub, and prints both the L1 transaction hash and
the domain transaction hash.

Fill in the `npm run sequence` block of `.env` (`HUB_ADDRESS`, `SENDER_KEY`, the target `TO`/`DATA`,
and the domain nonce), then:

```sh
cd offchain
set -a && source .env && set +a
npm run sequence
```

## Domain-to-domain messaging

Domains only ever talk to the L1. `spoke.sendDomainMessage(destinationChainId, to, data)`
records one authenticated envelope whatever the destination: proven on the hub by the
relayer, an L1 destination executes `onDomainMessage` on the target, while another domain
as destination makes the hub queue the message through the same path as `sendL1Message`,
and the protocol delivers it on the destination domain as a system transaction. Tokens
follow the same shape with the bridge contracts: burn on A for an L1 recipient, then
deposit the released tokens into B (`test/bridge/DomainToDomain.t.sol` shows a router that
collapses the L1 leg into one transaction).

## End-to-end run against a single node

`offchain/src/e2e-cli.ts` (`npm run e2e`) exercises the protocol against the monad
single-node devnet from `monad-bft/docker/single-node/nets` (execution client started with
`--private-domain` and `--private-domain-sequencer`): setup, an L1 -> domain deposit
delivered by the protocol, a domain -> L1 withdrawal and the access-control checks. It
assumes a fresh chain (the hub must land at the address the node watches). Configure
`L1_RPC_URL`, `DOMAIN_CHAIN_ID` and `VIEWING_KEY`, then `forge build && cd offchain && npm run e2e`.

## Relaying: the operators' side

The protocol delivers L1 -> domain messages on its own (the node derives a system
transaction from every hub `L1MessageRecorded` event). Everything that moves *from* a
domain needs keys: the spoke operator must finalize the pending domain-origin messages
into an anchor, domain validators must attest the state transition carrying that anchor
onto the hub, and someone must prove each message to `DomainHub.relayDomainMessage`
(which executes an L1 callback or forwards the message to another domain). The relayer
service does all of this for any number of domains:

```sh
cd offchain
set -a && source .env && set +a      # L1_RPC_URL, HUB_ADDRESS, SUBMITTER_KEY, RELAYER_DOMAINS, RELAYER_<id>_*
npm run relayer
```

It indexes spoke events from a configured start block, reconstructs batches from
on-chain state (so it works with spokes that emit no finalize event and survives
restarts), waits for the finalize block to be finalized before attesting the domain
header the node serves (`monad_getDomainHeader`), and relays every finalized message.
See `offchain/README.md`.
