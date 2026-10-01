// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OMPilot} from "../contracts/OMPilot.sol";
import {OMPilotTestBase} from "./helpers/OMPilotTestBase.sol";

/// Stage 2, part 4b — cutoffs: a dispute can't run on into the next inspection.
/// Uses a short schedule (30-day interval, 5-day tolerance) so a dispute reaches
/// the cutoff in a few rounds; the rules are the same as with 182/14 days.
contract OMPilotCutoffsTest is OMPilotTestBase {
    OMPilot internal c;
    uint256 internal due1;
    uint256 internal cutoff1;
    uint256 internal constant INTERVAL = 30 days;
    uint256 internal constant RATE = 1_500e6;

    // Stored once (not `constant`): sha256 is itself a call — see OMPilot.Rework.t.sol.
    bytes32 internal A1 = sha256("attempt 1");
    bytes32 internal A2 = sha256("attempt 2");
    bytes32 internal A3 = sha256("attempt 3");
    bytes32 internal A4 = sha256("attempt 4");
    bytes32 internal NOTE_1 = sha256("note 1");
    bytes32 internal NOTE_2 = sha256("note 2");
    bytes32 internal NOTE_3 = sha256("note 3");
    bytes32 internal NOTE_4 = sha256("note 4");

    function setUp() public override {
        super.setUp();
        OMPilot.Terms memory t = validTerms();
        t.inspectionInterval = INTERVAL;
        t.tolerance = 5 days;
        t.endDate = t.startDate + 365 days;
        c = deployAsDana(t, validPriceList());
        due1 = t.startDate + INTERVAL;
        cutoff1 = due1 + INTERVAL; // when inspection #2 would be due

        vm.prank(luis);
        c.accept();
        mockUsdc.mint(dana, 10_000e6);
        vm.prank(dana);
        usdc.approve(address(c), 10_000e6);
        vm.prank(dana);
        c.deposit(10_000e6);
    }

    // --- helpers -------------------------------------------------------

    function submitAt(uint256 when, bytes32 evidence) internal {
        vm.warp(when);
        vm.prank(luis);
        c.submitInspection(evidence, OMPilot.Finding.NoIssuesFound);
    }

    function rejectAt(uint256 when, bytes32 note) internal {
        vm.warp(when);
        vm.prank(dana);
        c.rejectInspection(note);
    }

    function resubmitBy() internal view returns (uint256 deadline) {
        (deadline,) = c.inspectionRework();
    }

    /// Two rounds of dispute, ending with Dana's rejection on day 25:
    /// Luis's 14 days would run to day 39, but the cutoff is on day 30.
    function disputeUntilDay25() internal {
        submitAt(due1, A1);
        rejectAt(due1 + 6 days, NOTE_1); // 14 days: until day 20 — before the cutoff
        submitAt(due1 + 19 days, A2);
        rejectAt(due1 + 25 days, NOTE_2);
    }

    // --- a cutoff shortens a resubmission period that runs into it ------

    function test_first_rejection_far_from_the_cutoff_gets_the_full_14_days() public {
        submitAt(due1, A1);
        rejectAt(due1 + 6 days, NOTE_1);
        assertEq(resubmitBy(), due1 + 20 days);
    }

    function test_cutoff_shortens_the_resubmission_period() public {
        disputeUntilDay25();
        assertEq(resubmitBy(), cutoff1); // day 30, not day 39
    }

    function test_dispute_unresolved_at_the_cutoff_is_a_miss() public {
        disputeUntilDay25();
        vm.warp(cutoff1); // Luis didn't resubmit in the shortened period
        c.markMissed();

        OMPilot.InspectionRecord memory r = c.inspectionRecord(1);
        assertEq(uint256(r.outcome), uint256(OMPilot.InspectionOutcome.Missed));
        assertEq(uint256(r.missReason), uint256(OMPilot.MissReason.Missed));
        assertEq(r.missedAt, cutoff1);
        (uint256 number, uint256 dueDate,,) = c.currentInspectionInfo();
        assertEq(number, 2);
        assertEq(dueDate, cutoff1); // one interval after the missed due date (decision 78)
    }

    // --- a submission awaiting review at the cutoff is reviewed normally --

    function test_pending_review_across_the_cutoff_is_not_a_miss() public {
        disputeUntilDay25();
        submitAt(due1 + 29 days, A3); // just before the shortened deadline
        vm.warp(cutoff1 + 1 days);
        vm.expectRevert(OMPilot.NothingToRecord.selector);
        c.markMissed();

        vm.prank(dana);
        c.confirmInspection(); // still within her 7 days
        assertEq(uint256(c.inspectionRecord(1).outcome), uint256(OMPilot.InspectionOutcome.Confirmed));
        assertEq(usdc.balanceOf(luis), RATE);
    }

    function test_silence_after_the_cutoff_still_pays_on_timeout() public {
        disputeUntilDay25();
        submitAt(due1 + 29 days, A3);
        vm.warp(due1 + 36 days); // Dana's 7 days ran out, after the cutoff
        vm.prank(stranger);
        c.claimInspectionOnTimeout();
        assertEq(uint256(c.inspectionRecord(1).outcome), uint256(OMPilot.InspectionOutcome.PaidOnTimeout));
        assertEq(usdc.balanceOf(luis), RATE);
    }

    // --- after the cutoff: exactly one more chance, then a final review ---

    function test_rejection_after_the_cutoff_gives_one_full_chance() public {
        disputeUntilDay25();
        submitAt(due1 + 29 days, A3);
        rejectAt(due1 + 31 days, NOTE_3); // after the cutoff

        assertEq(resubmitBy(), due1 + 31 days + 14 days); // full 14 days, not shortened
        (, bool used) = c.inspectionCutoff();
        assertTrue(used);
    }

    function test_the_extra_chance_can_end_in_confirmation() public {
        disputeUntilDay25();
        submitAt(due1 + 29 days, A3);
        rejectAt(due1 + 31 days, NOTE_3);
        submitAt(due1 + 40 days, A4);
        vm.prank(dana);
        c.confirmInspection();

        assertEq(uint256(c.inspectionRecord(1).outcome), uint256(OMPilot.InspectionOutcome.Confirmed));
        (, uint256 nextDue,,) = c.currentInspectionInfo();
        assertEq(nextDue, due1 + 40 days + INTERVAL); // counted from the accepted submission
        (, bool used) = c.inspectionCutoff();
        assertFalse(used); // reset for inspection #2
    }

    function test_second_rejection_after_the_cutoff_is_final() public {
        disputeUntilDay25();
        submitAt(due1 + 29 days, A3);
        rejectAt(due1 + 31 days, NOTE_3); // the one extra chance
        submitAt(due1 + 40 days, A4);
        uint256 entriesBefore = c.entryCount();
        rejectAt(due1 + 42 days, NOTE_4); // final review

        assertEq(c.entryCount(), entriesBefore + 1); // the rejection note is still recorded
        OMPilot.InspectionRecord memory r = c.inspectionRecord(1);
        assertEq(uint256(r.outcome), uint256(OMPilot.InspectionOutcome.Missed));
        assertEq(r.missedAt, due1 + 42 days);
        assertEq(c.currentInspection(), 2);
        assertEq(usdc.balanceOf(luis), 0);
    }

    // --- decision 78: the known consequence of the strict schedule rule ---

    function test_next_inspection_can_already_be_past_its_window() public {
        disputeUntilDay25();
        submitAt(due1 + 29 days, A3);
        rejectAt(due1 + 31 days, NOTE_3);
        submitAt(due1 + 40 days, A4);
        rejectAt(due1 + 42 days, NOTE_4); // #1 missed on day 42

        // #2 was due on day 30 (the cutoff) and its window closed on day 35:
        // it is already past, although Luis could not have submitted it.
        (uint256 number, uint256 dueDate,, OMPilot.InspectionPhase phase) = c.currentInspectionInfo();
        assertEq(number, 2);
        assertEq(dueDate, cutoff1);
        assertEq(uint256(phase), uint256(OMPilot.InspectionPhase.WindowClosed));

        c.markMissed(); // so #2 is recorded as missed straight away
        assertEq(uint256(c.inspectionRecord(2).outcome), uint256(OMPilot.InspectionOutcome.Missed));
    }
}
