# Testnet deployment

Domain messaging on Monad testnet (chain id `10143`), served by the `swe-013` node, with the
bank-settlement demo layered on top. Protocol contracts from monad-domains `main` (463d793,
"Add routing logic in hub contract") plus the `relayer` branch's spoke finalize event for
new deployments; demo contracts from `src/demo/`. The node runs the `kai/domains-v0.16.3`
branches of `monad` and `monad-bft` (monad-bft commit `3a53f79`).

The machine-readable version of the current deployment is `deployments/testnet.json`, which
the operator service (`demo/operator`, `npm run operator`) and the frontend (`demo/frontend`)
both read.

> This deployment runs the hub and spokes from before the checkpoint-attestation redesign
> (operator role, `finalizeDomainMessages`). The contracts and services in this branch expect
> the redesigned hub (`registerDomain` with fee recipient, viewing key and checkpoint interval;
> scheduled `submitStateSignature`) and a spoke without an operator, so the demo cannot run
> against these addresses until the protocol contracts are redeployed and the domains
> registered anew (new chain ids, so the node's configured spoke addresses line up).
> `deployments/devnet.json` is a reproducible single-node deployment of the current contracts.

## Current domains (deployed 2026-10-21)

| Domain | Id | Derivation | Registered at L1 block | Validators / quorum | Operator |
|---|---|---|---|---|---|
| A | 206751 | `(3 << 16) \| 10143` | 72906962 | admin / 1 | admin |
| B | 272287 | `(4 << 16) \| 10143` | 72907034 | admin / 1 | admin |

Registration transactions: `0x3a4c5d150357b434e6f669a46a9e84dcc9862dc199278cb5db7fb7e5bc532ccc`
(A) and `0x8e205ccb995252347366f2d105ec8692f43983520a9d74fea0f74ac06f860778` (B). Both are on
the same hub, so native routing between them works. The registration blocks are the
`startBlock`s the relayer indexes from.

### Protocol contracts

| Contract | Chain | Address |
|---|---|---|
| DomainHub | L1 | `0x251AEe9C131f3BF6941461e3d51B1412Fdbc5945` |
| L1Bridge (domain 206751, reference pair, unused by the demo) | L1 | `0xdaf71edb345689f153c333105aab40d5e3b502d0` |
| L1Bridge (domain 272287, reference pair, unused by the demo) | L1 | `0x1497ae65d6433f7f8bee1b9a775d291576f50bd3` |
| DomainSpoke | both domains | `0x9696388E3D036308A717A44Bb3f4612DB99d38fF` |
| DomainBridge (reference pair) | both domains | `0x10c19706CFDc71f49717d29048F7E4F60515FEAb` |

The spoke and the reference bridge are the admin's first two creations on each fresh domain
(`CREATE(admin, 0)` and `CREATE(admin, 1)`), which is why they share an address on every
domain the admin seeds. Do not reseed.

### Demo contracts (`npm run deploy` from `demo/operator`, admin domain nonces 2-3 on each domain)

| Contract | Chain | Address |
|---|---|---|
| DemoLedger EUR | L1 | `0xa6b83239e3142898486f239bbf3219254103d774` |
| DemoLedger USD | L1 | `0xb79fed94161feb8901262148ecf7e0f56517bcdc` |
| DemoL1Bridge A (EUR allowed) | L1 | `0xd5add79953004b8f0033ced89f8a319ae49cfbcd` |
| DemoL1Bridge B (USD allowed) | L1 | `0xc55eb79276af1145bc314763bf79e897fd500c2c` |
| LockingLiquidityPool (1 EUR = 1.2 USD, 1,000,000 USD seeded) | L1 | `0x0ce6c36c6263a88fffaeca7ee462ed7d9ab61aab` |
| DemoDomainBridge | both domains | `0x1B21d29c63b5fC10Af9234fbbB9edDd53C088621` |
| L2Bank (Bank A = EUR on A, Bank B = USD on B) | both domains | `0xf2393b3186c8ba39aE5fca192521b60EFE203d41` |

The pool's `locker` and both banks' `BANK` are the admin account. Bank A and Bank B are
registered as each other's peers.

### Viewing keys

Each domain has a P-256 viewing key. The private PEMs exist only on the node:

```
/home/monad/monad-bft/config/domain-keys/domain-206751.pem
/home/monad/monad-bft/config/domain-keys/domain-272287.pem
```

Back them up: a lost viewing key makes that domain's history undecryptable. Senders need the
matching public keys (`viewingKey` in `deployments/testnet.json`):

```
206751: 0x04d31f49ed035afc6c7045c4dd33b6485466fcf6021eb3e01a54a95cbc0b3e5399de67354267cc3cf62b8e933b932af6dfc19ce8e6be68d707c59873e6fb184a50
272287: 0x0440091734ad40625313e6b2cf683093e003c9563829cca399ec955cb7a0bd5e0eb283c71550a7583d6b6bf8c28cb7e40e842b3a1ac66e6b4fb9c396d0240ad785
```

To re-derive a public key from a PEM on the node:

```sh
openssl ec -in domain-206751.pem -pubout -conv_form uncompressed -outform DER | tail -c 65 | xxd -p -c 65
```

Every node that serves a domain must hold the same PEM; the client supports one receiver key
per domain. A node holding a key drops plaintext payloads, so every sender (the operator
service and the frontend included) encrypts.

## Accounts

Admin (deployer, hub operator of both domains, sole domain validator, spoke operator, bridge
owner, bank operator, pool locker, faucet): `0xe9C890d0f02f9a6Eb179384183C475888935420B`.
This is a test account; its private key is not recorded here. The operator service takes it
as `OPERATOR_KEY` (the other roles default to it and can be split with `VALIDATOR_KEYS`,
`SUBMITTER_KEY`, `BANK_KEY`, `FAUCET_KEY`).

## Node (`swe-013`)

Ubuntu 26.04, OpenSSL 3.5. The execution client needs OpenSSL 3.2 or newer because the
domain decryption uses the `OSSL_HPKE_*` API; it does not run on Ubuntu 24.04 (OpenSSL 3.0).
Services are systemd units `monad-execution`, `monad-bft`, `monad-rpc` with config under
`/home/monad/monad-bft/config`. Domain flags live in drop-ins (`sudo systemctl edit <unit>`):

```
# monad-execution
--private-domain 206751 0x9696388E3D036308A717A44Bb3f4612DB99d38fF /home/monad/monad-bft/config/domain-keys/domain-206751.pem
--private-domain 272287 0x9696388E3D036308A717A44Bb3f4612DB99d38fF /home/monad/monad-bft/config/domain-keys/domain-272287.pem
--private-domain-sequencer 0x251AEe9C131f3BF6941461e3d51B1412Fdbc5945

# monad-rpc
--private-domain-spoke 206751=0x9696388E3D036308A717A44Bb3f4612DB99d38fF
--private-domain-spoke 272287=0x9696388E3D036308A717A44Bb3f4612DB99d38fF
```

The consensus node needs no domain flags. The RPC listens on `127.0.0.1:8080` and is
published by nginx as `https://swe-013.devcore4.com/rpc/<token>` for the L1 route and
`https://swe-013.devcore4.com/rpc/<token>/domain/<id>` for the domain routes (a wrong token
gets 401). Public L1 RPC: `https://testnet-rpc.monad.xyz`. `eth_getLogs` is capped at 1000
blocks per query on every route.

### nginx (applied 2026-10-18)

The site (`/etc/nginx/sites-enabled/monad-rpc-000.conf`, Ansible-managed, so keep the change
in the Ansible source too) forwards the optional `/domain/<id>` suffix:

```nginx
    location ~ ^/rpc/(?<api_key>[^/]+)(/domain/[0-9]+)?$ {
        if ($api_key_valid = 0) {
          return 401;
        }
        # ... same CORS / OPTIONS block ...
        rewrite ^/rpc/[^/]+(/domain/[0-9]+)$ $1 break;   # /rpc/<token>/domain/206751 -> /domain/206751
        rewrite ^/rpc/[^/]+$ / break;                    # /rpc/<token>              -> /
        proxy_pass http://devnet-rpc;
        # ... same proxy settings ...
    }
```

For a node without that, the operator can open its own ssh port-forward to the node's
localhost RPC instead (`RPC_SSH_*` variables, see `demo/operator/.env.example`).

## How the current deployment was made (2026-10-21)

1. Generated the two viewing keys on the node (`openssl genpkey`, mode 0600) and derived the
   public points.
2. Replaced the `--private-domain` / `--private-domain-spoke` drop-in lines with the new ids
   and restarted `monad-execution` and `monad-rpc` (root). Nothing may be sequenced to a new
   id before this point: the client only derives domain blocks for L1 blocks it executes with
   the flags set, and a missed spoke creation cannot be replayed.
3. From `offchain/`, ran `npm run setup` once per domain, sequentially, with
   `EXISTING_HUB_ADDRESS=<hub>`, `DOMAIN_CHAIN_ID`, `VALIDATORS=<admin>`, `QUORUM=1`, that
   domain's `VIEWING_KEY` and `L1_RPC_URL=https://swe-013.devcore4.com/rpc/<token>`. Each run
   registers the domain, deploys its reference L1Bridge, sequences the encrypted spoke and
   bridge creations, and calls `registerDomainBridge`.
4. Wrote the protocol part of `deployments/testnet.json` (hub, spokes, viewing keys,
   registration blocks) and ran `npm run deploy` from `demo/operator`, which appended the demo
   addresses above.
5. Verified with both Docker images against the public node URL: onboarding, deposit, KYC
   round trip, lock, payment, atomic settlement and delivery; the expired-lock refund path;
   and the real page in headless Chromium behind the password.

## Retired domains (75679 and 141215, 2026-10-16 to 2026-10-21)

The first two domains, `(1 << 16) | 10143 = 75679` and `(2 << 16) | 10143 = 141215`
(registered at L1 blocks 71580830 and 71580952), are no longer served by the node: their
`--private-domain` lines were replaced on 2026-10-21 and their viewing-key PEMs
(`domain-75679.pem`, `domain-141215.pem`) remain on the node only as a record. Their demo
layer (EUR `0x379d801c10906e6f90bf263612d8a788147f931e`, USD
`0x07978e0c4b08486126f7ef3c0d431a21280fbb76`, pool `0xbb16e62aaf40c4c56743f43898d71612728ba19f`,
DemoL1Bridge A `0xe80e455a90740ea9065bc7ac7125a8c06bb3d5bc`, B
`0x310b0b978c58fde11f034374c7dfb26c32933ce0`; reference L1Bridges
`0x46c61f5adcc934fb99705154eb187ef514b23700` and `0x0a1b122912c0fd3fb087d7dfed3d47b2d58e57a5`)
still exists on the L1 but is unused. Hub deploy transaction:
`0x2227d57d3fbb420f454cd98305dbd3cd58a49e349c265212587b70849042b9e1`.

## Known limits

- `registerDomain` is permissionless, so anyone can register further ids on this hub.
- The faucet's rate limits are in memory (per address and per IP) and reset on restart.
- A withdrawal whose settlement hook reverts (for example a lock cancelled before the payment
  arrived) stays retryable at the hub but can never succeed; the custodied EUR then sits in the
  domain-A bridge escrow. The bank agent never cancels locks itself.
