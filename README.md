# Monad Domains

## Setting up a domain

Brings up a fully L1-sequenced domain end-to-end. The execution client puts the `DomainSpoke`
in the domain's genesis state, at the same address on every domain
(`0x000000000000000000446f6d61696E53706f6B65`). Every other domain transaction flows through
`DomainHub.sequenceToDomain`, so the token policy and the bridge are created by *sequencing*
their deployment transactions as the seed deployer's first two domain transactions.

The setup tool (`offchain/src/setup.ts`, run via `npm run setup`) performs, in order:

1. deploy `DomainHub` on the L1 and `registerDomain(...)` with the validator set + quorum, the
   fee recipient, the viewing public key (published for senders) and the
   checkpoint interval;
2. deploy `L1Bridge(hub, chainId)` (admin becomes owner);
3. precompute the default token policy `DomainAccessRules` = `CREATE(seed, 0)` and the
   `DomainBridge` = `CREATE(seed, 1)`;
4. sign the two domain creation transactions (gasless) and `sequenceToDomain` them through the hub;
   the genesis spoke is bound to `(domainChainId, l1ChainId, hub)` by the client;
5. `L1Bridge.registerDomainBridge(domainBridge)` (one-shot) against the precomputed address;
6. optionally `setTokenAllowed(token)` — e.g. the wrapped-MON ERC20 used for deposits.

Domain transactions are HPKE-encrypted to the domain's viewing key before they are
sequenced: the execution client is started with the viewing secret key
(`monad-domain --domain <chain id> <key.pem>`) and decrypts every payload, so the L1 only carries
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

## Static analysis

CI runs [Slither](https://github.com/crytic/slither) on every push and pull request and fails on
any finding. To run the same checks locally, install the version pinned in
`.github/workflows/ci.yml` and run the script from anywhere in the repository:

```sh
pip install slither-analyzer==0.11.6   # or: uv tool install slither-analyzer==0.11.6
./script/slither.sh
```

The script runs three checks:

- `slither .`, the detectors over `src/`. `slither.config.json` holds the setup: dependencies,
  tests and scripts are not analyzed, and every detector runs except four that only restate
  deliberate choices in this codebase (`naming-convention`, `assembly`, `low-level-calls`,
  `cyclomatic-complexity`).
- `slither-check-upgradeability`, the initializer and storage layout checks on `DomainHub` and the
  `ERC1967Proxy` it is deployed behind.
- `slither-check-erc`, ERC-20 conformance of `BridgedERC20`.

A detector finding is either fixed or, when it is a false positive, suppressed where it is
reported, with the reason on the line above:

```solidity
// Rounding down to a multiple of the interval is the point.
// slither-disable-next-line divide-before-multiply
```
