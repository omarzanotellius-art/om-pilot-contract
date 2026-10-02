# om-pilot-contract

**A code-run O&M agreement: the money is set aside before the work and released only once the work is on record — so reports arrive with the work, both sides can rely on the terms, and the asset builds a maintenance history anyone can check.**

> **Status: exploratory.** A learning project to explore smart contracts. It runs on a public **test** network with valueless test money, about a fictional solar asset. It is not a product, service, offering, investment or security token, and it has not been audited.

## What changes for an asset manager

**Efficiency: less chasing, less checking.**
- The inspection report *is* the payment request. The provider can't be paid without logging it, so it arrives when the work is done, not weeks later.
- Amounts come from the agreed rate and price list, so there are no invoices to check against the contract.
- Inspection due dates are worked out from the contract, and a missed inspection gets recorded as missed, by anyone, or automatically with the next submission. You don't need a tracking spreadsheet.

**Trust: both sides can rely on the terms.**
- The terms are fixed when the contract is created. Neither side can change them afterwards.
- The contract works like an escrow account. The owner deposits funds into the contract, not into their own account, and the money for the next inspection and the current repair budget stays locked there. The owner can't withdraw it while the engagement runs, so the provider can check at any time that the money is there before doing the work.
- Rejecting work requires a written reason, and if the owner stays silent for 7 days, the payment can be released by anyone, including the provider. Every dispute has a fixed end date.

**History: every decision, on record.**
- Every submission, approval, rejection and reason is logged with its date and author when it happens. "Why did we pay this?" always has an answer.
- A lender, auditor or buyer can check any maintenance document against the record themselves, without taking the binder on trust.

## What it asks in return

The owner deposits funds up front in a stablecoin (a digital dollar) and has to review submissions within 7 days. Only a rolling amount is locked: the next inspection plus the current repair budget, not the full contract value, so the rest stays available to the owner. Both parties use digital wallets. It covers routine inspections and list-price repairs only. Everything else stays in the paper contract.

## How it works

The agreement is a "smart contract": a small program on a public blockchain that holds money and releases it only under rules written in advance. It models one maintenance (O&M) engagement for one solar asset, awarded by tender.

- **Inspections.** When an inspection falls due, the provider logs a fingerprint of the evidence (photos, report, site data) and a finding: "no issues" or "issues found." Payment is for the inspection itself, whatever the finding, so the provider has no reason to hide a problem.
- **Review.** The owner has 7 days. Approving releases the payment at once. Rejecting requires a written reason, which is logged too, and the provider then has 14 days to resubmit with new evidence. If the owner doesn't decide in time, anyone (usually the provider) can release the payment, and the record shows it was paid because nobody decided.
- **Missed inspections.** If an inspection window passes with nothing logged, it is recorded as missed, or as "missed (unfunded)" if the owner hadn't set aside the money for it.
- **Repairs.** The provider fixes small faults first and then claims them from the agreed price list, within a budget per period. The amount is calculated from the list, not typed in. Claims go through the same review, with at most three attempts.
- **Other records.** Either side can log records that involve no payment, such as site visits or incident reports. Together with the provider's acceptance of the terms, every submission and every rejection reason, they form one numbered logbook.
- **End of term.** Once nothing is still open, the owner can withdraw the remaining money.

## Why it matters

Every maintenance job leaves a trail (the request, the visit, the report, the approval, the payment), and each party keeps its own part of it. That trail has to hold together across the life of an asset, even as owners, operators, lenders and service providers change. This pilot explores whether a code-run agreement can make the record a by-product of the work itself: one shared history of what was agreed, submitted, approved and paid, which both parties can see and neither can rewrite.

