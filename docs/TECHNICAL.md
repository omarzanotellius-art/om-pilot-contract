# Technical notes

The plain-language overview is in the [README](../README.md). This document covers how the contract is built, tested and run.

> Exploratory learning project. Not audited, not upgradeable, testnet only. Do not use with real money.

## Repository layout

| Path | What it is |
| --- | --- |
| `contracts/OMPilot.sol` | The contract: terms, roles, reserve, logbook, inspections, repair claims, end of term |
| `test/OMPilot.*.t.sol` | Rule tests in Solidity (forge-std), one file per area, plus `Story`: the full two-year Jupiter Ridge engagement as one test |
| `test/Toolchain.t.sol` | Toolchain check (compiler, test runner, clock fast-forward) |
| `test/helpers/OMPilotTestBase.sol` | Shared test setup: cast, clock, valid terms |
| `test/helpers/MockUSDC.sol` | Test-only stablecoin (6 decimals). Never deployed |
| `scripts/evidence.mjs` | Builds an evidence manifest and its fingerprint; checks one file against a manifest |
| `scripts/demo.ts` | The demo storyline (14 transactions), as a local rehearsal or live on Amoy; resumable |
| `evidence/` | Fictional sample evidence, one folder per on-chain record (`tender`, `handover-visit`, `inspection-1-attempt-1`, `rejection-note-1`, `repair-1`, `inspection-1-attempt-2`, `inspection-2`), each with its `manifest.json` |
| `deployments/amoy-demo.json` | Record of the live Amoy run: contract and token addresses, and every step's transaction, time, sender and gas |
| `hardhat.config.ts` | Compiler, optimiser and `amoy` network settings |

## Toolchain

| Item | Choice |
| --- | --- |
| Language | Solidity 0.8.37, pinned |
| Framework | Hardhat 3.17.0 (viem + Node test runner); rule tests in Solidity with forge-std v1.16.2 |
| Compiler | npm `solc` 0.8.37 (WebAssembly), used everywhere via Hardhat's `solidity.path` (absolute path). Optimiser on, 200 runs; all tests run against optimised code |
| Libraries | OpenZeppelin 5.6.1, pinned exactly: `IERC20`, `SafeERC20` (contract); `ERC20` (test mock only) |
| Network | Polygon Amoy testnet (chain ID 80002); gas in test POL |
| Token | Circle test USDC on Amoy, `0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582` (6 decimals) |
| Size | 14,793 bytes optimised, 60.2% of the 24 KB limit |
| Node.js | Works with Node 22 and Node 24 (developed on v24.21.0 in GitHub Codespaces) |

Hardhat's native engines have no current Windows-on-ARM64 builds; run in Linux, macOS, x64 Windows or GitHub Codespaces.

**Audit warnings (accepted, documented):** `npm install` reports 2 high (`tmp`, via `solc`'s unused command-line tool) and 11 low (`elliptic`, via the verification plugin's dependencies). npm's suggested fixes would downgrade the compiler or install an incompatible plugin. Nothing from these packages is deployed.

## Build, test, run

```
npm install
npm run build
npm test                                   # 155 tests
npx hardhat run scripts/demo.ts            # local rehearsal: test-only USDC stand-in, clock fast-forwarded, runs in seconds
```

### Live demo on Amoy

Requires test POL for both accounts and 20 test USDC for the owner account. Secrets are stored by name in Hardhat's password-protected (encrypted) keystore, never in the repository or in a `.env` file. Account 0 is the owner (Dana), account 1 the provider (Luis):

```
npx hardhat keystore set AMOY_RPC_URL
npx hardhat keystore set AMOY_OWNER_PRIVATE_KEY
npx hardhat keystore set AMOY_PROVIDER_PRIVATE_KEY
npx hardhat run scripts/demo.ts --network amoy
```

Do not use Hardhat's *development* keystore (it stores its password unencrypted), and do not set these values as environment variables: Hardhat reads an environment variable of the same name before the keystore.

The live run takes about 1.5 hours of real waiting. Before spending anything, the script checks both accounts' POL and the owner's USDC against the gas measured in the local rehearsal plus a 20% margin, and stops with "nothing spent" if either is short. It saves progress after every step to `deployments/amoy-demo.json`; re-running continues from the next step, and a step interrupted after sending waits for that same transaction instead of sending it again.

**Fees:** Polygon networks refuse transactions whose priority fee (tip) is below 25 gwei, and wallet estimates can be far lower. Every transaction offers a fixed 30-gwei tip, plus twice the current base fee as headroom.

