// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {OMPilot} from "../contracts/OMPilot.sol";
import {OMPilotTestBase} from "./helpers/OMPilotTestBase.sol";

/// Stage 2, part 4a — misses: (a) the window closed with no submission;
/// (b) the resubmission period ran out. The "missed (unfunded)" label, automatic
/// settling, and recording by anyone. (Cutoffs: part 4b.)
contract OMPilotMissesTest is OMPilotTestBase {
    OMPilot internal c;
    uint256 internal due1;
    uint256 internal closes1;
    uint256 internal constant INTERVAL = 182 days;
    uint256 internal constant RATE = 1_500e6;

    // Stored once (not `constant`): sha256 is itself a call — see OMPilot.Rework.t.sol.
    bytes32 internal EVIDENCE_1 = sha256("inspection 1 evidence");
    bytes32 internal EVIDENCE_2 = sha256("inspection 2 evidence");
    bytes32 internal NOTE = sha256("rejection note");
    bytes32 internal VISIT = sha256("site visit notes");

    function setUp() public override {
        super.setUp();
        c = deployValid();
        due1 = c.startDate() + INTERVAL;
        closes1 = due1 + 14 days;
        vm.prank(luis);
        c.accept(); // entry 1
    }

    // --- helpers -------------------------------------------------------

    function fund(uint256 amount) internal {
        mockUsdc.mint(dana, amount);
        vm.prank(dana);
        usdc.approve(address(c), amount);
        vm.prank(dana);
        c.deposit(amount);
    }

    function record(uint256 n) internal view returns (OMPilot.InspectionRecord memory) {
        return c.inspectionRecord(n);
    }

    function assertMissed(uint256 n, OMPilot.MissReason reason) internal view {
        OMPilot.InspectionRecord memory r = record(n);
        assertEq(uint256(r.outcome), uint256(OMPilot.InspectionOutcome.Missed));
        assertEq(uint256(r.missReason), uint256(reason));
    }

    // --- (a) the window closed with no submission ----------------------

    function test_window_miss_recorded_by_anyone() public {
        fund(5_000e6); // covered well before the due date
        vm.warp(closes1);

        vm.expectEmit(true, true, false, true, address(c));
        emit OMPilot.InspectionMissed(1, OMPilot.MissReason.Missed, closes1, stranger);
        vm.prank(stranger);
        uint256 recorded = c.markMissed();

        assertEq(recorded, 1);
        assertMissed(1, OMPilot.MissReason.Missed); // the provider's side
        assertEq(record(1).missedAt, closes1); // when it actually happened
        assertEq(record(1).recordedBy, stranger);
        (uint256 number, uint256 dueDate,,) = c.currentInspectionInfo();
        assertEq(number, 2);
        assertEq(dueDate, due1 + INTERVAL); // counted from the MISSED due date (§8.3)
        assertEq(c.balance(), 5_000e6); // no payment
    }

    function test_refuses_recording_while_the_window_is_still_open() public {
        fund(5_000e6);
        vm.warp(closes1 - 1);
        vm.expectRevert(OMPilot.NothingToRecord.selector);
        c.markMissed();
    }

    function test_refuses_recording_in_a_never_activated_contract() public {
        OMPilot unaccepted = deployValid();
        vm.warp(unaccepted.startDate() + 400 days);
        vm.expectRevert(OMPilot.NothingToRecord.selector);
        unaccepted.markMissed();
    }

    // --- (b) the resubmission period ran out ---------------------------

    function test_resubmission_period_miss() public {
        fund(5_000e6);
        vm.warp(due1);
        vm.prank(luis);
        c.submitInspection(EVIDENCE_1, OMPilot.Finding.NoIssuesFound);
        vm.warp(due1 + 2 days);
        vm.prank(dana);
        c.rejectInspection(NOTE);

        vm.warp(due1 + 2 days + 14 days); // Luis never resubmitted
        vm.prank(dana);
        c.markMissed();

        assertMissed(1, OMPilot.MissReason.Missed);
        assertEq(record(1).missedAt, due1 + 16 days);
        (uint256 resubmitBy, bytes32 rejected) = c.inspectionRework();
        assertEq(resubmitBy, 0); // rework state cleared
        assertEq(rejected, bytes32(0));
        assertEq(c.currentInspection(), 2);
    }

    // --- "missed (unfunded)": the owner's side (decisions 32, 76) ------

    function test_unfunded_when_never_covered() public {
        vm.warp(closes1); // Dana never deposited
        c.markMissed();
        assertMissed(1, OMPilot.MissReason.MissedUnfunded);
    }

    function test_unfunded_when_covered_only_after_the_due_moment() public {
        vm.warp(due1 + 3 days);
        fund(5_000e6); // too late: uncovered at the start of the window
        vm.warp(closes1);
        c.markMissed();
        assertMissed(1, OMPilot.MissReason.MissedUnfunded);
    }

    function test_unfunded_when_coverage_was_used_up_by_the_previous_payment() public {
        fund(RATE); // exactly one inspection's worth
        vm.warp(due1);
        vm.prank(luis);
        c.submitInspection(EVIDENCE_1, OMPilot.Finding.NoIssuesFound);
        vm.prank(dana);
        c.confirmInspection(); // pays 1,500: the balance is now 0

        uint256 due2 = due1 + INTERVAL;
        vm.warp(due2 + 1 days);
        fund(RATE); // topped up after inspection #2 was already due
        vm.warp(due2 + 14 days);
        c.markMissed();
        assertMissed(2, OMPilot.MissReason.MissedUnfunded);
    }

    function test_money_sent_directly_counts_only_once_the_contract_sees_it() public {
        mockUsdc.mint(dana, RATE);
        vm.prank(dana);
        usdc.transfer(address(c), RATE); // bypasses deposit(): the contract doesn't see it
        vm.warp(closes1);
        c.markMissed();
        assertMissed(1, OMPilot.MissReason.MissedUnfunded); // errs on the provider's side
    }

    function test_money_sent_directly_counts_from_the_next_action() public {
        mockUsdc.mint(dana, RATE);
        vm.prank(dana);
        usdc.transfer(address(c), RATE);
        vm.prank(luis);
        c.logRecord(OMPilot.RecordType.SiteVisit, VISIT); // any action: the contract now sees it

        vm.warp(closes1);
        c.markMissed();
        assertMissed(1, OMPilot.MissReason.Missed); // covered before the due moment
    }

    // --- automatic settling (decision 65) ------------------------------

    function test_next_submission_records_the_overdue_miss_automatically() public {
        fund(5_000e6);
        uint256 due2 = due1 + INTERVAL;
        vm.warp(due2); // #1 was never submitted; #2's window is now open

        vm.prank(luis);
        uint256 entryNumber = c.submitInspection(EVIDENCE_2, OMPilot.Finding.NoIssuesFound);

        assertMissed(1, OMPilot.MissReason.Missed);
        assertEq(record(1).recordedBy, luis); // recorded as part of his submission
        assertEq(c.entry(entryNumber).relatesTo, 2); // the submission is for #2
    }

    function test_several_misses_are_recorded_in_one_go_oldest_first() public {
        fund(5_000e6);
        vm.warp(due1 + 2 * INTERVAL + 14 days); // #1, #2 and #3 all overdue
        uint256 recorded = c.markMissed();

        assertEq(recorded, 3);
        assertEq(c.currentInspection(), 4);
        assertEq(record(3).missedAt, due1 + 2 * INTERVAL + 14 days);
    }

    function test_after_the_last_inspection_is_missed_none_are_scheduled() public {
        fund(5_000e6);
        // Terms: 730-day term, 182-day interval → due dates at start + 182, 364, 546, 728
        vm.warp(c.startDate() + 728 days + 14 days);
        assertEq(c.markMissed(), 4);

        (,,, OMPilot.InspectionPhase phase) = c.currentInspectionInfo();
        assertEq(uint256(phase), uint256(OMPilot.InspectionPhase.NoneScheduled));
        vm.expectRevert(OMPilot.NothingToRecord.selector);
        c.markMissed();
    }

    // --- decision 77: a late submission reports the original reason -----

    function test_late_submission_says_window_closed_and_changes_nothing() public {
        fund(5_000e6);
        vm.warp(closes1 + 1 days); // #1's window closed; #2 not yet due
        vm.expectRevert(abi.encodeWithSelector(OMPilot.WindowNotOpen.selector, OMPilot.InspectionPhase.WindowClosed));
        vm.prank(luis);
        c.submitInspection(EVIDENCE_1, OMPilot.Finding.NoIssuesFound);

        assertEq(c.currentInspection(), 1); // the refused transaction recorded nothing
    }
}
