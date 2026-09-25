// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title OMPilot — an O&M engagement as a smart contract
/// @notice Learning project. Not audited. Testnet only. Not a security token.
/// @dev Stage 1: part A — the tender terms, fixed at creation;
///      part B — the provider's acceptance and the contract's status.
///      Deposits, withdrawals and the lock follow in parts C–D;
///      inspections, repairs and payments in Stage 2.
contract OMPilot {
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

    // ------------------------------------------------------------------
    // Public announcements (events) — readable on the block explorer
    // ------------------------------------------------------------------

    /// The provider accepted exactly these terms (identified by the tender hash).
    event Accepted(address indexed provider, bytes32 tenderHash, uint256 acceptedAt);

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
    // Creation
    // ------------------------------------------------------------------

    /// @param terms the awarded tender terms
    /// @param priceList the repair price list (names and prices)
    constructor(Terms memory terms, PriceItem[] memory priceList) {
        // Parties and token
        if (address(terms.token) == address(0) || terms.provider == address(0)) revert ZeroAddress();
        if (terms.provider == msg.sender) revert SameOwnerAndProvider();

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
        emit Accepted(provider, tenderHash, block.timestamp);
    }

    /// Where the engagement stands right now (see `Status`).
    function status() public view returns (Status) {
        bool started = block.timestamp >= startDate;
        if (!accepted) return started ? Status.NeverActivated : Status.AwaitingAcceptance;
        return started ? Status.Active : Status.Accepted;
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
