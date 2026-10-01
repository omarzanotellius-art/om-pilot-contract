// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title OMPilot — an O&M engagement as a smart contract
/// @notice Learning project. Not audited. Testnet only. Not a security token.
/// @dev Stage 1 (complete): the tender terms, fixed at creation; the provider's
///      acceptance and the contract's status; deposits; withdrawals and the lock.
///      Stage 2, part 1: the passport — one numbered logbook of fingerprinted
///      entries — and unpaid records. Part 2: the inspection schedule (which
///      inspection is current, when it is due, whether its window is open).
///      Part 3a: submitting an inspection, the owner confirming, payment, and
///      moving on to the next inspection. Part 3b: rejection with a reason note,
///      resubmission, and timeout payment triggered by anyone. Part 4a: misses
///      (window closed; resubmission period over), "missed (unfunded)", automatic
///      settling, and recording misses by anyone. Part 4b: cutoffs — a dispute
///      can't run on into the next inspection. Part 5a: repair claims (submit,
///      confirm, pay), budget periods, the full lock (decision 59), available budget.
///      Part 5b: claim rejection with a note, resubmission with new evidence only,
///      the 3-attempt limit, timeout payment by anyone, and lapses.
///      Part 6: end of term — Ended/Closed statuses, the lock released step by
///      step, and the end-of-term cutoff for inspections and claims.
contract OMPilot {
    using SafeERC20 for IERC20; // token transfers that always stop the action if they fail

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    /// One entry of the repair price list (e.g. "String fuse replacement", 150 USDC).
    struct PriceItem {
        string name;
        uint256 price; // in token units (USDC has 6 decimals: 1 USDC = 1_000_000)
    }

    /// The awarded tender terms, passed in as one package at creation.
    /// The owner is not listed: it is whoever creates (deploys) the contract.
    struct Terms {
        address provider;
        IERC20 token;
        string assetName;
        bytes32 tenderHash; // SHA-256 of the signed tender award document
        uint256 startDate; // unix time (seconds)
        uint256 endDate; // unix time (seconds)
        uint256 inspectionInterval; // seconds between inspections (e.g. 182 days)
        uint256 tolerance; // seconds after each due date the window stays open
        uint256 inspectionRate; // paid per accepted inspection, in token units
        uint256 repairBudget; // pre-authorised repairs per period, in token units (may be 0)
    }

    /// Where the engagement stands. Worked out from the clock and from
    /// whether the provider has accepted — never stored, so nobody has to
    /// send a transaction to "switch it on" at the start date.
    enum Status {
        AwaitingAcceptance, // before the start date, not yet accepted
        Accepted, // accepted, start date not yet reached
        Active, // accepted, start date reached
        NeverActivated, // start date reached without acceptance
        Ended, // after the end date, while an item is still open (settling)
        Closed // after the end date, nothing open
    }

    /// Where the current inspection stands (worked out from the clock, never stored).
    enum InspectionPhase {
        NotYetDue, // before its due date: submissions would be too early
        WindowOpen, // from the due moment until just before due + tolerance
        WindowClosed, // the window has closed without (part 4 turns this into a miss)
        NoneScheduled // no more inspections: next due date after the end date, or never activated
    }

    /// What the provider found at an inspection. Recorded publicly; it does not
    /// affect payment, which is for the inspection service (decision 60).
    enum Finding {
        NoIssuesFound,
        IssuesFound
    }

    /// Where the current inspection's review stands.
    enum ReviewState {
        Open, // waiting for the provider's submission
        PendingReview, // a submission awaits the owner's decision
        Rejected // rejected with a note; the provider may resubmit within the period
    }

    /// How a finished inspection ended.
    enum InspectionOutcome {
        None, // not finished
        Confirmed, // the owner confirmed it and the provider was paid
        PaidOnTimeout, // the owner didn't decide in time; payment was triggered after the deadline
        Missed // not completed in time: no payment (see MissReason)
    }

    /// Why a missed inspection counts as missed (decision 32).
    enum MissReason {
        None, // not missed
        Missed, // the provider's side
        MissedUnfunded // the fee was not covered at some point during the window: the owner's side
    }

    /// What is kept about each finished inspection.
    struct InspectionRecord {
        InspectionOutcome outcome;
        Finding finding; // the finding of the accepted attempt (meaningless if missed)
        uint256 acceptedAt; // when the accepted attempt was submitted
        uint256 acceptedEntry; // its passport entry number
        MissReason missReason; // why it was missed (None if not missed)
        uint256 missedAt; // when the miss actually happened (e.g. the moment the window closed)
        address recordedBy; // who sent the transaction that recorded the miss
    }

    /// One line of a repair claim: an item on the price list and a quantity.
    struct ClaimLine {
        uint256 item; // position on the price list (0 = first)
        uint256 quantity; // at least 1
    }

    /// Where a repair claim stands.
    enum ClaimState {
        None, // no such claim
        PendingReview, // awaiting the owner's decision
        Confirmed, // confirmed and paid
        Rejected, // rejected with a note; the provider may resubmit within the period
        PaidOnTimeout, // the owner didn't decide in time; payment was triggered after the deadline
        Lapsed // ended unpaid (third rejection, or no resubmission in time); budget freed
    }

    /// What is kept about each repair claim. Lines and amount are fixed at the
    /// first submission (decision 79).
    struct Claim {
        ClaimState state;
        uint256 amount; // computed from the price list
        uint256 period; // the budget period it belongs to (that of its first submission)
        uint256 attempts; // submissions so far (at most 3 — decision 64)
        uint256 pendingEntry; // passport entry under review
        uint256 submittedAt;
        uint256 reviewDeadline; // decisions only strictly before this
        uint256 resubmitDeadline; // after a rejection: resubmission only strictly before this
        bytes32 rejectedFingerprint; // evidence of the attempt just rejected
    }

    /// The kinds of entry in the passport (the numbered logbook).
    /// Only Acceptance and UnpaidRecord are written so far; the others follow in Stage 2.
    enum EntryKind {
        Acceptance, // entry 1: the provider accepts; fingerprint = tender award
        InspectionSubmission,
        ClaimSubmission,
        RejectionNote,
        UnpaidRecord
    }

    /// Types of unpaid record (§8.7).
    enum RecordType {
        PerformanceCheck,
        MaintenanceNote,
        IncidentReport,
        SiteVisit,
        Other
    }

    /// One passport entry. `relatesTo` and `detail` depend on the kind: e.g. for an
    /// unpaid record, `detail` is its RecordType; later, for an inspection submission,
    /// `relatesTo` is the inspection number and `detail` its finding.
    struct Entry {
        EntryKind kind;
        address author;
        uint256 timestamp; // from the block, never typed in
        bytes32 fingerprint; // SHA-256 of the document
        uint256 relatesTo;
        uint8 detail;
    }

    // ------------------------------------------------------------------
    // Public announcements (events) — readable on the block explorer
    // ------------------------------------------------------------------

    /// The provider accepted exactly these terms (identified by the tender hash).
    event Accepted(address indexed provider, bytes32 tenderHash, uint256 acceptedAt);

    /// The owner deposited `amount`; `newBalance` is what the contract holds afterwards.
    event Deposited(address indexed owner, uint256 amount, uint256 newBalance);

    /// The owner withdrew `amount`; `newBalance` is what the contract holds afterwards.
    event Withdrawn(address indexed owner, uint256 amount, uint256 newBalance);

    /// A new passport entry was written.
    event EntryAdded(uint256 indexed number, EntryKind kind, address indexed author, bytes32 fingerprint);

    /// The provider submitted inspection `inspection` as passport entry `entryNumber`.
    event InspectionSubmitted(uint256 indexed inspection, uint256 entryNumber, Finding finding);

    /// Inspection `inspection` was paid; `triggeredBy` sent the transaction that settled it.
    event InspectionPaid(
        uint256 indexed inspection, uint256 amount, InspectionOutcome outcome, address indexed triggeredBy
    );

    /// Inspection `inspection` was missed at `missedAt`; `recordedBy` sent the
    /// transaction that recorded it (explicitly, or automatically as part of another action).
    event InspectionMissed(
        uint256 indexed inspection, MissReason reason, uint256 missedAt, address indexed recordedBy
    );

    /// The provider submitted repair claim `claimId` for `amount`, in budget period `period`.
    event ClaimSubmitted(uint256 indexed claimId, uint256 entryNumber, uint256 amount, uint256 period);

    /// Repair claim `claimId` was paid; `triggeredBy` sent the transaction that settled it.
    event ClaimPaid(uint256 indexed claimId, uint256 amount, ClaimState outcome, address indexed triggeredBy);

    /// The owner rejected claim `claimId`'s submission in `submissionEntry`, with her note in
    /// `noteEntry`. `resubmitBy` is 0 when this was the last attempt (the claim lapses).
    event ClaimRejected(uint256 indexed claimId, uint256 submissionEntry, uint256 noteEntry, uint256 resubmitBy);

    /// Claim `claimId` lapsed at `lapsedAt`, unpaid; its budget is freed.
    event ClaimLapsed(uint256 indexed claimId, uint256 lapsedAt, address indexed recordedBy);

    /// The owner rejected the submission in `submissionEntry`, with her note in `noteEntry`.
    /// The provider may resubmit strictly before `resubmitBy`.
    event InspectionRejected(
        uint256 indexed inspection, uint256 submissionEntry, uint256 noteEntry, uint256 resubmitBy
    );

    // ------------------------------------------------------------------
    // Named refusals (decision 56)
    // ------------------------------------------------------------------

    error ZeroAddress();
    error SameOwnerAndProvider();
    error StartNotInFuture();
    error EndNotAfterStart();
    error ZeroInterval();
    error InvalidTolerance();
    error TermShorterThanInterval();
    error ZeroRate();
    error EmptyPriceList();
    error InvalidPriceItem(uint256 index);
    error NotProvider();
    error AlreadyAccepted();
    error AcceptanceWindowClosed();
    error NotOwner();
    error ZeroAmount();
    error ContractNeverActivated();
    error WithdrawalExceedsUnlocked(uint256 requested, uint256 available);
    error EmptyTenderHash();
    error EmptyFingerprint();
    error NotAParty();
    error RecordingNotAllowed();
    error NoSuchEntry(uint256 number);
    error WindowNotOpen(InspectionPhase phase);
    error SubmissionNotExpected();
    error InspectionUnfunded(uint256 required, uint256 balance);
    error NotPendingReview();
    error ReviewDeadlinePassed();
    error ResubmissionPeriodOver();
    error SameEvidenceAsRejected();
    error ReviewStillOpen();
    error NothingToRecord();
    error ClaimsNotAllowed();
    error InvalidClaimLines();
    error InvalidClaimLine(uint256 index);
    error ClaimExceedsAvailableBudget(uint256 amount, uint256 available);
    error NoSuchClaim(uint256 claimId);
    error ClaimNotPendingReview(uint256 claimId);
    error ClaimNotAwaitingResubmission(uint256 claimId);

    // ------------------------------------------------------------------
    // Terms — written once at creation; no function can change them
    // ------------------------------------------------------------------

    address public immutable owner;
    address public immutable provider;
    IERC20 public immutable token;
    bytes32 public immutable tenderHash;
    uint256 public immutable startDate;
    uint256 public immutable endDate;
    uint256 public immutable inspectionInterval;
    uint256 public immutable tolerance;
    uint256 public immutable inspectionRate;
    uint256 public immutable repairBudget;

    /// Text and lists can't be `immutable` in Solidity; they are stored once
    /// here, and simply no function exists that could edit them.
    string public assetName;
    PriceItem[] private _priceList;

    // ------------------------------------------------------------------
    // Acceptance — the only things that change in part B
    // ------------------------------------------------------------------

    bool public accepted;
    uint256 public acceptedAt; // unix time of acceptance (0 = not accepted)

    // ------------------------------------------------------------------
    // The passport — entries are numbered from 1; entry n is _entries[n - 1]
    // ------------------------------------------------------------------

    Entry[] private _entries;
    mapping(bytes32 => uint256[]) private _entriesByFingerprint;

    // ------------------------------------------------------------------
    // The inspection schedule — only two facts are kept
    // ------------------------------------------------------------------

    uint256 public currentInspection; // number of the current inspection (starts at 1)
    uint256 private _currentDue; // its due date (unix time)

    // ------------------------------------------------------------------
    // Review of the current inspection, and records of finished ones
    // ------------------------------------------------------------------

    /// The owner's time to decide on each submission (a rule of procedure, §7).
    uint256 public constant REVIEW_WINDOW = 7 days;

    ReviewState private _review;
    uint256 private _pendingEntry; // passport entry under review
    uint256 private _pendingSubmittedAt; // when it was submitted
    uint256 private _reviewDeadline; // decisions only strictly before this (decision 61)

    /// The provider's time to resubmit after each rejection (a rule of procedure, §7).
    uint256 public constant RESUBMISSION_PERIOD = 14 days;

    uint256 private _resubmitDeadline; // resubmission only strictly before this
    bytes32 private _rejectedFingerprint; // evidence of the attempt just rejected

    /// Since when the inspection fee has been continuously covered by the balance,
    /// as seen by the contract (0 = not covered when last seen). Re-checked at every
    /// action; money sent directly counts from the next action onwards (decision 76).
    uint256 private _coveredSince;

    /// Whether the one extra resubmission chance after the cutoff has been given.
    bool private _postCutoffChanceUsed;

    // ------------------------------------------------------------------
    // Repair claims and budget periods
    // ------------------------------------------------------------------

    /// Lines per repair claim (a rule of procedure, §7; decision 69).
    uint256 public constant MAX_CLAIM_LINES = 20;

    /// Attempts per repair claim: the first + 2 resubmissions (§7; decision 64).
    uint256 public constant MAX_CLAIM_ATTEMPTS = 3;

    uint256 public claimCount; // claims are numbered from 1
    mapping(uint256 => Claim) private _claims;
    mapping(uint256 => ClaimLine[]) private _claimLines;

    mapping(uint256 => uint256) private _paidInPeriod; // per budget period
    mapping(uint256 => uint256) private _pendingInPeriod; // claims awaiting a decision, per period
    uint256 private _totalPending; // across all periods

    mapping(uint256 => InspectionRecord) private _inspectionRecords;

    // ------------------------------------------------------------------
    // Creation
    // ------------------------------------------------------------------

    /// @param terms the awarded tender terms
    /// @param priceList the repair price list (names and prices)
    constructor(Terms memory terms, PriceItem[] memory priceList) {
        // Parties and token
        if (address(terms.token) == address(0) || terms.provider == address(0)) revert ZeroAddress();
        if (terms.provider == msg.sender) revert SameOwnerAndProvider();
        if (terms.tenderHash == bytes32(0)) revert EmptyTenderHash();

        // Dates
        if (terms.startDate <= block.timestamp) revert StartNotInFuture();
        if (terms.endDate <= terms.startDate) revert EndNotAfterStart();

        // Schedule
        if (terms.inspectionInterval == 0) revert ZeroInterval();
        if (terms.tolerance == 0 || terms.tolerance >= terms.inspectionInterval) revert InvalidTolerance();
        if (terms.endDate - terms.startDate < terms.inspectionInterval) revert TermShorterThanInterval();

        // Money (a repair budget of zero is allowed: no pre-authorised repairs)
        if (terms.inspectionRate == 0) revert ZeroRate();

        // Price list
        if (priceList.length == 0) revert EmptyPriceList();
        for (uint256 i = 0; i < priceList.length; ++i) {
            if (bytes(priceList[i].name).length == 0 || priceList[i].price == 0) revert InvalidPriceItem(i);
            _priceList.push(priceList[i]);
        }

        owner = msg.sender;
        provider = terms.provider;
        token = terms.token;
        tenderHash = terms.tenderHash;
        startDate = terms.startDate;
        endDate = terms.endDate;
        inspectionInterval = terms.inspectionInterval;
        tolerance = terms.tolerance;
        inspectionRate = terms.inspectionRate;
        repairBudget = terms.repairBudget;
        assetName = terms.assetName;

        // Inspection #1 is due one interval after the start (§8.3)
        currentInspection = 1;
        _currentDue = terms.startDate + terms.inspectionInterval;
    }

    // ------------------------------------------------------------------
    // Acceptance and status
    // ------------------------------------------------------------------

    /// The provider accepts the terms. Only once, and strictly before the start date.
    function accept() external {
        if (msg.sender != provider) revert NotProvider();
        if (accepted) revert AlreadyAccepted();
        if (block.timestamp >= startDate) revert AcceptanceWindowClosed();

        accepted = true;
        acceptedAt = block.timestamp;
        _addEntry(EntryKind.Acceptance, provider, tenderHash, 0, 0); // entry 1
        _updateCoverage();
        emit Accepted(provider, tenderHash, block.timestamp);
    }

    /// Where the engagement stands right now (see `Status`).
    function status() public view returns (Status) {
        bool started = block.timestamp >= startDate;
        if (!accepted) return started ? Status.NeverActivated : Status.AwaitingAcceptance;
        if (!started) return Status.Accepted;
        if (block.timestamp < endDate) return Status.Active;
        return _hasOpenItems() ? Status.Ended : Status.Closed;
    }

    /// Anything still open: an inspection due within the term but not yet resolved
    /// (including an overdue miss not yet recorded), or a claim under review or rework.
    function _hasOpenItems() internal view returns (bool) {
        return _currentDue <= endDate || _totalPending > 0;
    }

    // ------------------------------------------------------------------
    // Money: deposits and balance
    // ------------------------------------------------------------------

    /// The owner deposits `amount` of the token. She must first approve this
    /// contract on the token for at least `amount` (the standard two-step handshake);
    /// otherwise the token itself refuses the transfer.
    function deposit(uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        if (amount == 0) revert ZeroAmount();
        if (status() == Status.NeverActivated) revert ContractNeverActivated();

        token.safeTransferFrom(owner, address(this), amount);
        _updateCoverage();
        emit Deposited(owner, amount, balance());
    }

    /// Everything the contract holds in the token (decision 58). Includes any
    /// amount sent to it directly, which counts as the owner's money.
    function balance() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /// The owner withdraws `amount`, always to her own address (there is no
    /// "send to" field). At most the unlocked part of the balance.
    function withdraw(uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        if (amount == 0) revert ZeroAmount();
        uint256 available = availableToWithdraw();
        if (amount > available) revert WithdrawalExceedsUnlocked(amount, available);

        token.safeTransfer(owner, amount);
        _updateCoverage();
        emit Withdrawn(owner, amount, balance());
    }

    // ------------------------------------------------------------------
    // The rolling lock (decisions 53, 59)
    // ------------------------------------------------------------------

    /// Money reserved for the provider, which the owner cannot withdraw.
    /// Zero until the provider accepts (decision 53) — so also zero if the
    /// contract never activated. Once accepted (decision 59): the fee of the next
    /// unresolved inspection (if one is still scheduled in the term) + this budget
    /// period's budget minus what has been paid this period + claims still pending
    /// from earlier periods. Pending claims of this period sit inside the budget term.
    /// After the end date (decision 67): only what is still open — an unresolved
    /// inspection's fee and pending claims. The unused budget is released at once,
    /// each item as it resolves, and the lock is zero once Closed.
    function lockedAmount() public view returns (uint256) {
        if (!accepted) return 0;
        if (block.timestamp >= endDate) return _scheduledFee() + _totalPending;
        uint256 period = currentPeriod();
        uint256 earlierPending = _totalPending - _pendingInPeriod[period];
        return _scheduledFee() + (repairBudget - _paidInPeriod[period]) + earlierPending;
    }

    /// The inspection fee, if an inspection is still scheduled within the term.
    function _scheduledFee() internal view returns (uint256) {
        return _currentDue <= endDate ? inspectionRate : 0;
    }

    /// What the owner can withdraw right now: balance minus lock, never below zero.
    function availableToWithdraw() public view returns (uint256) {
        uint256 bal = balance();
        uint256 locked = lockedAmount();
        return bal > locked ? bal - locked : 0;
    }

    // ------------------------------------------------------------------
    // The inspection schedule
    // ------------------------------------------------------------------

    /// The current inspection: its number, due date, the moment its window closes
    /// (strictly before — decision 72) and its phase. An inspection due on or before
    /// the end date belongs to the term (decision 73).
    function currentInspectionInfo()
        external
        view
        returns (uint256 number, uint256 dueDate, uint256 windowClosesAt, InspectionPhase phase)
    {
        number = currentInspection;
        dueDate = _currentDue;
        windowClosesAt = _currentDue + tolerance;
        phase = _inspectionPhase();
    }

    /// The provider submits the current inspection: the fingerprint of the evidence
    /// bundle and the finding. A first submission needs the window open; a
    /// resubmission after a rejection needs to be within the resubmission period,
    /// with different evidence. The fee must be covered either way.
    function submitInspection(bytes32 fingerprint, Finding finding) external returns (uint256 entryNumber) {
        if (msg.sender != provider) revert NotProvider();

        // Record any overdue misses first (decision 65). If that happened but the
        // submission still can't go through, report the ORIGINAL problem — Luis was
        // too late for the inspection he meant — rather than the next one's (decision 77).
        bool wasResubmissionLate = _review == ReviewState.Rejected && block.timestamp >= _resubmitDeadline;
        if (_settleOverdueMisses() > 0 && _inspectionPhase() != InspectionPhase.WindowOpen) {
            if (wasResubmissionLate) revert ResubmissionPeriodOver();
            revert WindowNotOpen(InspectionPhase.WindowClosed);
        }
        _updateCoverage();
        if (_review == ReviewState.PendingReview) revert SubmissionNotExpected();
        if (_review == ReviewState.Open) {
            // First submission: the window must be open
            InspectionPhase phase = _inspectionPhase();
            if (phase != InspectionPhase.WindowOpen) revert WindowNotOpen(phase);
        } else {
            // Resubmission after a rejection: within the period, with different evidence
            if (block.timestamp >= _resubmitDeadline) revert ResubmissionPeriodOver();
            if (fingerprint == _rejectedFingerprint) revert SameEvidenceAsRejected();
        }
        uint256 bal = balance();
        if (bal < inspectionRate) revert InspectionUnfunded(inspectionRate, bal);

        entryNumber =
            _addEntry(EntryKind.InspectionSubmission, provider, fingerprint, currentInspection, uint8(finding));
        _review = ReviewState.PendingReview;
        _pendingEntry = entryNumber;
        _pendingSubmittedAt = block.timestamp;
        _reviewDeadline = block.timestamp + REVIEW_WINDOW;
        emit InspectionSubmitted(currentInspection, entryNumber, finding);
    }

    /// The owner confirms the submission under review, strictly before the deadline.
    /// The provider is paid the inspection rate, and the next inspection is scheduled.
    function confirmInspection() external {
        if (msg.sender != owner) revert NotOwner();
        if (_review != ReviewState.PendingReview) revert NotPendingReview();
        if (block.timestamp >= _reviewDeadline) revert ReviewDeadlinePassed();
        _settleAccepted(InspectionOutcome.Confirmed);
    }

    /// The owner rejects the submission under review, strictly before the deadline,
    /// with the fingerprint of a rejection note (shared with the provider off-chain).
    /// The note becomes its own passport entry; the provider may then resubmit.
    function rejectInspection(bytes32 noteFingerprint) external returns (uint256 noteEntry) {
        if (msg.sender != owner) revert NotOwner();
        if (_review != ReviewState.PendingReview) revert NotPendingReview();
        if (block.timestamp >= _reviewDeadline) revert ReviewDeadlinePassed();

        uint256 submissionEntry = _pendingEntry;
        noteEntry = _addEntry(EntryKind.RejectionNote, owner, noteFingerprint, submissionEntry, 0);

        // Cutoff rules (§8.5)
        uint256 cutoff = _cutoff();
        if (block.timestamp >= cutoff && _postCutoffChanceUsed) {
            // Second rejection after the cutoff: the review of the extra chance is final.
            emit InspectionRejected(currentInspection, submissionEntry, noteEntry, 0);
            _recordMiss(MissReason.Missed, block.timestamp);
            _updateCoverage();
            return noteEntry;
        }
        uint256 resubmitBy = block.timestamp + RESUBMISSION_PERIOD;
        if (block.timestamp >= cutoff) {
            _postCutoffChanceUsed = true; // exactly one further, full resubmission period
        } else if (resubmitBy > cutoff) {
            resubmitBy = cutoff; // a cutoff shortens a resubmission period that runs into it
        }

        _rejectedFingerprint = _entries[submissionEntry - 1].fingerprint;
        _resubmitDeadline = resubmitBy;
        _review = ReviewState.Rejected;
        _pendingEntry = 0;
        _pendingSubmittedAt = 0;
        _reviewDeadline = 0;
        _updateCoverage();
        emit InspectionRejected(currentInspection, submissionEntry, noteEntry, resubmitBy);
    }

    /// The current inspection's cutoff — when the next inspection would be due —
    /// and whether the one extra chance after it has been used.
    function inspectionCutoff() external view returns (uint256 cutoff, bool postCutoffChanceUsed) {
        return (_cutoff(), _postCutoffChanceUsed);
    }

    /// The cutoff: when the next inspection would be due (one interval after the
    /// current due date), or the end-of-term cutoff — end date + RESUBMISSION_PERIOD —
    /// if that comes sooner (§8.5, §8.8).
    function _cutoff() internal view returns (uint256) {
        uint256 normal = _currentDue + inspectionInterval;
        uint256 endOfTerm = endDate + RESUBMISSION_PERIOD;
        return normal < endOfTerm ? normal : endOfTerm;
    }

    /// Once the owner's deadline has passed without a decision, anyone may trigger
    /// payment (decision 63). It always pays the provider; the event records who triggered it.
    function claimInspectionOnTimeout() external {
        if (_review != ReviewState.PendingReview) revert NotPendingReview();
        if (block.timestamp < _reviewDeadline) revert ReviewStillOpen();
        _settleAccepted(InspectionOutcome.PaidOnTimeout);
    }

    /// After a rejection: the resubmission deadline and the fingerprint that may not be reused.
    function inspectionRework() external view returns (uint256 resubmitDeadline, bytes32 rejectedFingerprint) {
        return (_resubmitDeadline, _rejectedFingerprint);
    }

    /// The review state of the current inspection.
    function inspectionReview()
        external
        view
        returns (ReviewState state, uint256 pendingEntry, uint256 submittedAt, uint256 reviewDeadline)
    {
        return (_review, _pendingEntry, _pendingSubmittedAt, _reviewDeadline);
    }

    /// What is recorded about inspection `number` once finished (outcome None if not).
    function inspectionRecord(uint256 number) external view returns (InspectionRecord memory) {
        return _inspectionRecords[number];
    }

    /// Records the accepted inspection, schedules the next one, then pays.
    /// Records first, money last (checks, effects, interactions).
    function _settleAccepted(InspectionOutcome outcome) internal {
        uint256 number = currentInspection;
        _inspectionRecords[number] = InspectionRecord({
            outcome: outcome,
            finding: Finding(_entries[_pendingEntry - 1].detail),
            acceptedAt: _pendingSubmittedAt,
            acceptedEntry: _pendingEntry,
            missReason: MissReason.None,
            missedAt: 0,
            recordedBy: address(0)
        });

        // Next inspection: one interval after the accepted submission (§8.3)
        currentInspection = number + 1;
        _currentDue = _pendingSubmittedAt + inspectionInterval;
        _review = ReviewState.Open;
        _pendingEntry = 0;
        _pendingSubmittedAt = 0;
        _reviewDeadline = 0;
        _resubmitDeadline = 0;
        _rejectedFingerprint = bytes32(0);
        _postCutoffChanceUsed = false;

        token.safeTransfer(provider, inspectionRate);
        _updateCoverage(); // the next inspection's fee may no longer be covered
        emit InspectionPaid(number, inspectionRate, outcome, msg.sender);
    }

    // ------------------------------------------------------------------
    // Misses (part 4a): recorded explicitly by anyone, or automatically
    // ------------------------------------------------------------------

    /// Anyone may record overdue misses (decision 65). Records every inspection
    /// that is overdue right now, oldest first; refused if there is nothing to record.
    function markMissed() external returns (uint256 recorded) {
        recorded = _settleOverdueMisses();
        if (recorded == 0) revert NothingToRecord();
        _updateCoverage();
    }

    /// Records every overdue miss, oldest first, moving the schedule on after each.
    /// (a) the window closed with no first submission;
    /// (b) the resubmission period ran out after a rejection — including one
    ///     shortened by the cutoff, which is how (c) a dispute unresolved at its
    ///     cutoff becomes a miss. A submission awaiting review is never settled here.
    function _settleOverdueMisses() internal returns (uint256 count) {
        while (status() != Status.NeverActivated && _currentDue <= endDate) {
            if (_review == ReviewState.Open && block.timestamp >= _currentDue + tolerance) {
                _recordMiss(_windowMissReason(), _currentDue + tolerance);
            } else if (_review == ReviewState.Rejected && block.timestamp >= _resubmitDeadline) {
                _recordMiss(MissReason.Missed, _resubmitDeadline);
            } else {
                break;
            }
            ++count;
        }
    }

    /// A window miss is the owner's side if the fee was not continuously covered
    /// from the due moment on — as far as the contract has seen (decision 76).
    function _windowMissReason() internal view returns (MissReason) {
        if (_coveredSince == 0 || _coveredSince > _currentDue) return MissReason.MissedUnfunded;
        return MissReason.Missed;
    }

    /// Records the current inspection as missed; the next is due one interval
    /// after the missed due date (§8.3). No payment.
    function _recordMiss(MissReason reason, uint256 missedAt) internal {
        uint256 number = currentInspection;
        _inspectionRecords[number] = InspectionRecord({
            outcome: InspectionOutcome.Missed,
            finding: Finding.NoIssuesFound,
            acceptedAt: 0,
            acceptedEntry: 0,
            missReason: reason,
            missedAt: missedAt,
            recordedBy: msg.sender
        });
        currentInspection = number + 1;
        _currentDue = _currentDue + inspectionInterval;
        _review = ReviewState.Open;
        _pendingEntry = 0;
        _pendingSubmittedAt = 0;
        _reviewDeadline = 0;
        _resubmitDeadline = 0;
        _rejectedFingerprint = bytes32(0);
        _postCutoffChanceUsed = false;
        emit InspectionMissed(number, reason, missedAt, msg.sender);
    }

    /// Re-checks whether the inspection fee is covered, and since when.
    function _updateCoverage() internal {
        if (balance() < inspectionRate) {
            _coveredSince = 0;
        } else if (_coveredSince == 0) {
            _coveredSince = block.timestamp;
        }
    }

    function _inspectionPhase() internal view returns (InspectionPhase) {
        if (status() == Status.NeverActivated || _currentDue > endDate) return InspectionPhase.NoneScheduled;
        if (block.timestamp < _currentDue) return InspectionPhase.NotYetDue;
        if (block.timestamp < _currentDue + tolerance) return InspectionPhase.WindowOpen;
        return InspectionPhase.WindowClosed;
    }

    // ------------------------------------------------------------------
    // Repair claims (part 5a)
    // ------------------------------------------------------------------

    /// The budget period now: 0 until one interval after the start, then 1, ...
    /// (a fixed grid from the start date — §8.6).
    function currentPeriod() public view returns (uint256) {
        if (block.timestamp < startDate) return 0;
        return (block.timestamp - startDate) / inspectionInterval;
    }

    /// What a new claim may cost right now: this period's budget minus paid and
    /// pending, limited to what the balance still covers after the inspection fee
    /// and all pending claims (the inspection comes first — §8.2). Zero unless Active.
    function availableRepairBudget() public view returns (uint256) {
        if (!accepted || block.timestamp < startDate || block.timestamp >= endDate) return 0;
        uint256 period = currentPeriod();
        uint256 byBudget = repairBudget - _paidInPeriod[period] - _pendingInPeriod[period];
        uint256 reserved = _scheduledFee() + _totalPending;
        uint256 bal = balance();
        uint256 byBalance = bal > reserved ? bal - reserved : 0;
        return byBudget < byBalance ? byBudget : byBalance;
    }

    /// The provider claims for a routine repair already done: 1–20 lines from the
    /// price list, plus the fingerprint of the repair evidence. The contract computes
    /// the amount. Only while Active (decision 66), and only within the available budget.
    function submitClaim(ClaimLine[] calldata lines, bytes32 fingerprint) external returns (uint256 claimId) {
        if (msg.sender != provider) revert NotProvider();
        if (!accepted || block.timestamp < startDate || block.timestamp >= endDate) revert ClaimsNotAllowed();
        if (lines.length == 0 || lines.length > MAX_CLAIM_LINES) revert InvalidClaimLines();

        uint256 amount;
        for (uint256 i = 0; i < lines.length; ++i) {
            if (lines[i].item >= _priceList.length || lines[i].quantity == 0) revert InvalidClaimLine(i);
            amount += _priceList[lines[i].item].price * lines[i].quantity;
        }
        _updateCoverage();
        uint256 available = availableRepairBudget();
        if (amount > available) revert ClaimExceedsAvailableBudget(amount, available);

        claimId = ++claimCount;
        uint256 period = currentPeriod();
        uint256 entryNumber = _addEntry(EntryKind.ClaimSubmission, provider, fingerprint, claimId, 0);
        _claims[claimId] = Claim({
            state: ClaimState.PendingReview,
            amount: amount,
            period: period,
            attempts: 1,
            pendingEntry: entryNumber,
            submittedAt: block.timestamp,
            reviewDeadline: block.timestamp + REVIEW_WINDOW,
            resubmitDeadline: 0,
            rejectedFingerprint: bytes32(0)
        });
        for (uint256 i = 0; i < lines.length; ++i) {
            _claimLines[claimId].push(lines[i]);
        }
        _pendingInPeriod[period] += amount;
        _totalPending += amount;
        emit ClaimSubmitted(claimId, entryNumber, amount, period);
    }

    /// The owner confirms a claim under review, strictly before its deadline; it is paid.
    function confirmClaim(uint256 claimId) external {
        if (msg.sender != owner) revert NotOwner();
        Claim storage theClaim = _existingClaim(claimId);
        if (theClaim.state != ClaimState.PendingReview) revert ClaimNotPendingReview(claimId);
        if (block.timestamp >= theClaim.reviewDeadline) revert ReviewDeadlinePassed();
        _payClaim(claimId, ClaimState.Confirmed);
    }

    /// The owner rejects a claim under review, strictly before its deadline, with the
    /// fingerprint of a rejection note. If this was the third attempt, the claim lapses.
    function rejectClaim(uint256 claimId, bytes32 noteFingerprint) external returns (uint256 noteEntry) {
        if (msg.sender != owner) revert NotOwner();
        Claim storage theClaim = _existingClaim(claimId);
        if (theClaim.state != ClaimState.PendingReview) revert ClaimNotPendingReview(claimId);
        if (block.timestamp >= theClaim.reviewDeadline) revert ReviewDeadlinePassed();

        uint256 submissionEntry = theClaim.pendingEntry;
        noteEntry = _addEntry(EntryKind.RejectionNote, owner, noteFingerprint, submissionEntry, 0);
        _updateCoverage();

        if (theClaim.attempts >= MAX_CLAIM_ATTEMPTS) {
            emit ClaimRejected(claimId, submissionEntry, noteEntry, 0);
            _lapseClaim(claimId, block.timestamp); // the third rejection ends the claim
            return noteEntry;
        }
        // End-of-term cutoff (§8.8): it shortens a resubmission period that runs into it;
        // a rejection after it gets a full period. (The spec's "final review after the
        // cutoff" needs no code for claims: a first attempt can't still be under review
        // at the cutoff, so the earliest rejection after it is of attempt 2 — its extra
        // chance is attempt 3, which the 3-attempt limit already makes final.)
        uint256 cutoff = endDate + RESUBMISSION_PERIOD;
        uint256 resubmitBy = block.timestamp + RESUBMISSION_PERIOD;
        if (block.timestamp < cutoff && resubmitBy > cutoff) resubmitBy = cutoff;
        theClaim.state = ClaimState.Rejected;
        theClaim.rejectedFingerprint = _entries[submissionEntry - 1].fingerprint;
        theClaim.resubmitDeadline = resubmitBy;
        theClaim.pendingEntry = 0;
        theClaim.reviewDeadline = 0;
        emit ClaimRejected(claimId, submissionEntry, noteEntry, theClaim.resubmitDeadline);
    }

    /// The provider resubmits a rejected claim with NEW evidence; the lines and the
    /// amount stay as first claimed (decision 79). Within the resubmission period only.
    function resubmitClaim(uint256 claimId, bytes32 fingerprint) external returns (uint256 entryNumber) {
        if (msg.sender != provider) revert NotProvider();
        Claim storage theClaim = _existingClaim(claimId);
        if (theClaim.state != ClaimState.Rejected) revert ClaimNotAwaitingResubmission(claimId);
        if (block.timestamp >= theClaim.resubmitDeadline) revert ResubmissionPeriodOver();
        if (fingerprint == theClaim.rejectedFingerprint) revert SameEvidenceAsRejected();

        entryNumber = _addEntry(EntryKind.ClaimSubmission, provider, fingerprint, claimId, 0);
        theClaim.state = ClaimState.PendingReview;
        theClaim.attempts += 1;
        theClaim.pendingEntry = entryNumber;
        theClaim.submittedAt = block.timestamp;
        theClaim.reviewDeadline = block.timestamp + REVIEW_WINDOW;
        theClaim.resubmitDeadline = 0;
        theClaim.rejectedFingerprint = bytes32(0);
        _updateCoverage();
        emit ClaimSubmitted(claimId, entryNumber, theClaim.amount, theClaim.period);
    }

    /// Once the owner's deadline on a claim has passed without a decision, anyone may
    /// trigger payment (decision 63); it always pays the provider.
    function claimClaimOnTimeout(uint256 claimId) external {
        Claim storage theClaim = _existingClaim(claimId);
        if (theClaim.state != ClaimState.PendingReview) revert ClaimNotPendingReview(claimId);
        if (block.timestamp < theClaim.reviewDeadline) revert ReviewStillOpen();
        _payClaim(claimId, ClaimState.PaidOnTimeout);
    }

    /// Anyone may record that a rejected claim lapsed because its resubmission period
    /// ran out (decision 80). This frees its budget.
    function markClaimLapsed(uint256 claimId) external {
        Claim storage theClaim = _existingClaim(claimId);
        if (theClaim.state != ClaimState.Rejected || block.timestamp < theClaim.resubmitDeadline) {
            revert NothingToRecord();
        }
        _lapseClaim(claimId, theClaim.resubmitDeadline);
        _updateCoverage();
    }

    /// Everything kept about claim `claimId`.
    function claim(uint256 claimId) external view returns (Claim memory) {
        return _existingClaim(claimId);
    }

    /// The lines of claim `claimId`.
    function claimLines(uint256 claimId) external view returns (ClaimLine[] memory) {
        _existingClaim(claimId);
        return _claimLines[claimId];
    }

    /// Paid and pending amounts for budget period `period`.
    function periodBudget(uint256 period) external view returns (uint256 paid, uint256 pending) {
        return (_paidInPeriod[period], _pendingInPeriod[period]);
    }

    function _existingClaim(uint256 claimId) internal view returns (Claim storage) {
        if (claimId == 0 || claimId > claimCount) revert NoSuchClaim(claimId);
        return _claims[claimId];
    }

    /// Ends a claim unpaid and frees its reservation from its own period's budget.
    function _lapseClaim(uint256 claimId, uint256 lapsedAt) internal {
        Claim storage theClaim = _claims[claimId];
        theClaim.state = ClaimState.Lapsed;
        _pendingInPeriod[theClaim.period] -= theClaim.amount;
        _totalPending -= theClaim.amount;
        theClaim.pendingEntry = 0;
        theClaim.reviewDeadline = 0;
        theClaim.resubmitDeadline = 0;
        theClaim.rejectedFingerprint = bytes32(0);
        emit ClaimLapsed(claimId, lapsedAt, msg.sender);
    }

    /// Records the claim as paid in its own period, then pays (records first, money last).
    function _payClaim(uint256 claimId, ClaimState outcome) internal {
        Claim storage theClaim = _claims[claimId];
        uint256 amount = theClaim.amount;
        theClaim.state = outcome; // pendingEntry is kept: it shows which submission was paid
        _pendingInPeriod[theClaim.period] -= amount;
        _totalPending -= amount;
        _paidInPeriod[theClaim.period] += amount;

        token.safeTransfer(provider, amount);
        _updateCoverage();
        emit ClaimPaid(claimId, amount, outcome, msg.sender);
    }

    // ------------------------------------------------------------------
    // The passport: unpaid records, reading, verifying
    // ------------------------------------------------------------------

    /// The owner or the provider logs an unpaid record (no review, no payment),
    /// from acceptance until the end date (decision 66).
    function logRecord(RecordType recordType, bytes32 fingerprint) external returns (uint256 number) {
        if (msg.sender != owner && msg.sender != provider) revert NotAParty();
        if (!accepted || block.timestamp >= endDate) revert RecordingNotAllowed();
        _updateCoverage();
        return _addEntry(EntryKind.UnpaidRecord, msg.sender, fingerprint, 0, uint8(recordType));
    }

    /// How many entries the passport holds (entries are numbered 1..entryCount).
    function entryCount() external view returns (uint256) {
        return _entries.length;
    }

    /// Everything about entry `number`.
    function entry(uint256 number) external view returns (Entry memory) {
        if (number == 0 || number > _entries.length) revert NoSuchEntry(number);
        return _entries[number - 1];
    }

    /// Does entry `number` carry exactly this fingerprint? A number that doesn't
    /// exist simply answers false, so anyone can check without risk of an error.
    function verifyRecord(uint256 number, bytes32 candidateFingerprint) external view returns (bool) {
        if (number == 0 || number > _entries.length) return false;
        return _entries[number - 1].fingerprint == candidateFingerprint;
    }

    /// Every entry that used this fingerprint (empty if none) — so a verifier
    /// holding a document needs no entry number.
    function findEntries(bytes32 fingerprint) external view returns (uint256[] memory) {
        return _entriesByFingerprint[fingerprint];
    }

    /// Writes the next entry. Every entry must carry a real fingerprint (decision 69).
    function _addEntry(EntryKind kind, address author, bytes32 fingerprint, uint256 relatesTo, uint8 detail)
        internal
        returns (uint256 number)
    {
        if (fingerprint == bytes32(0)) revert EmptyFingerprint();
        _entries.push(Entry(kind, author, block.timestamp, fingerprint, relatesTo, detail));
        number = _entries.length;
        _entriesByFingerprint[fingerprint].push(number);
        emit EntryAdded(number, kind, author, fingerprint);
    }

    // ------------------------------------------------------------------
    // Reading the price list
    // ------------------------------------------------------------------

    /// Number of items on the price list.
    function priceListLength() external view returns (uint256) {
        return _priceList.length;
    }

    /// One item of the price list, by position (0 = first).
    function priceItem(uint256 index) external view returns (string memory name, uint256 price) {
        PriceItem storage item = _priceList[index];
        return (item.name, item.price);
    }
}
