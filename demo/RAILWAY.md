# Deploying the demo to Railway

Two services from this repository, both built from the repository root with their own
Dockerfile under `demo/`. The **operator** is the only component that talks to the node (and the only
place the node URL and the operator keys live); the **frontend** talks to the operator.

```
browser ── https ──> frontend (server.mjs: static page + /rpc, /rpc/domain/<id>, /api proxies)
                         │  private network
                         ▼
                     operator (relayer for both domains, Bank A back office, faucet,
                               /api, RPC gateway)
                         │  https, with the node's access token
                         ▼
                     node RPC  https://<node>/rpc/<token>  and  .../rpc/<token>/domain/<id>
```

## 0. Prerequisites

- The node publishes its L1 route **and** the domain routes behind the same token
  (`deployments/testnet.md` describes the nginx change; check with
  `curl -X POST https://<node>/rpc/<token>/domain/75679 -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}'`
  -> `0x1279f`).
- The demo contracts are deployed and recorded in `deployments/testnet.json` (done for
  Monad testnet).
- The operator key holds MON on the L1 (it pays for attestations, relays, locks and
  faucet drips; the testnet admin account had about 990 MON).
- The `relayer` branch is pushed to a repository Railway can read.

## 1. Create one project with two services

In Railway: **New Project -> Deploy from GitHub repo**, pick this repository and the
`relayer` branch. Railway creates the project with one service in it. Then, **inside the
same project**, add the second service from the same repo (**+ New -> GitHub Repo**, same
repository and branch). Both services must live in one project (and one environment):
the frontend reaches the operator over Railway's private network
(`operator.railway.internal`), which does not cross projects. If you ever split them, give
the operator a public domain and set the frontend's `OPERATOR_URL` to that `https://` URL.

## 2. Operator service

Settings:

| Setting | Value |
|---|---|
| Name | `operator` |
| Root directory | `/` (the build needs `deployments/`) |
| Build | Dockerfile, path `demo/Dockerfile.operator` (set **Variables -> `RAILWAY_DOCKERFILE_PATH=demo/Dockerfile.operator`** if the UI does not offer a Dockerfile path field) |
| Watch paths (optional) | `offchain/**`, `demo/operator/**`, `deployments/**`, `demo/Dockerfile.operator` |
| Networking | nothing public is required; the frontend reaches it over the private network. Add a public domain only if you want `/api/status` reachable from outside. |
| Health check (optional) | `/api/health` |

Variables (required):

```
L1_RPC_URL=https://swe-013.devcore4.com/rpc/<token>
DEPLOYMENT=testnet
OPERATOR_KEY=0x<spoke operator / validator / bank operator / faucet key>
```

Optional, with their defaults:

```
VALIDATOR_KEYS=            # comma-separated; default OPERATOR_KEY
SUBMITTER_KEY=             # pays submitStateSignature / relayDomainMessage; default OPERATOR_KEY
BANK_KEY=                  # BANK on both L2Banks and pool locker; default OPERATOR_KEY
FAUCET_KEY=                # funds drips and mints demo EUR; default OPERATOR_KEY
FAUCET_DRIP_WEI=500000000000000000           # 0.5 MON per onboarding
FAUCET_DRIP_BELOW_WEI=300000000000000000
FAUCET_MINT_EUR_WEI=1000000000000000000000   # 1000 demo EUR
FAUCET_RECEIVE_LIMIT_WEI=100000000000000000000000
FAUCET_COOLDOWN_MS=600000                    # per address
FAUCET_PER_IP_LIMIT=10                       # per cooldown window
ATTEST_INTERVAL_MS=60000                     # idle attestations
POLL_INTERVAL_MS=500                         # delay between operator passes
FINALITY_WAIT_MS=5000                        # in-pass wait for finality before attesting
LOCK_TTL_SECONDS=600
```

`PORT` is injected by Railway; the service listens on it. Deploy, then open the service
logs: within a minute you should see `relayer: hub ... on L1 10143`, the two `relayer:
domain ...` lines, `bank agent: operating ...`, and the first `hub advanced to domain block`.
The first start indexes from each domain's registration block (hundreds of 1000-block log
windows), which takes about a minute on testnet; `GET /api/status` reports
`scannedThrough` per domain and `lastError: null` once it is caught up.

## 3. Frontend service

