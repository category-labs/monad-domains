# Private settlement domains - the public demo

A bank-mediated payment between two domains through L1 liquidity, deployed on Monad
testnet (`deployments/testnet.md`): a visitor banks in € with Bank A on domain A and pays $
to someone banking with Bank B on domain B. Bank A KYC-inquires with Bank B through the
hub's native routing, reserves liquidity at the L1 pool, charges the quoted € and withdraws
it to the pool; the L1 transaction that delivers the withdrawal settles the lock and
bridges the $ to the recipient atomically (or refunds the € once the lock timed out).

Layout:

- `operator/` - the operator service (`npm run operator`) and the demo contract deploy script
  (`npm run deploy`); depends on `../../offchain` for the relayer and sequencing;
- `frontend/` - the page and its small proxy server;
- `Dockerfile.operator`, `Dockerfile.frontend`, `RAILWAY.md` - the two Railway services;
- `../src/demo`, `../test/demo` - the demo contracts (Foundry keeps them under `src`);
- `../deployments/` - the addresses both services read.

Two services, deployed separately:

- **operator** (`demo/operator`, `npm run operator`, `demo/Dockerfile.operator`): the relayer for
  both domains, Bank A's back office (pool locks + payment execution), the onboarding
  faucet (gas drip, demo € mint, registry entries at both banks) and the small HTTP API the
  page uses. Holds the operator keys; never shipped to a browser.
- **frontend** (`demo/frontend`, `npm run start`, `demo/Dockerfile.frontend`): the page plus a tiny
  server that proxies `/rpc`, `/rpc/domain/<id>` and `/api` so the browser only talks to its
  own origin and the node's RPC URL (with its token) stays server-side. Visitors use a key
  generated in their browser (funded by the faucet) or connect a wallet for the L1 side;
  a browser-held session key signs the domain transactions, which are HPKE-encrypted to
  the domain's viewing key and carried to the hub inside the visitor's own L1 transaction.

Demo contracts live in `src/demo/` (`DemoLedger`, `DemoL1Bridge` with a settlement hook,
`DemoDomainBridge` with memo withdrawals, `L2Bank`, `LockingLiquidityPool`), tested in
`test/demo/BankSettlement.t.sol`, deployed with `npm run deploy` (from `demo/operator`) into
`deployments/<name>.json`.

## Operator service

`npm run operator` (`demo/operator`, `src/operator.ts`) wraps the relayer for the two demo domains together
with Bank A's back office (`src/bank-agent.ts`: reserve pool liquidity for approved payment
orders and execute the payment), the onboarding faucet and the HTTP API the frontend uses
(`GET /api/config`, `GET /api/status`, `POST /api/onboard {address, domainAddress}`). It reads
`deployments/<DEPLOYMENT>.json`, which `npm run deploy` (`src/deploy-cli.ts`)
writes after layering the demo contracts on two registered domains. Domain transactions
from the operator keys are sequenced one after the other by a single loop; concurrent L1
sends from one key are ordered by viem's nonce manager. See `operator/.env.example` for every
variable and `Dockerfile.operator` for the Railway image.

## Railway

Step-by-step runbook: [`RAILWAY.md`](./RAILWAY.md). In short, both services build from the repository root (they need `deployments/`); the images were
built and smoke-tested locally (`Dockerfile.operator`, `Dockerfile.frontend`). The page
reaches the node only through the operator's RPC gateway (`/rpc`, `/rpc/domain/<id>`), so
the **operator is the one service that must reach the node's L1 *and* domain routes**, and
the node's URL or key never leaves it. Create two services from this repo:

| Service | Setting | Value |
|---|---|---|
| operator | Root directory / Dockerfile path | `/`, `demo/Dockerfile.operator` (`RAILWAY_DOCKERFILE_PATH`) |
| | Variables | `DEPLOYMENT=testnet`, `OPERATOR_KEY=0x...`, node access (one of the two options below), optional `VALIDATOR_KEYS`, `SUBMITTER_KEY`, `BANK_KEY`, `FAUCET_KEY`, faucet limits (`demo/operator/.env.example`); `PORT` is set by Railway |
| | Networking | private (the frontend reaches it over `http://<service>.railway.internal:<port>`) or public |
| frontend | Root directory / Dockerfile path | `/`, `demo/Dockerfile.frontend` |
| | Variables | `OPERATOR_URL=http://<operator>.railway.internal:<port>` (or its public URL); `PORT` is set by Railway |
| | Networking | public domain |

Node access for the operator, pick one:

1. **Published domain routes** - `L1_RPC_URL=https://<node>/rpc/<token>`; the domain routes
   default to `${L1_RPC_URL}/domain/<id>`. On `swe-013` the nginx site only matches
   `/rpc/<token>` today, so this needs the one-location nginx change in
   `deployments/testnet.md` (root on the node).
2. **ssh port-forward from the operator** - no nginx change: `RPC_SSH_HOST=swe-013.devcore4.com`,
   `RPC_SSH_PORT=9022`, `RPC_SSH_USER=monad`, `RPC_SSH_KEY=<private key>` and ideally
   `RPC_SSH_KNOWN_HOSTS=<host key line>`. The service opens `ssh -N -L` to the node's
   localhost RPC (which serves every route) and reconnects if it drops. Install the matching
   public key on the node restricted to that forward:
   `restrict,port-forwarding,permitopen="127.0.0.1:8080",command="/bin/false" ssh-ed25519 ...`
   in `~monad/.ssh/authorized_keys`. Only someone with access to the node should add it.

Operator keys hold real (test) funds and run the faucet; keep them in Railway variables,
never in the repo. The faucet rate-limits per address and per IP in memory. To restrict the
demo to people you share a password with, set `DEMO_PASSWORD` on the frontend (HTTP Basic
auth on the page, its assets and its proxies).