**Gas on the live network ran higher than in the rehearsal:** owner +9%, provider +19%. Circle's real USDC costs more to call than the test stand-in (for example, approve 66k vs 46k gas, deposit 118k vs 88k), and the contract reads the token balance on every action. The provider's margin over the pre-flight figure was about 4%. To reproduce the run, give the provider more test POL (around 0.1 POL).

**Getting test POL:** public Amoy faucets now require the receiving address to hold a small mainnet balance and to have a transaction history. Plan for this before a live run.

**Resume rehearsal (local):** start `npx hardhat node` in a second terminal, then run `DEMO_INTERRUPT_AT="<step name>" npx hardhat run scripts/demo.ts --network localhost`. The script stops right after sending that step's transaction; re-run without `DEMO_INTERRUPT_AT` to resume. Progress goes to `deployments/localhost-demo.json`.

**Demo terms:** start 10 minutes after deployment (time for the provider to accept), 30-minute inspection interval, 10-minute tolerance, 80-minute term, 5 USDC per inspection, 5 USDC repair budget per period, 20 USDC deposit. Price list: string fuse replacement 1 USDC, connector replacement 1, inverter reset visit 2, combiner breaker replacement 3.

### Deployment (2 October 2026)

| Item | Value |
| --- | --- |
| Contract | [`0x641557b9392e67547dce6e6970ade4d9987defd7`](https://amoy.polygonscan.com/address/0x641557b9392e67547dce6e6970ade4d9987defd7) |
| Owner (Dana) | `0x0930ce1faee50452e3cdd24a23dfd65ba87c1dd1` |
| Provider (Luis) | `0x8a29dbca059746c4694eb91f83cb2687397c69fc` |
| Token | Circle test USDC, `0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582` |
| Outcome | Status Closed; 12 USDC paid to the provider (2 inspections × 5 + 2 connectors × 1) |
| Gas used | Owner 4,716,135 (8 transactions); provider 2,019,189 (6 transactions) |

| # | Step | From | Time (UTC) | Transaction |
| --- | --- | --- | --- | --- |
| 1 | Deploy | Owner | 15:32:04 | [`0x953cdb…9828`](https://amoy.polygonscan.com/tx/0x953cdbd8250036c6bd6c8ac584eacf353bfe66dbba5ae91e9cf8c26641a39828) |
| 2 | Accept | Provider | 15:32:08 | [`0xa2d1db…9693`](https://amoy.polygonscan.com/tx/0xa2d1db6cf00f7c20143a8429d1c05108d92512d6a757813d12fdb45d8d8b9693) |
| 3 | Log handover visit | Provider | 15:32:12 | [`0x08bfa6…de9e`](https://amoy.polygonscan.com/tx/0x08bfa6f652a2b0dcc924c8804cbf66887d524269ba36c0c19fedeb4b0587de9e) |
| 4 | Approve 20 USDC (token) | Owner | 15:32:16 | [`0x4a3774…2bb0`](https://amoy.polygonscan.com/tx/0x4a377498b5841ef88e0e925b9d03450197a1d2dd80d5f01232095955588c2bb0) |
| 5 | Deposit 20 USDC | Owner | 15:32:20 | [`0x152fde…e5f9`](https://amoy.polygonscan.com/tx/0x152fdef0ebf2bd2bf557a1d9da6309165e059f5707ba7b53ebff4e507568e5f9) |
| 6 | Submit inspection #1 (issues found) | Provider | 16:12:03 | [`0x0b4797…76cb`](https://amoy.polygonscan.com/tx/0x0b47978e69c04b5bfd212a92e8542cedf9bb799703459236c55e5761911e76cb) |
| 7 | Reject inspection #1 with a note | Owner | 16:12:07 | [`0x1bcfd5…4d5e`](https://amoy.polygonscan.com/tx/0x1bcfd5dbf8541a3539403dbf4da86d910d59d4b129a8575da6b6615ccdd04d5e) |
| 8 | Claim repair: 2 × connector | Provider | 16:12:11 | [`0xe45976…15fc`](https://amoy.polygonscan.com/tx/0xe45976295345be0e7c79aeca9d8f56df8d42bf6521116b09ba54aa1cd26915fc) |
| 9 | Resubmit inspection #1 (no issues found) | Provider | 16:12:15 | [`0xa7202c…9c42`](https://amoy.polygonscan.com/tx/0xa7202c35c565755a8f38c6b538cd38758dc802a6c035cf509b5f4fca48b49c42) |
| 10 | Confirm inspection #1 | Owner | 16:12:20 | [`0xe30440…4fd4`](https://amoy.polygonscan.com/tx/0xe30440fb0c70d6422c958f595e86efa51a4cf68df09da06ad04dfe0f64964fd4) |
| 11 | Confirm repair claim | Owner | 16:12:24 | [`0xf226ac…b7aa`](https://amoy.polygonscan.com/tx/0xf226acad54428e4bd0d9be336e5d99ff5d7845af102492a278c0c386e515b7aa) |
| 12 | Submit inspection #2 (no issues found) | Provider | 16:42:17 | [`0x00d2f7…f510`](https://amoy.polygonscan.com/tx/0x00d2f7ef3176ef184563ee534482d93abccd57f0a00d10f5d330c4afdae7f510) |
| 13 | Confirm inspection #2 | Owner | 16:42:21 | [`0x65930e…42e7`](https://amoy.polygonscan.com/tx/0x65930e895de21a7127bf276ca14799a9a5cf176b9f030126c655cc58f18c42e7) |
| 14 | Withdraw the rest | Owner | 17:02:03 | [`0x42620f…592b`](https://amoy.polygonscan.com/tx/0x42620f13010297f70966b5e76e7e32157c60cd5e75575c61d80085a7cdae592b) |

Times are when the script recorded each confirmed step. The full record is in [`deployments/amoy-demo.json`](../deployments/amoy-demo.json).

### Evidence tool

```
node scripts/evidence.mjs bundle <folder>
node scripts/evidence.mjs check <file> <manifest.json>
```

`bundle` fingerprints every file at the folder's top level (SHA-256; hidden files and `manifest.json` itself are skipped), writes `manifest.json`, and prints the manifest's fingerprint: the value submitted on-chain. The manifest has one fixed format (`{"files": [{"name", "sha256"}, …]}`, files sorted by name, no dates), so the same files always give the same fingerprint. `check` confirms one file is listed in a manifest with the same fingerprint and prints the manifest's fingerprint. Plain Node.js, no dependencies. The results match the operating system's own `sha256sum` / `shasum -a 256` / `Get-FileHash`.

`.gitattributes` disables line-ending conversion in `evidence/`, so fingerprints are identical on every operating system.

## Contract design

One immutable contract per engagement: one asset, one owner, one provider, one token. No administrator, no upgrade proxy, no pause, no parameter setters.

### Terms (constructor, immutable)

Owner (the deployer), provider, token, asset name, tender award fingerprint, start date, end date, inspection interval, tolerance, inspection rate, repair budget per period, price list (names and prices).

Creation is refused if: the token or provider address is empty; the provider is the owner; the start isn't in the future; the end isn't after the start; the interval or rate is zero; the tolerance is zero or not shorter than the interval; the term is shorter than one interval; the price list is empty or an item has no name or a zero price; the tender fingerprint is empty. A zero repair budget is allowed.

### Procedure (code constants)

| Constant | Value |
| --- | --- |
| `REVIEW_WINDOW` | 7 days |
| `RESUBMISSION_PERIOD` | 14 days |
| `MAX_CLAIM_ATTEMPTS` | 3 |
| `MAX_CLAIM_LINES` | 20 |

### Roles and permissions

| Action | Owner | Provider | Anyone | Allowed when |
| --- | --- | --- | --- | --- |
| `accept` | | ✓ once | | Strictly before the start date |
| `deposit` | ✓ | | | Any status except Never activated |
| `withdraw` (to the owner only) | ✓ | | | Up to balance − lock |
| `logRecord` | ✓ | ✓ | | From acceptance until the end date |
| `submitInspection` | | ✓ | | First submission inside its window; resubmission within its period; fee covered |
| `confirmInspection`, `rejectInspection` | ✓ | | | Pending review, strictly before the deadline; reject needs a note fingerprint |
| `claimInspectionOnTimeout` | ✓ | ✓ | ✓ | Pending review, at or after the deadline |
| `markMissed` | ✓ | ✓ | ✓ | An inspection is overdue |
| `submitClaim` | | ✓ | | Active, within the available budget |
| `confirmClaim`, `rejectClaim` | ✓ | | | Claim pending, strictly before its deadline |
| `resubmitClaim` | | ✓ | | Claim rejected, within its period, different evidence |
| `claimClaimOnTimeout` | ✓ | ✓ | ✓ | Claim pending, at or after its deadline |
| `markClaimLapsed` | ✓ | ✓ | ✓ | Claim rejected, resubmission period over |

Status is computed from the clock and stored facts, never stored: Awaiting acceptance → Accepted → Active → Ended (settling, while items are open) → Closed; or Never activated if the start date passes without acceptance.

### Schedule

Inspection 1 is due at start + interval. Each window opens at the due moment and closes strictly before due + tolerance; early submissions are refused. After an accepted inspection, the next is due one interval after the accepted submission's time; after a miss, one interval after the missed due date (even if that moment has already passed). An inspection due on or before the end date belongs to the term.

### The reserve (lock)

- Zero before acceptance, and if the contract never activated.
- From acceptance until the end date: fee of the next unresolved inspection + (period budget − paid this period) + claims still pending from earlier periods.
- After the end date: fee of an unresolved inspection due within the term + pending claims; zero once Closed.

When underfunded, the inspection fee is covered first. An inspection whose fee isn't covered is unfunded; its submissions are refused until the owner tops up, and a window that closes with no submission while unfunded is recorded as "missed (unfunded)", based on coverage as seen by the contract (direct transfers count from its next action; fund through `deposit`).

### Disputes and cutoffs

A rejection needs the fingerprint of a reason note (its own logbook entry); a resubmission can't reuse the rejected fingerprint. Owner decisions are allowed only strictly before the review deadline; after it, anyone may trigger payment to the provider, recorded as paid on timeout. Inspection disputes end at a cutoff (the next due date, or end date + 14 days if sooner); a review pending at the cutoff always finishes, and a rejection after it allows exactly one more resubmission with a final review. Repair claims end after 3 attempts; an expired resubmission period is recorded as a lapse by anyone.

Overdue misses are recorded automatically on the next inspection submission, or by anyone through `markMissed`. Unrecorded misses and lapses keep their amounts locked until someone records them.

### Logbook (passport)

One numbered logbook. Entry 1 is the provider's acceptance carrying the tender fingerprint; then inspection submissions (each attempt, with its finding), claim submissions (each attempt, with its lines), rejection notes and unpaid records (performance check, maintenance note, incident report, site visit, other). Each entry stores its kind, author, time, fingerprint, related item and detail. `verifyRecord(entry, fingerprint)` returns true or false; `findEntries(fingerprint)` returns every entry carrying a fingerprint.

### Events and errors

12 events: `Accepted`, `Deposited`, `Withdrawn`, `EntryAdded`, `InspectionSubmitted`, `InspectionRejected`, `InspectionPaid`, `InspectionMissed`, `ClaimSubmitted`, `ClaimRejected`, `ClaimPaid`, `ClaimLapsed`. Refusals use 38 named errors, each tied to a rule.

## Security model

- **Token movements:** only three. Deposits (owner → contract, from the owner's own approval), payments (contract → provider, fixed or price-list amounts) and withdrawals (contract → owner, no recipient parameter). No fee, penalty, rescue or third-party path.
- **Payments:** state is written before the token transfer (checks-effects-interactions), through OpenZeppelin `SafeERC20`.
- **Anyone-functions** only execute outcomes the clock has already fixed, paying fixed parties fixed amounts.
- **Assumes a standard ERC-20** without transfer hooks, fees or rebasing (Circle USDC). Other tokens are unsupported, though nothing prevents them at creation.
- **USDC's issuer can freeze addresses:** a payment to a frozen provider address reverts, and the confirmation with it.

## Testing

155 Solidity tests: an allow and a refuse test for every rule, including time-warped paths (timeouts, misses, cutoffs, end of term), and the full two-year story as one test. Each build part was sabotage-checked: rules were deliberately broken in a temporary copy to confirm the matching tests fail.

Not yet in place: property-based (fuzz) and invariant tests, continuous integration, external audit.

## Known technical limitations

- Not audited; immutable, so bugs can't be patched and lost keys can't be replaced.
- A very long term with long inactivity makes a single `markMissed` call more expensive (one loop iteration per overdue inspection).
- After a dispute runs past its cutoff and ends in a miss, the next inspection may already be overdue when it becomes current, and be recorded as missed at once.
- The logbook and its fingerprint index grow without limit.
- Minute-scale demo deadlines are more sensitive to block-timestamp drift than the day-scale production constants.

## Explorer verification

Source-code verification on Amoy Polygonscan is **pending**. Until then, the explorer shows each transaction but not the contract's function names or labelled inputs.

Fingerprints can already be checked in the raw data. Open a transaction from the table above, view its Input Data in the Original view, and search (Ctrl+F) for the fingerprint without the leading `0x`. If it appears, that exact value was submitted in that transaction, at that time, by the "From" address. This was confirmed on the live explorer for step 9 (resubmission of inspection #1): the evidence fingerprint follows the function code `84287b2a`, followed by the finding (zero, "no issues found"). Other transactions carry their fingerprints in the same field but at different positions (for example the repair claim and the deployment), so search rather than counting positions.

Once the source is verified, the explorer's Read Contract tab will also offer the contract's own checks, such as `verifyRecord(entry, fingerprint)` and `findEntries(fingerprint)`.

---

Copyright © 2026 OnToken, LLC. Free to use under the [MIT License](../LICENSE): anyone may use, copy and adapt it, at their own risk and with no warranty.