| Setting | Value |
|---|---|
| Name | `frontend` |
| Root directory | `/` |
| Build | Dockerfile, path `demo/Dockerfile.frontend` (`RAILWAY_DOCKERFILE_PATH=demo/Dockerfile.frontend`) |
| Watch paths (optional) | `demo/frontend/**`, `deployments/**`, `demo/Dockerfile.frontend` |
| Networking | **Generate Domain** (this is the shareable URL) |

Variables:

```
OPERATOR_URL=http://operator.railway.internal:<operator PORT>   # or the operator's public https URL
DEMO_PASSWORD=<the password visitors must enter>
DEMO_USER=demo                                                   # optional, the user name of the prompt
```

`DEMO_PASSWORD` puts the whole page (assets, `/rpc`, `/api`) behind HTTP Basic auth: the
browser asks once for user and password and keeps sending them. Share the URL together with
the password. `/healthz` stays open for Railway's health check. Leave `DEMO_PASSWORD` unset
for a public demo. Note that the password protects the page only: if the operator has a
public domain, its `/api` and `/rpc` remain reachable there.

Finding that URL: the operator's hostname is under its **Settings -> Networking ->
Private Networking** (`<service-name>.railway.internal`, where the name is the one you
gave the service - the default is the repository name). Railway shows no port for private
networking because it does not proxy that traffic: use the port the operator listens on,
8787 when `PORT` is set to that or left unset. The safest form is a reference variable,
which Railway autocompletes and keeps valid if you rename the service:

```
OPERATOR_URL=http://${{<service-name>.RAILWAY_PRIVATE_DOMAIN}}:8787
```

Both services must be in the same project and environment (private networking does not
cross them). The operator listens dual-stack, so it is reachable over IPv4 or IPv6
inside the private network. If you gave the operator a public domain (Generate Domain,
port 8787) you can use that `https://...` URL instead. Nothing else is needed: the page proxies `/rpc`,
`/rpc/domain/<id>` and `/api` to the operator, so the node URL never reaches the browser.

## 4. Verify

```sh
# page up and proxies working (-u sends the Basic credentials; drop it for an open demo)
curl -s -u demo:<password> https://<frontend-domain>/api/health                       # {"ok":true}
curl -s -u demo:<password> https://<frontend-domain>/api/status | jq '.relayer[] | {chainId, scannedThrough, lastError}'
curl -s -u demo:<password> -X POST https://<frontend-domain>/rpc/domain/75679 \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}'   # 0x1279f

# the real flow, from any machine with the repo checked out (DEMO_AUTH answers the Basic auth)
cd demo/frontend && npm install
DEMO_AUTH=demo:<password> OPERATOR_URL=https://<frontend-domain> npm run e2e                 # settlement path, ~20 s
EXPIRE_LOCK=1 DEMO_AUTH=demo:<password> OPERATOR_URL=https://<frontend-domain> npm run e2e   # refund path
DEMO_AUTH=demo:<password> DEMO_URL=https://<frontend-domain> npm run e2e:browser             # drives the page in Chromium
```

Then open the page: **Get test funds**, **Deposit**, **Send $**.

## 5. Operating notes

- **Redeploys**: pushing to `relayer` rebuilds whichever service's watch paths changed.
  The operator is stateless: on restart it re-indexes and recognises every batch already
  on the hub, and resumes a payment order from the pool's per-order lock, so a redeploy in
  the middle of a visitor's flow only delays it.
- **New demo deployment** (fresh contracts): run `npm run deploy` from `demo/operator`
  with `forge build` artifacts, commit the updated `deployments/testnet.json`, push. Both
  services pick the file up at build time (the frontend bakes the addresses into the bundle).
- **Funds**: the faucet drips from `FAUCET_KEY`; watch its MON balance. Visitors' browser
  keys keep their test funds; nothing is reclaimed.
- **Abuse**: the faucet limits are per address and per client IP, in memory; the RPC
  gateway relays any JSON-RPC call to the node, as the old vite proxy did. Put the frontend
  behind Railway's rate limiting or an edge proxy if the link is widely shared.
- **Alternative node access**: if the domain routes are ever not public again, the
  operator can open its own ssh port-forward to the node (`RPC_SSH_*` variables, see
  `demo/operator/.env.example`), with a key the node restricts to that forward.
