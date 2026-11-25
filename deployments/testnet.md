# Testnet deployment

The bank demo on Monad testnet (chain id `10143`), on two private domains served beside the
`swe-013` node. Protocol contracts from the `domains-testnet` branch of this repository
(`6224cbc`); domain clients and RPCs from the `domains-testnet` branches of `monad`
(`f5b6ce4f8`) and `monad-bft` (`31cb8949f`).

`deployments/testnet.json` is the machine-readable version, read by the operator service
(`demo/operator`) and baked into the page (`demo/frontend`) at build time.

## Protocol

| | |
|---|---|
| DomainHub | `0xbd9690c9218cc05b82f0dfd44268dd594cc98fd4` (implementation `0x2b8e2c537b5bca484ea1ef2631b4da9a960c9a51`) |
| Owner, validator (quorum 1 of 1), fee recipient | `0xF918BF9eCd48a40e7b088a4b718966092B3b4253` |
| DomainSpoke, on every domain | `0x000000000000000000446f6d61696E53706f6B65` (in the domain's genesis) |
| Checkpoint interval | 5 L1 blocks, at most 50 unattested periods |

| | Domain A (Bank A, EUR) | Domain B (Bank B, USD) |
|---|---|---|
| Chain id | `403359` = `(6 << 16) \| 10143` | `468895` = `(7 << 16) \| 10143` |
| Registered from L1 block | 82735747 | 82735799 |
| Viewing key | `0xb974b77877dacb1c5d56fe20137203f324c12c9d3c8024adcbdb0644b75a1554` | `0xd1934b206833f563a5c7501923474b8daf5aedd3416ae0fd3198d140e51cf217` |

Domain `337823` on the same hub (checkpoint interval 200) was a test domain; its services
are stopped.

## Demo contracts

| | |
|---|---|
| EUR ledger (L1) | `0x1b4d490c801d9ce3a0e4a2bbf9f979f93e9b98f5` |
| USD ledger (L1) | `0x40ee71073cc37ff53508d73069f7cf301664f7f2` |
| LockingLiquidityPool (L1), 1 EUR = 1.2 USD | `0x2b7d32ffffccd69fb481b4e9025f1738585b1f4a` |
| DemoL1Bridge A / B (L1) | `0x9f75b52f608819a6cdb3b571121bb23b15ab8232` / `0x1e9c7e8d2b0ad278385c977c00bf8e05ae82f556` |
| DemoDomainBridge, on both domains | `0x14F6f020c56C8E033852C0F1CC1E6F159a21BbFd` |
| L2Bank, on both domains | `0x625B4622c51c39e1F54D4f55A77BCc87326F7586` |
| Bank operator | `0xF918BF9eCd48a40e7b088a4b718966092B3b4253` |

## The node

Each domain is two user-level systemd services of the `monad` user on `swe-013`, next to the
node's own services, which they do not change:

| Service | What it runs | Listens on |
|---|---|---|
| `monad-domain@403359`, `monad-domain@468895` | `monad-domain`, reading the node's L1 db read-only | - |
| `monad-domain-rpc@403359` | `monad-rpc --domain-chain-id` | `127.0.0.1:8182` |
| `monad-domain-rpc@468895` | `monad-rpc --domain-chain-id` | `127.0.0.1:8183` |

Binaries and libraries are in `~/domains-testnet`, settings in
`~/domains-testnet/config/<id>.env`, dbs in `~/domains-testnet/db`, unit files in
`~/.config/systemd/user`, viewing keys in `~/monad-bft/config/domain-keys/domain-<id>.pem`.
`systemctl --user status 'monad-domain@*' 'monad-domain-rpc@*'` shows them.

## Reaching the domain RPCs from outside

The domain RPCs listen on localhost. For the operator on Railway, nginx on the node has to
send each domain's path to its port. In `/etc/nginx/sites-available/monad-rpc-000.conf`
(root; the site is Ansible-managed, so the template has to carry it), beside the existing
maps:

```nginx
map $rpc_path $rpc_upstream {
  default          http://devnet-rpc;
  /domain/403359   http://127.0.0.1:8182;
  /domain/468895   http://127.0.0.1:8183;
}
map $rpc_path $rpc_upstream_path {
  default          $rpc_path;
  /domain/403359   /;
  /domain/468895   /;
}
```

and in the `location ~ ^/rpc/(?<api_key>[^/]+)(?<rpc_path>/.*)?$` block, `set $rpc_target
$rpc_upstream_path;` in place of `set $rpc_target $rpc_path;`, and `proxy_pass $rpc_upstream;`
in place of `proxy_pass http://devnet-rpc;`. Every other path keeps going to the L1 RPC.

Check, with the node's token: a request without an access token answers error `-32006`.

```sh
curl -s -X POST https://swe-013.devcore4.com/rpc/<token>/domain/403359 \
  -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}'
```

The operator then takes `L1_RPC_URL=https://swe-013.devcore4.com/rpc/<token>`,
`DOMAIN_A_RPC_URL=https://swe-013.devcore4.com/rpc/<token>/domain/403359` and
`DOMAIN_B_RPC_URL=https://swe-013.devcore4.com/rpc/<token>/domain/468895`.
