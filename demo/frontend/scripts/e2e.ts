// Headless end-to-end run of exactly what the page does, with a fresh browser-style key:
// onboard through the operator's faucet, deposit € into Bank A, pay $ to a recipient at
// Bank B (KYC round trip, L1 lock, atomic settlement, protocol delivery) and assert the
// balances. EXPIRE_LOCK=1 exercises the timeout/refund path instead.
//
//   RPC_URL=<node rpc> OPERATOR_URL=<operator api> [SESSION_KEY=0x..] [AMOUNT=60] npm run e2e
import { formatEther, parseEther, type Address } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { browserIdentity } from "../src/lib/account";
import { quoteEurIn } from "../src/lib/deployment";
import { depositToA, fetchBalances, filePaymentOrder, onboard, type Step } from "../src/lib/flows";
import { trackPayment } from "../src/lib/watch";

const EXPIRE_LOCK = process.env.EXPIRE_LOCK === "1";
const AMOUNT_OUT = parseEther(process.env.AMOUNT ?? "60");
const started = Date.now();

function report(step: Step) {
  const t = ((Date.now() - started) / 1000).toFixed(1).padStart(6);
  const mark = step.status === "done" ? "✓" : "…";
  console.log(`  ${t}s ${mark} [${step.zone}] ${step.actor}: ${step.title}${step.txHash ? ` (${step.txHash.slice(0, 14)}…)` : ""}${step.atomic && step.status === "done" ? "  <-- ATOMIC L1 TX" : ""}`);
}

function assertEq(actual: bigint, expected: bigint, label: string) {
  if (actual !== expected) throw new Error(`ASSERTION FAILED: ${label} - expected ${formatEther(expected)}, got ${formatEther(actual)}`);
  console.log(`  ok: ${label} = ${formatEther(actual)}`);
}

async function main() {
  const key = (process.env.SESSION_KEY as `0x${string}` | undefined) ?? generatePrivateKey();
  const identity = browserIdentity(key);
  const recipient: Address = (process.env.RECIPIENT as Address | undefined) ?? privateKeyToAccount(key).address;
  const cost = quoteEurIn(AMOUNT_OUT);
  console.log(`account ${identity.l1.address}, recipient ${recipient}, $${formatEther(AMOUNT_OUT)} costs ${formatEther(cost)} €, mode ${EXPIRE_LOCK ? "EXPIRED LOCK (refund)" : "live lock"}`);

  console.log("\n== Onboarding ==");
  await onboard(identity, report);
  let b = await fetchBalances(identity.l1.address, identity.domain.address, recipient);
  if (b.mon === 0n) throw new Error("no gas after onboarding");
  if (b.eurL1 < cost) throw new Error("not enough € minted");
  if (recipient.toLowerCase() === identity.domain.address.toLowerCase() && b.recipientLimitB < AMOUNT_OUT) throw new Error("registry entry missing");
  const before = b;

  console.log("\n== Deposit € into Bank A ==");
  await depositToA(identity, cost, report);
  b = await fetchBalances(identity.l1.address, identity.domain.address, recipient);
  assertEq(b.userEurOnA, before.userEurOnA + cost, "€ at Bank A after deposit");
  assertEq(b.eurL1, before.eurL1 - cost, "€ on the L1 after deposit");

  console.log(`\n== Payment of $${formatEther(AMOUNT_OUT)} ==`);
  const afterDeposit = b;
  const order = await filePaymentOrder(identity, recipient, AMOUNT_OUT, EXPIRE_LOCK, report);
  const outcome = await trackPayment(order, report, { timeoutMs: 15 * 60_000 });
  b = await fetchBalances(identity.l1.address, identity.domain.address, recipient);

  if (!outcome.approved) throw new Error("KYC was denied");
  // Only the visitor's own books are asserted exactly: the pool and the bridge escrows are
  // shared with every other visitor running the demo at the same time.
  const delta = (label: string, before: bigint, after: bigint) => console.log(`  info: ${label} ${formatEther(before)} -> ${formatEther(after)}`);
  delta("pool €", afterDeposit.poolEur, b.poolEur);
  delta("pool $", afterDeposit.poolUsd, b.poolUsd);
  delta("domain A € escrow", afterDeposit.lockedEurA, b.lockedEurA);
  delta("domain B $ escrow", afterDeposit.lockedUsdB, b.lockedUsdB);
  if (EXPIRE_LOCK) {
    if (!outcome.refunded) throw new Error("expected the refund path");
    assertEq(b.userEurOnA, afterDeposit.userEurOnA, "€ at Bank A refunded");
    assertEq(b.recipientUsdOnB, afterDeposit.recipientUsdOnB, "no $ delivered");
    assertEq(b.recipientLimitB, afterDeposit.recipientLimitB - AMOUNT_OUT, "KYC limit consumed by the inquiry");
    console.log("\nE2E PASSED - the expired lock refunded the € on domain A; no $ moved.");
  } else {
    if (!outcome.settled) throw new Error("expected the settlement path");
    assertEq(b.userEurOnA, afterDeposit.userEurOnA - cost, "€ at Bank A charged");
    assertEq(b.recipientUsdOnB, afterDeposit.recipientUsdOnB + AMOUNT_OUT, "$ delivered at Bank B");
    assertEq(b.recipientLimitB, afterDeposit.recipientLimitB - AMOUNT_OUT, "KYC limit consumed");
    if (b.poolEur < afterDeposit.poolEur + cost) throw new Error("ASSERTION FAILED: the pool did not absorb the €");
    console.log("\nE2E PASSED - KYC round trip, liquidity lock, € charge, atomic settlement, $ delivered.");
  }
  console.log(`total ${((Date.now() - started) / 1000).toFixed(1)}s`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
