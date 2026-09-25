// SPDX-License-Identifier: UNLICENSED
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
///      moving on to the next inspection.
///      Still to come in Stage 2: rejection, resubmission and timeout payment (3b),
///      misses, repair claims, and end of term (which completes the lock).
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
        NeverActivated // start date reached without acceptance
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
        PendingReview // a submission awaits the owner's decision
    }

    /// How a finished inspection ended.
    enum InspectionOutcome {
        None, // not finished
        Confirmed // the owner confirmed it and the provider was paid
    }

    /// What is kept about each finished inspection.
    struct InspectionRecord {
        InspectionOutcome outcome;
        Finding finding; // the finding of the accepted attempt
        uint256 acceptedAt; // when the accepted attempt was submitted
        uint256 acceptedEntry; // its passport entry number
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
        emit Accepted(provider, tenderHash, block.timestamp);
    }

    /// Where the engagement stands right now (see `Status`).
    function status() public view returns (Status) {
        bool started = block.timestamp >= startDate;
        if (!accepted) return started ? Status.NeverActivated : Status.AwaitingAcceptance;
        return started ? Status.Active : Status.Accepted;
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
        emit Withdrawn(owner, amount, balance());
    }

    // ------------------------------------------------------------------
    // The rolling lock (Stage 1 version)
    // ------------------------------------------------------------------

    /// Money reserved for the provider, which the owner cannot withdraw.
    /// Zero until the provider accepts (decision 53) — so also zero if the
    /// contract never activated. Once accepted: the next inspection's fee plus
    /// the repair budget. (Stage 2 makes this shrink with payments and reset
    /// each budget period.)
    function lockedAmount() public view returns (uint256) {
        if (!accepted) return 0;
        return inspectionRate + repairBudget;
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
    /// bundle and the finding. The window must be open and the fee covered.
    function submitInspection(bytes32 fingerprint, Finding finding) external returns (uint256 entryNumber) {
        if (msg.sender != provider) revert NotProvider();
        if (_review != ReviewState.Open) revert SubmissionNotExpected();
        InspectionPhase phase = _inspectionPhase();
        if (phase != InspectionPhase.WindowOpen) revert WindowNotOpen(phase);
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
            acceptedEntry: _pendingEntry
        });

        // Next inspection: one interval after the accepted submission (§8.3)
        currentInspection = number + 1;
        _currentDue = _pendingSubmittedAt + inspectionInterval;
        _review = ReviewState.Open;
        _pendingEntry = 0;
        _pendingSubmittedAt = 0;
        _reviewDeadline = 0;

        token.safeTransfer(provider, inspectionRate);
        emit InspectionPaid(number, inspectionRate, outcome, msg.sender);
    }

    function _inspectionPhase() internal view returns (InspectionPhase) {
        if (status() == Status.NeverActivated || _currentDue > endDate) return InspectionPhase.NoneScheduled;
        if (block.timestamp < _currentDue) return InspectionPhase.NotYetDue;
        if (block.timestamp < _currentDue + tolerance) return InspectionPhase.WindowOpen;
        return InspectionPhase.WindowClosed;
    }

    // ------------------------------------------------------------------
    // The passport: unpaid records, reading, verifying
    // ------------------------------------------------------------------

    /// The owner or the provider logs an unpaid record (no review, no payment),
    /// from acceptance until the end date (decision 66).
    function logRecord(RecordType recordType, bytes32 fingerprint) external returns (uint256 number) {
        if (msg.sender != owner && msg.sender != provider) revert NotAParty();
        if (!accepted || block.timestamp >= endDate) revert RecordingNotAllowed();
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
