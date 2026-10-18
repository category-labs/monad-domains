# Private settlement domains - public demo

Single-page demo of a bank-mediated payment between two **private settlement domains**
on Monad testnet, settled through L1 liquidity. Any visitor can run it with their own
account:

1. **Get test funds** - the operators' faucet drips MON for gas, mints demo € on the L1 and
   registers the visitor in both banks' know-your-depositor registries;
2. **Deposit** - the visitor locks € on the L1 for their account at Bank A (domain A); the
   domain protocol delivers the deposit as a system transaction;
3. **Send $** - the visitor files a payment order at Bank A. Bank A KYC-inquires with Bank B
   (domain B) through the hub's native domain -> domain routing, takes a **liquidity lock**
   at the L1 pool (1 € = 1.2 $), charges the quoted € and withdraws them to the pool with the
   lock id as memo; the L1 transaction that delivers that withdrawal **settles the lock and
   bridges the $ to the recipient at Bank B atomically**. Tick *let the lock expire* to run
   the timeout path instead: the same settlement refunds the € to the visitor on domain A.

Unlike the earlier demo, nothing privileged happens in the browser:

- **no shared keys in the page** - the visitor either uses a key generated in their browser
  (kept in `localStorage`, exportable) or connects an injected wallet for the L1 side; a
  browser-held *session key* always signs the domain transactions, because a wallet can only
  sign for the chain it is connected to, while a domain transaction is signed for the
  domain's chain id and merely *carried* by an L1 transaction (`hub.sequenceToDomain`),
  encrypted to the domain's viewing key;
- **no relaying in the page** - finalizing batches, attesting state roots, proving messages
  on the hub, Bank A's back office and the faucet all run in the operators' service
  (`demo/operator`, `npm run operator`). The page only submits the visitor's own transactions and
  then *follows* the order by reading the chains (`src/lib/watch.ts`), which is what the
  step ledger shows.

The page talks to its own origin only: `/api` -> the operator service, `/rpc` and
`/rpc/domain/<id>` -> the operator's RPC gateway, which forwards to the node. So the page's
server needs just `OPERATOR_URL`; the node's URL (with its access token, or an ssh
port-forward) lives in the operator. `RPC_URL` / `DOMAIN_RPC_URL` can still point the page's
proxy straight at a node for local work.

## Run it locally

```sh
# contracts deployed (deployments/testnet.json), operator service running (see ../operator)
npm install
OPERATOR_URL=http://127.0.0.1:8787 npm run dev   # http://localhost:5173
```

Production: `npm run build` then `OPERATOR_URL=... PORT=... npm run start` runs
`server.mjs`, a small Node server that serves `dist/` and proxies the same paths. The
`demo/Dockerfile.frontend` packages exactly that for Railway. Set `DEMO_PASSWORD` (and
optionally `DEMO_USER`, default `demo`) to put the page behind HTTP Basic auth.

## Tests

```sh
OPERATOR_URL=... npm run e2e                          # headless: onboard, deposit, pay, assert balances
EXPIRE_LOCK=1 OPERATOR_URL=... npm run e2e            # the timeout / refund path
DEMO_URL=http://localhost:5173 npm run e2e:browser    # drives the real page in headless Chromium
```

Both use a fresh random key each run (`SESSION_KEY=0x...` reuses one). Against a
password-protected page pass `DEMO_AUTH=user:password`.

## Layout

- `src/lib/account.ts` - browser account / injected wallet / session key
- `src/lib/sequencer.ts` - signing a domain transaction and carrying it to the hub (`sequenceToDomain`), encrypted
- `src/lib/encryption.ts` - HPKE sealing to the domain viewing key (browser port of `offchain/src/encryption.ts`)
- `src/lib/flows.ts` - onboarding, deposit, filing the payment order; balance reads
- `src/lib/watch.ts` - follows a payment order through both domains and the L1 by scanning logs
- `src/lib/deployment.ts` - addresses from `deployments/testnet.json` (`VITE_DEPLOYMENT_JSON` overrides at build time)
- `src/App.tsx` - the page; `server.mjs` / `vite.config.ts` - the same-origin proxies