More on this in [post-003](https://theunlistedbrief.com/post-003.html).

## An example

*Jupiter Ridge Solar* is a fictional solar asset. Its owner, Dana (Aldermont Energy Holdings), awards a two-year maintenance tender to Luis (Tavistone Asset Services), with an inspection every 182 days and a small budget for routine repairs.

Dana creates the contract with the awarded terms and deposits the funds. Luis accepts on the record. When the first inspection falls due, Luis visits the site and logs his evidence and finding. Dana rejects it with a note asking for missing photos. Luis resubmits with them, and Dana approves; the payment goes out in the same step. Later Luis replaces a faulty part from the price list and is paid for it within the budget. At the end of the term, Dana withdraws whatever is no longer needed. Every step, including the rejection and its reason, stays in the logbook.

*All names are fictional. Any resemblance to real companies or people is unintended.*

## What it doesn't solve

Being clear about the limits is part of the point.

- **It can't tell whether a record is true.** A fingerprint proves that a document hasn't changed since it was logged, who logged it and when. It doesn't prove the inspection happened or the finding is right. Field observations are still human claims.
- **It doesn't store the documents.** Only fingerprints go on the blockchain. The documents stay with the parties, and a lost document can no longer be checked.
- **It covers routine O&M only.** Legal agreements, power purchase agreement (PPA) terms, financing, warranties, large repairs, penalties and termination are outside it. The tender document is anchored by its fingerprint, but only the terms written into the contract are enforced.
- **It can't judge fairness.** The owner can still reject good work. The contract only makes sure every rejection carries a recorded reason and that disputes come to an end.
- **Nothing happens by itself.** Deadlines are checked when someone acts. A payment owed after the owner's silence, for example, is released when anyone sends the request.
- **It is public.** Amounts, dates and account addresses are visible to anyone. Only the documents themselves stay private.
- **One owner, one provider, fixed terms.** No amendments, no change of provider, no recovery of lost access.

## Live demo (Polygon Amoy test network)

The full Jupiter Ridge storyline was run on 2 October 2026 on Polygon Amoy, a public test network using valueless test tokens. Do not send real funds to this address.

- **Contract:** [`0x641557b9392e67547dce6e6970ade4d9987defd7`](https://amoy.polygonscan.com/address/0x641557b9392e67547dce6e6970ade4d9987defd7)
- **Outcome:** two inspections (one rejected with a written reason, then resubmitted with new evidence and accepted), one repair claim, 12 test USDC paid to the provider, status Closed.
- **Every transaction:** listed in [`deployments/amoy-demo.json`](deployments/amoy-demo.json).
- **Source code on the explorer:** verification pending.

The 7-day and 14-day deadlines are fixed in the code, so they can't be shown in a shortened live run. They are tested instead, along with every other rule (see the technical notes).

## Verify a record yourself

You don't need to trust me, or install anything, to check that a document matches the record.

1. **Pick a sample file**, for example `evidence/inspection-1-attempt-2/photo-03.txt`, from this repository. Download the file (or clone the repository) rather than copying and pasting its text: copying can change invisible characters, such as line endings, and the fingerprint would no longer match.
2. **Fingerprint it** with the tool already on your computer, running the command in the folder that contains the file:
   - Windows (PowerShell): `Get-FileHash -Algorithm SHA256 photo-03.txt`
   - macOS: `shasum -a 256 photo-03.txt`
   - Linux: `sha256sum photo-03.txt`
3. **Compare** the result with the fingerprint listed next to `photo-03.txt` in the same folder's `manifest.json`. They should match exactly (upper or lower case doesn't matter).
4. **Fingerprint the manifest** the same way. This single value is what was logged on the blockchain.
5. **Look it up** on the block explorer. Find the matching step in `deployments/amoy-demo.json` (for the sample file, that's the resubmission of inspection 1) and open its transaction on the Amoy explorer. In the transaction's Input Data (Original view), search (Ctrl+F) for the fingerprint from step 4, without a leading `0x`. If it appears, that exact document was recorded on-chain at that time, by the address shown as "From." (Until the contract's source code is published on the explorer, the fingerprint appears inside the raw Input Data rather than as a labelled field.)

Change one character in the file and repeat step 2: the fingerprint changes completely, and the match fails.

## Technical details

For how it's built, tested and run: [docs/TECHNICAL.md](docs/TECHNICAL.md).

---

Copyright © 2026 OnToken, LLC. Free to use under the [MIT License](LICENSE): anyone may use, copy and adapt it, at their own risk and with no warranty.
