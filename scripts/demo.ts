// The Jupiter Ridge Solar demo (spec §13.7, decisions 85–87) — two inspections,
// a rejection with a note, a repair claim, both payment types, then Closed.
//
//   Local rehearsal:  npx hardhat run scripts/demo.ts
//       Test-only USDC stand-in; the clock is fast-forwarded at each wait. Seconds.
//   Live on Amoy:     npx hardhat run scripts/demo.ts --network amoy
//       Circle's test USDC; real waiting (about 1.5 hours); an explorer link for
//       every transaction. RESUMABLE: progress is saved after every step to
//       deployments/amoy-demo.json, and re-running continues from the next step.
//   Resume rehearsal: npx hardhat node   (in a second terminal), then
//                     DEMO_INTERRUPT_AT="<step name>" npx hardhat run scripts/demo.ts --network localhost
//       stops right after SENDING that step's transaction (the hardest interruption);
//       re-run without DEMO_INTERRUPT_AT to resume. Progress: deployments/localhost-demo.json.
//
// Accounts: 0 = Owner (Dana), 1 = Provider (Luis). All names are fictional.

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { network } from "hardhat";
import { formatEther, formatUnits } from "viem";

// ---- demo terms (decision 86) --------------------------------------------
const MIN = 60n;
const START_DELAY = 10n * MIN; // time for the provider to accept
const INTERVAL = 30n * MIN;
const TOLERANCE = 10n * MIN;
const TERM = 80n * MIN;
const USDC = (n: number) => BigInt(Math.round(n * 1_000_000)); // 6 decimals
const RATE = USDC(5);
const BUDGET = USDC(5);
const DEPOSIT = USDC(20);
const PRICE_LIST = [
  { name: "String fuse replacement", price: USDC(1) },
  { name: "Connector replacement", price: USDC(1) },
  { name: "Inverter reset visit", price: USDC(2) },
  { name: "Combiner breaker replacement", price: USDC(3) },
];
const CIRCLE_TEST_USDC_AMOY = "0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582"; // spec §12
const EXPLORER = "https://amoy.polygonscan.com";

// Enum positions, as declared in the contract
const Finding = { NoIssuesFound: 0, IssuesFound: 1 } as const;
const RecordType = { SiteVisit: 3 } as const;
const Status = ["AwaitingAcceptance", "Accepted", "Active", "NeverActivated", "Ended", "Closed"];

/** The on-chain fingerprint of an evidence folder = SHA-256 of its manifest.json. */
function fingerprint(folder: string): `0x${string}` {
  const bytes = readFileSync(`evidence/${folder}/manifest.json`);
  return `0x${createHash("sha256").update(bytes).digest("hex")}`;
}

// ---- connection -------------------------------------------------------------
const connection = await network.create();
const { viem, networkName } = connection;
const publicClient = await viem.getPublicClient();
const [owner, provider] = await viem.getWalletClients();
const chainId = await publicClient.getChainId();
const localChain = chainId === 31337; // a local chain: use the test USDC stand-in and fast-forward the clock
const persist = networkName !== "default"; // save progress on any chain that outlives this run
const onAmoy = chainId === 80002;
const STATE_FILE = `deployments/${networkName}-demo.json`;

console.log(`\nJupiter Ridge Solar demo — network: ${networkName}${localChain ? " (local)" : " (LIVE)"}`);
console.log(`Owner (Dana):    ${owner.account.address}`);
console.log(`Provider (Luis): ${provider.account.address}\n`);

// ---- progress state (resumable on any persistent chain) -----------------------
type State = {
  contract?: `0x${string}`;
  token?: `0x${string}`;
  claimId?: string;
  done: Record<string, { tx?: string; at: string }>;
  pending?: { step: string; tx: `0x${string}` };
};
const state: State = persist && existsSync(STATE_FILE) ? JSON.parse(readFileSync(STATE_FILE, "utf8")) : { done: {} };
function save() {
  if (!persist) return;
  mkdirSync("deployments", { recursive: true });
  writeFileSync(STATE_FILE, JSON.stringify(state, null, 2) + "\n");
}
if (persist && Object.keys(state.done).length > 0) console.log(`Resuming: ${Object.keys(state.done).length} steps already done.\n`);

