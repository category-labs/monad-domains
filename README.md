# Monad Domains

## Setting up a domain

Brings up a fully L1-sequenced domain end-to-end. Every domain transaction flows
through `DomainHub.sequenceToDomain`, so the system contracts are created by *sequencing*
their deployment transactions as the seed deployer's first domain transactions.

The setup tool (`offchain/src/setup.ts`, run via `npm run setup`) performs, in order:

1. deploy `DomainHub` on the L1 and `registerDomain(...)` with the validator set + quorum, the
   fee recipient, the viewing public key (published for senders) and the
   checkpoint interval;
2. deploy `L1Bridge(hub, chainId)` (admin becomes owner);
3. precompute the domain `DomainSpoke` = `CREATE(seed, 0)`, the default token policy
   `DomainAccessRules` = `CREATE(seed, 1)` and `DomainBridge` = `CREATE(seed, 2)` (or
   `CREATE(seed, 1)` when `INITIAL_TOKEN_POLICY` supplies the policy);
4. sign the domain creation transactions (gasless) and `sequenceToDomain` them through the hub;
   the spoke constructor binds `(domainChainId, l1ChainId, hub)`, names the domain admin and
   sets the domain's starting access lists;
5. `L1Bridge.registerDomainBridge(domainBridge)` (one-shot) against the precomputed address;
6. optionally `setTokenAllowed(token)` — e.g. the wrapped-MON ERC20 used for deposits.

The spoke holds three access lists for the whole domain, `Deploy`, `SendTx` and `ReadData`, for
deploying contracts, sending transactions and reading private data. Each is `Closed`, `Allowlist`
or `Open`. Setup opens `Deploy` and `SendTx`, closes `ReadData`, and makes `DOMAIN_ADMIN` (by
default the admin) the domain admin, who changes the lists with domain transactions to the spoke:
`setAccessListMode(list, mode)` and `setAccessListMembers(list, accounts, allowed)`. The admin
hands the role on with `transferAdmin` and `acceptAdmin`. `PROTOCOL.md` has the rules.

Domain transactions are HPKE-encrypted to the domain's viewing key before they are
sequenced: the execution client is started with the viewing secret key
(`--private-domain <chain id> <spoke address> <key.pem>`) and decrypts every payload, so the L1 only carries
ciphertext. Create the key and print the matching `VIEWING_KEY` with
`npm run viewing-key -- generate <key.pem>` (or `-- public <key.pem>` for an existing PEM), and set
`VIEWING_KEY` in `.env`; the setup tool then encrypts the seeded creation transactions
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
