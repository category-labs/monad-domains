// Drives the real page in headless Chromium with a fresh browser account: get test funds,
// deposit, pay, and check the rendered ledger reaches the final step and the balances move.
//
//   (operator service + `npm run dev` or `npm run start` up)  DEMO_URL=http://localhost:5173 npm run e2e:browser
import { mkdirSync } from "node:fs";
import { chromium } from "playwright";

const URL = process.env.DEMO_URL ?? "http://localhost:5173";
const STEP_TIMEOUT = 15 * 60_000;

async function main() {
  mkdirSync("screenshots", { recursive: true });
  const browser = await chromium.launch();
  // DEMO_AUTH=user:password answers the page's Basic auth prompt when it is password protected.
  const [username, ...rest] = (process.env.DEMO_AUTH ?? "").split(":");
  const context = await browser.newContext({
    viewport: { width: 1360, height: 1100 },
    httpCredentials: process.env.DEMO_AUTH ? { username: username ?? "", password: rest.join(":") } : undefined,
  });
  const page = await context.newPage();
  page.on("pageerror", (err) => {
    throw new Error(`page error: ${err.message}`);
  });
  page.on("console", (msg) => {
    if (msg.type() === "error") console.log(`console.error: ${msg.text()}`);
  });

  await page.goto(URL);
  await page.waitForSelector(".node-badge:not(.offline)", { timeout: 20_000 });
  const address = await page.locator(".account-address").first().innerText();
  console.log(`page up, browser account ${address}`);
  await page.screenshot({ path: "screenshots/1-initial.png", fullPage: true });

  const balance = async (station: string, label: string): Promise<number> => {
    const row = page.locator(`.station-${station} .balance-row`, { hasText: label }).first();
    const text = await row.locator(".balance-value").innerText();
    return parseFloat(text.replace(/[€$]/g, "").trim());
  };
  const finished = async (count: number, label: string) => {
    await page.waitForSelector(`.ledger-count >> text=${count}/${count}`, { timeout: STEP_TIMEOUT });
    console.log(`${label} finished (${count}/${count} steps)`);
  };

  await page.getByRole("button", { name: /Get test funds/ }).click();
  await finished(2, "onboarding");
  await page.waitForFunction(() => !document.querySelector(".btn.primary")?.hasAttribute("disabled") || true);
  await page.screenshot({ path: "screenshots/2-onboarded.png", fullPage: true });

  const bankABefore = await balance("A", "You");
  await page.getByRole("button", { name: /Deposit/ }).click();
  await finished(3, "deposit");
  await page.waitForTimeout(3_000);
  const bankAAfterDeposit = await balance("A", "You");
  if (bankAAfterDeposit < bankABefore + 50) throw new Error(`expected >= ${bankABefore + 50} € at Bank A, saw ${bankAAfterDeposit}`);
  await page.screenshot({ path: "screenshots/3-after-deposit.png", fullPage: true });

  const recipientBefore = await balance("B", "Recipient");
  await page.getByRole("button", { name: /Send \$/ }).click();
  await page.waitForSelector(".entry.atomic", { timeout: STEP_TIMEOUT });
  console.log("atomic L1 settlement entry appeared");
  await finished(10, "payment");
  await page.waitForTimeout(3_000);
  await page.screenshot({ path: "screenshots/4-after-payment.png", fullPage: true });

  const recipientAfter = await balance("B", "Recipient");
  const bankAAfterPayment = await balance("A", "You");
  const atomicBadge = await page.locator(".atomic-badge").first().innerText();
  if (recipientAfter !== recipientBefore + 60) throw new Error(`recipient at Bank B: expected ${recipientBefore + 60}, saw ${recipientAfter}`);
  if (bankAAfterPayment !== bankAAfterDeposit - 50) throw new Error(`you at Bank A: expected ${bankAAfterDeposit - 50}, saw ${bankAAfterPayment}`);
  if (!/1 L1 TX/.test(atomicBadge)) throw new Error(`atomic badge missing, saw "${atomicBadge}"`);
  console.log(`recipient at Bank B: ${recipientBefore} -> ${recipientAfter}, you at Bank A: ${bankAAfterDeposit} -> ${bankAAfterPayment}`);
  console.log("BROWSER E2E PASSED");
  await browser.close();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