const link = (tx: string) => (onAmoy ? `${EXPLORER}/tx/${tx}` : tx);

/** Runs one transaction step once: skipped if done; if interrupted after sending,
 *  waits for that same transaction instead of sending it again. */
async function step(name: string, send: () => Promise<`0x${string}`>) {
  if (state.done[name]) {
    console.log(`✓ ${name} (already done)`);
    return;
  }
  let tx: `0x${string}`;
  if (state.pending?.step === name) {
    tx = state.pending.tx;
    console.log(`… ${name}: waiting for the transaction sent before the interruption`);
  } else {
    tx = await send();
    state.pending = { step: name, tx };
    save();
    if (process.env.DEMO_INTERRUPT_AT === name) {
      console.log(`⚡ interrupted on purpose right after sending "${name}" (rehearsal). Re-run to resume.`);
      process.exit(0);
    }
  }
  const receipt = await publicClient.waitForTransactionReceipt({ hash: tx });
  if (receipt.status !== "success") throw new Error(`${name}: transaction failed (${link(tx)})`);
  state.done[name] = { tx, at: new Date().toISOString() };
  delete state.pending;
  save();
  console.log(`✓ ${name}   ${link(tx)}`);
}

/** Waits until the chain's clock reaches `target` (fast-forwards when local). */
async function waitUntil(label: string, target: bigint) {
  if (localChain) {
    const now = (await publicClient.getBlock()).timestamp;
    if (now < target) await connection.networkHelpers.time.increaseTo(target);
    console.log(`⏩ ${label} (clock fast-forwarded)`);
    return;
  }
  for (;;) {
    const now = (await publicClient.getBlock()).timestamp;
    if (now >= target) break;
    const left = target - now;
    console.log(`⏳ ${label}: ${left / 60n} min ${left % 60n} s to go`);
    await new Promise((r) => setTimeout(r, Number(left > 60n ? 60n : left) * 1000));
  }
  console.log(`✓ ${label}`);
}

// ---- token --------------------------------------------------------------------
if (!state.token) {
  if (!localChain) {
    state.token = CIRCLE_TEST_USDC_AMOY;
  } else {
    const mock = await viem.deployContract("MockUSDC"); // test-only stand-in
    await mock.write.mint([owner.account.address, DEPOSIT]);
    state.token = mock.address;
  }
  save();
}
const usdc = await viem.getContractAt("MockUSDC", state.token); // same ERC-20 interface as Circle's USDC

// ---- pre-flight (live networks): stop before spending anything if funds are short
if (!localChain && !state.done["deploy"]) {
  const gasPrice = await publicClient.getGasPrice();
  const needOwner = (4_300_000n * gasPrice * 12n) / 10n; // measured gas + 20% margin
  const needProvider = (1_300_000n * gasPrice * 12n) / 10n;
  const polOwner = await publicClient.getBalance({ address: owner.account.address });
  const polProvider = await publicClient.getBalance({ address: provider.account.address });
  const usdcOwner = await usdc.read.balanceOf([owner.account.address]);
  console.log(`Gas price: ${formatUnits(gasPrice, 9)} gwei`);
  console.log(`Owner POL ${formatEther(polOwner)} (needs ~${formatEther(needOwner)}), USDC ${formatUnits(usdcOwner, 6)} (needs 20)`);
  console.log(`Provider POL ${formatEther(polProvider)} (needs ~${formatEther(needProvider)})\n`);
  const short: string[] = [];
  if (polOwner < needOwner) short.push("Owner needs more POL");
  if (polProvider < needProvider) short.push("Provider needs more POL");
  if (usdcOwner < DEPOSIT) short.push("Owner needs 20 test USDC");
  if (short.length) throw new Error(`Not started — nothing spent. ${short.join("; ")}.`);
}

