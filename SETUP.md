# Setting up a domain

How to register a private domain on a deployed `DomainHub` and run it. The hub addresses and
the versions to use are under [Deployments](#deployments).

## Requirements

- **A Monad full node of the network, on the same machine as the domain client.** The client
  reads the node's triedb directly, read-only. See the [node operations documentation](https://docs.monad.xyz/node-ops/).

## 1. Build the client and the RPC

Both are built from source:

- `monad-rpc` and `monad-domain` together: [`scripts/build-binaries`](https://github.com/category-labs/monad-bft/blob/domains-testnet/scripts/build-binaries)
  in `monad-bft`. It builds `target/release/monad-rpc` and, from the pinned `monad-execution`
  submodule, `monad-execution/build/cmd/monad-domain`. The build environment is
  [`docker/builder`](https://github.com/category-labs/monad-bft/blob/domains-testnet/docker/builder/Dockerfile).

`monad-rpc` loads shared libraries from its build tree (`libtriedb_driver.so`,
`libmonad_execution.so` and the libraries those load). To run it elsewhere, copy them along
and name their directory in `LD_LIBRARY_PATH`;
[`scripts/build-deb`](https://github.com/category-labs/monad-bft/blob/domains-testnet/scripts/build-deb)
shows which ones. `monad-domain` needs system libraries only. Build on the OS release the
node runs.

## 2. Choose a chain id and create the encryption key

A domain's chain id is `(n << 16) | <L1 chain id>` for an `n` of your choice, and must not be
registered on the hub yet:

```sh
cast call <hub> 'isDomainRegistered(uint64)(bool)' <domain chain id> --rpc-url <L1 RPC>
```

Every transaction sent to the domain is encrypted to its encryption key. Create it:

```sh
cd offchain && npm install
npm run encryption-key -- generate domain-<id>.pem     # prints ENCRYPTION_PUB_KEY=0x...
```

The PEM is the private key. It belongs with the domain client only; without it the domain's
transactions cannot be read again, so keep a backup.

## 3. Run the domain client and its RPC

```sh
monad-domain \
    --chain <monad_testnet | monad_mainnet> \
    --l1-db <the node's triedb, e.g. /dev/triedb> \
    --domain <domain chain id> <domain-<id>.pem> \
    --hub <hub> \
    --domain-db <path of the domain's db file> \
    --log-level INFO

monad-rpc \
    --domain-chain-id <domain chain id> \
    --operators <address>[,<address>...] \
    --triedb-path <path of the domain's db file> \
    --node-config <the node's node.toml> \
    --rpc-addr 127.0.0.1 --rpc-port <port> \
    --metrics-listen-addr 127.0.0.1:<port>
```

The client can be started before the domain is registered: it waits for the registration and
creates the db then. The RPC can only open the db once it exists.

The RPC serves no request without an access token. The accounts named in `--operators` are
served every method; any other account is served its own data. The validators and the
relayer need an operator's key. Publish the RPC through a reverse proxy that passes the
`X-Authorization-Token` header.

As systemd user services, with one instance per domain (`systemctl --user enable --now
monad-domain@<id> monad-domain-rpc@<id>`) and the settings of a domain in
`~/monad-domains/config/<id>.env` (`CHAIN`, `DOMAIN_HUB`, `DOMAIN_OPERATORS`, `RPC_PORT`,
`METRICS_ADDR`):

```ini
# ~/.config/systemd/user/monad-domain@.service
[Unit]
Description=Monad domain client %i

[Service]
EnvironmentFile=%h/monad-domains/config/%i.env
ExecStart=%h/monad-domains/bin/monad-domain \
    --chain ${CHAIN} \
    --l1-db /dev/triedb \
    --domain %i %h/monad-domains/keys/domain-%i.pem \
    --hub ${DOMAIN_HUB} \
    --domain-db %h/monad-domains/db/%i.db \
    --log-level INFO
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=default.target
```

```ini
# ~/.config/systemd/user/monad-domain-rpc@.service
[Unit]
Description=Monad domain RPC %i
After=monad-domain@%i.service

[Service]
EnvironmentFile=%h/monad-domains/config/%i.env
Environment=LD_LIBRARY_PATH=%h/monad-domains/lib
ExecStartPre=/bin/sh -c "until [ -e %h/monad-domains/db/%i.db ]; do sleep 1; done"
ExecStart=%h/monad-domains/bin/monad-rpc \
    --domain-chain-id %i \
    --operators ${DOMAIN_OPERATORS} \
    --triedb-path %h/monad-domains/db/%i.db \
    --node-config %h/monad-bft/config/node.toml \
    --rpc-addr 127.0.0.1 \
    --rpc-port ${RPC_PORT} \
    --metrics-listen-addr ${METRICS_ADDR}
TimeoutStartSec=infinity
Restart=always
RestartSec=1
LimitNOFILE=1048576

[Install]
WantedBy=default.target
```

If the node's services are pinned to CPUs, give the domain services other ones
(`CPUAffinity=`).

## 4. Register the domain

Build the contracts, fill in `offchain/.env` (every variable is described in
`offchain/.env.example`) and run the setup:

```sh
forge build
cd offchain
cp .env.example .env
set -a && source .env && set +a
npm run setup
```

| Variable | Value |
|---|---|
| `L1_RPC_URL` | The RPC of your own node: the tools read logs over ranges of 1000 blocks |
| `ADMIN_KEY` | Pays for the registration; owns the domain's `L1Bridge` |
| `EXISTING_HUB_ADDRESS` | The hub of the deployment. Without it the tool deploys a hub of its own |
| `DOMAIN_CHAIN_ID` | From step 3 |
| `ENCRYPTION_PUB_KEY` | From step 3 |
| `VALIDATORS`, `QUORUM` | The validators' addresses, and how many of them have to sign a checkpoint: a majority |
| `CHECKPOINT_INTERVAL` | L1 blocks between checkpoints, see below. It cannot be changed afterwards |
| `MAX_UNATTESTED_PERIODS` | Checkpoint periods the oldest unattested input may be behind before the hub refuses new ones, at most 50 |

The tool registers the domain, deploys its `L1Bridge`, and sequences the domain's first two
transactions, which create its token policy and its `DomainBridge`. Keep the addresses it
prints.

**Choosing the checkpoint interval.** A message from the domain to the L1, such as a
withdrawal, can be relayed once a checkpoint covers it, so the interval bounds how long that
takes. Every validator sends one L1 transaction of roughly 200,000 gas per checkpoint.

## 5. Run the validators and a relayer

Each validator runs its own process with its own key; the hub advances when `QUORUM` of them
signed the same checkpoint.

```sh
cd offchain
L1_RPC_URL=... HUB_ADDRESS=<hub> DOMAIN_CHAIN_ID=<id> \
DOMAIN_RPC_URL=<the domain RPC> DOMAIN_RPC_KEY=<an operator's key> \
VALIDATOR_KEYS=<the validator's key> SUBMITTER_KEY=<a funded L1 key> \
POLL_INTERVAL_MS=1000 npm run checkpoint
```

```sh
L1_RPC_URL=... HUB_ADDRESS=<hub> DOMAIN_CHAIN_ID=<id> \
DOMAIN_RPC_URL=<the domain RPC> DOMAIN_RPC_KEY=<an operator's key> \
RELAYER_KEY=<a funded L1 key> SCAN_FROM_BLOCK=<an L1 block before the registration> \
POLL_INTERVAL_MS=1000 npm run relay
```

Give every process an L1 account of its own. A validator attests every scheduled checkpoint
in order, and one that was down attests each checkpoint it missed before the current one.
Start the validators right after registering. The setup's two transactions are the domain's
first inputs, and the hub refuses further ones once the oldest unattested input is
`MAX_UNATTESTED_PERIODS` periods old.

## 6. Check

```sh
TOKEN=$(DOMAIN_CHAIN_ID=<id> ACCOUNT_KEY=<an operator's key> npm run --silent access-token)
curl -s <the domain RPC> -H 'content-type: application/json' -H "X-Authorization-Token: $TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}'
cast call <hub> 'domainBlockNumbers(uint64)(uint64)' <id> --rpc-url <L1 RPC>
```

The domain is at block 2 after the setup: block 0 is its registration, and each later L1
block with an input for the domain is one more. The second command prints the L1 height of
the latest checkpoint, which follows the L1 head at the interval's distance once the
validators run.

## Deployments

### Monad testnet

| | |
|---|---|
| L1 chain id | `10143` (`--chain monad_testnet`) |
| DomainHub | `0xbd9690c9218cc05b82f0dfd44268dd594cc98fd4` |
| Hub owner, who may upgrade it | `0xF918BF9eCd48a40e7b088a4b718966092B3b4253` |
| DomainSpoke, on every domain | `0x000000000000000000446f6d61696E53706f6B65` |
| Contracts and tools | [`monad-domains`, branch `domains-testnet`](https://github.com/category-labs/monad-domains/tree/domains-testnet) (`6224cbc`) |
| Domain client | [`monad`, branch `domains-testnet`](https://github.com/category-labs/monad/tree/domains-testnet) (`f5b6ce4f8`) |
| Domain RPC | [`monad-bft`, branch `domains-testnet`](https://github.com/category-labs/monad-bft/tree/domains-testnet) (`31cb8949f`) |

### Monad mainnet

Not deployed.
