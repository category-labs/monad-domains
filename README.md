# Monad Domains

## Setting up a domain

Brings up a fully L1-sequenced domain end-to-end. Every domain transaction flows
through `DomainHub.sequenceToDomain`, so the system contracts are created by *sequencing* 
their deployment transactions as the seed deployer's first two domain transactions.

The setup tool (`offchain/src/setup.ts`, run via `npm run setup`) performs, in order:

1. deploy `DomainHub` on the L1 and `registerDomain(...)` - the admin becomes the operator
   and registers the validator set + quorum;
2. deploy `L1Bridge(hub, chainId)` (admin becomes owner);
3. precompute the domain `DomainSpoke` = `CREATE(seed, 0)` and `DomainBridge` = `CREATE(seed, 1)`;
4. sign the two domain creation transactions (gasless) and `sequenceToDomain` them through the hub;
   the spoke constructor binds `(domainChainId, operator, l1ChainId, hub)`;
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