// ---- 1. Deploy ------------------------------------------------------------------
await step("deploy", async () => {
  const now = (await publicClient.getBlock()).timestamp;
  const start = now + START_DELAY;
  const terms = {
    provider: provider.account.address,
    token: state.token!,
    assetName: "Jupiter Ridge Solar (demo)",
    tenderHash: fingerprint("tender"),
    startDate: start,
    endDate: start + TERM,
    inspectionInterval: INTERVAL,
    tolerance: TOLERANCE,
    inspectionRate: RATE,
    repairBudget: BUDGET,
  };
  const { deploymentTransaction } = await viem.sendDeploymentTransaction("OMPilot", [terms, PRICE_LIST]);
  return deploymentTransaction.hash;
});
if (!state.contract) {
  const receipt = await publicClient.getTransactionReceipt({ hash: state.done["deploy"].tx as `0x${string}` });
  state.contract = receipt.contractAddress!;
  save();
}
const c = await viem.getContractAt("OMPilot", state.contract);
console.log(`  contract: ${onAmoy ? `${EXPLORER}/address/${state.contract}` : state.contract}`);
const asOwner = { account: owner.account };
const asProvider = { account: provider.account };

// ---- 2. Signing and funding --------------------------------------------------------
await step("accept", () => c.write.accept(asProvider));
await step("log handover visit", () => c.write.logRecord([RecordType.SiteVisit, fingerprint("handover-visit")], asProvider));
await step("approve 20 USDC", () => usdc.write.approve([state.contract!, DEPOSIT], asOwner));
await step("deposit 20 USDC", () => c.write.deposit([DEPOSIT], asOwner));

// ---- 3. Inspection #1: issues found, rejected, repaired, resubmitted, confirmed ----
const [, due1] = await c.read.currentInspectionInfo();
if (!state.done["confirm inspection #1"]) await waitUntil("inspection #1 falls due", due1);
await step("submit inspection #1 (issues found)", () =>
  c.write.submitInspection([fingerprint("inspection-1-attempt-1"), Finding.IssuesFound], asProvider));
await step("reject inspection #1 with a note", () => c.write.rejectInspection([fingerprint("rejection-note-1")], asOwner));
await step("claim repair: 2 x connector", () =>
  c.write.submitClaim([[{ item: 1n, quantity: 2n }], fingerprint("repair-1")], asProvider));
if (!state.claimId) {
  state.claimId = (await c.read.claimCount()).toString();
  save();
}
await step("resubmit inspection #1 (no issues found)", () =>
  c.write.submitInspection([fingerprint("inspection-1-attempt-2"), Finding.NoIssuesFound], asProvider));
await step("confirm inspection #1", () => c.write.confirmInspection(asOwner));
await step("confirm repair claim", () => c.write.confirmClaim([BigInt(state.claimId!)], asOwner));

// ---- 4. Inspection #2 ----------------------------------------------------------------
if (!state.done["confirm inspection #2"]) {
  const [, due2] = await c.read.currentInspectionInfo();
  await waitUntil("inspection #2 falls due", due2);
}
await step("submit inspection #2 (no issues found)", () =>
  c.write.submitInspection([fingerprint("inspection-2"), Finding.NoIssuesFound], asProvider));
await step("confirm inspection #2", () => c.write.confirmInspection(asOwner));

// ---- 5. End of term: Closed, withdraw the rest ------------------------------------------
if (!state.done["withdraw the rest"]) await waitUntil("end date", await c.read.endDate());
const status = Status[Number(await c.read.status())];
console.log(`  status: ${status}`);
if (!state.done["withdraw the rest"] && status !== "Closed") throw new Error(`Expected Closed, found ${status}.`);
await step("withdraw the rest", async () => c.write.withdraw([await c.read.availableToWithdraw()], asOwner));

// ---- Summary -----------------------------------------------------------------------------
console.log(`\nProvider received: ${formatUnits(await usdc.read.balanceOf([provider.account.address]), 6)} USDC (expected 12)`);
console.log(`Contract balance:  ${formatUnits(await c.read.balance(), 6)} USDC (expected 0)`);
console.log(`Passport entries:  ${await c.read.entryCount()} (expected 7)`);
if (persist) console.log(`Progress file:     ${STATE_FILE}`);
console.log("Demo complete.\n");
