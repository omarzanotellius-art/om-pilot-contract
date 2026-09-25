// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {OMPilot} from "../contracts/OMPilot.sol";
import {OMPilotTestBase} from "./helpers/OMPilotTestBase.sol";

/// Stage 2, part 3b — rejection with a reason note, resubmission, and timeout
/// payment triggered by anyone. (Misses and cutoffs: part 4.)
contract OMPilotReworkTest is OMPilotTestBase {
    OMPilot internal c;
    uint256 internal due1;

    // Fingerprints are computed ONCE, when the test contract is created, and stored.
    // (A `constant` would recompute sha256 at every use — and sha256 is itself a call,
    // which would silently use up a vm.prank or vm.expectRevert meant for the next call.)
    bytes32 internal EVIDENCE_1 = sha256("inspection 1 evidence, attempt 1");
    bytes32 internal EVIDENCE_1B = sha256("inspection 1 evidence, attempt 2");
    bytes32 internal NOTE = sha256("rejection note: photo 3 shows a scorched connector");
    uint256 internal constant RATE = 1_500e6;

    function setUp() public override {
        super.setUp();
        c = deployValid();
        due1 = c.startDate() + 182 days;
        vm.prank(luis);
        c.accept(); // entry 1
        mockUsdc.mint(dana, 5_000e6);
        vm.prank(dana);
        usdc.approve(address(c), 5_000e6);
        vm.prank(dana);
        c.deposit(5_000e6);

        vm.warp(due1);
        vm.prank(luis);
        c.submitInspection(EVIDENCE_1, OMPilot.Finding.IssuesFound); // entry 2
    }

    // --- helpers -------------------------------------------------------

    function rejectAsDana(bytes32 note) internal returns (uint256) {
        vm.prank(dana);
        return c.rejectInspection(note);
    }

    function resubmitAsLuis(bytes32 fingerprint) internal returns (uint256) {
        vm.prank(luis);
        return c.submitInspection(fingerprint, OMPilot.Finding.NoIssuesFound);
    }

    function reviewState() internal view returns (OMPilot.ReviewState state) {
        (state,,,) = c.inspectionReview();
    }

    // --- rejecting -----------------------------------------------------

    function test_owner_rejects_with_a_note_that_becomes_its_own_entry() public {
        vm.warp(due1 + 2 days);
        vm.expectEmit(true, false, false, true, address(c));
        emit OMPilot.InspectionRejected(1, 2, 3, due1 + 2 days + 14 days);
        uint256 noteEntry = rejectAsDana(NOTE);

        assertEq(noteEntry, 3);
        OMPilot.Entry memory e = c.entry(3);
        assertEq(uint256(e.kind), uint256(OMPilot.EntryKind.RejectionNote));
        assertEq(e.author, dana);
        assertEq(e.relatesTo, 2); // points to the rejected submission
        assertEq(e.fingerprint, NOTE);

        assertEq(uint256(reviewState()), uint256(OMPilot.ReviewState.Rejected));
        (uint256 resubmitBy, bytes32 rejected) = c.inspectionRework();
        assertEq(resubmitBy, due1 + 2 days + 14 days);
        assertEq(rejected, EVIDENCE_1);
        assertEq(c.balance(), 5_000e6); // nothing paid; the fee stays reserved
    }

    function test_refuses_rejection_without_a_note() public {
        vm.expectRevert(OMPilot.EmptyFingerprint.selector);
        rejectAsDana(bytes32(0));
    }

    function test_refuses_rejection_by_anyone_but_the_owner() public {
        vm.expectRevert(OMPilot.NotOwner.selector);
        vm.prank(luis);
        c.rejectInspection(NOTE);
    }

    function test_refuses_rejection_at_exactly_the_deadline() public {
        vm.warp(due1 + 7 days);
        vm.expectRevert(OMPilot.ReviewDeadlinePassed.selector);
        rejectAsDana(NOTE);
    }

    function test_refuses_rejection_when_nothing_awaits_review() public {
        rejectAsDana(NOTE);
        vm.expectRevert(OMPilot.NotPendingReview.selector);
        rejectAsDana(NOTE);
    }

    // --- resubmitting --------------------------------------------------

    function test_resubmission_works_even_after_the_window_has_closed() public {
        vm.warp(due1 + 6 days); // Dana rejects on day 6 of her review...
        rejectAsDana(NOTE); // ...so Luis may resubmit until day 20
        vm.warp(due1 + 15 days); // the window closed on day 14; still within his 14 days
        uint256 n = resubmitAsLuis(EVIDENCE_1B);

        assertEq(n, 4);
        (OMPilot.ReviewState state, uint256 pending,, uint256 deadline) = c.inspectionReview();
        assertEq(uint256(state), uint256(OMPilot.ReviewState.PendingReview));
        assertEq(pending, 4);
        assertEq(deadline, due1 + 15 days + 7 days); // Dana's clock restarts
    }

    function test_refuses_resubmitting_the_same_evidence() public {
        rejectAsDana(NOTE);
        vm.expectRevert(OMPilot.SameEvidenceAsRejected.selector);
        resubmitAsLuis(EVIDENCE_1);
    }

    function test_refuses_resubmission_at_exactly_the_end_of_the_period() public {
        rejectAsDana(NOTE); // at due1
        vm.warp(due1 + 14 days);
        vm.expectRevert(OMPilot.ResubmissionPeriodOver.selector);
        resubmitAsLuis(EVIDENCE_1B);
    }

    function test_reject_fix_resubmit_confirm() public {
        rejectAsDana(NOTE);
        vm.warp(due1 + 9 days);
        resubmitAsLuis(EVIDENCE_1B); // entry 4
        vm.prank(dana);
        c.confirmInspection();

        assertEq(usdc.balanceOf(luis), RATE);
        OMPilot.InspectionRecord memory r = c.inspectionRecord(1);
        assertEq(uint256(r.outcome), uint256(OMPilot.InspectionOutcome.Confirmed));
        assertEq(r.acceptedEntry, 4);
        assertEq(r.acceptedAt, due1 + 9 days);
        assertEq(uint256(r.finding), uint256(OMPilot.Finding.NoIssuesFound));

        (, uint256 nextDue,,) = c.currentInspectionInfo();
        assertEq(nextDue, due1 + 9 days + 182 days); // counted from the accepted resubmission
        (uint256 resubmitBy, bytes32 rejected) = c.inspectionRework();
        assertEq(resubmitBy, 0); // rework state cleared
        assertEq(rejected, bytes32(0));
    }

    // --- timeout payment -----------------------------------------------

    function test_anyone_can_trigger_payment_once_the_deadline_has_passed() public {
        vm.warp(due1 + 7 days); // Dana stayed silent
        vm.expectEmit(true, true, false, true, address(c));
        emit OMPilot.InspectionPaid(1, RATE, OMPilot.InspectionOutcome.PaidOnTimeout, stranger);
        vm.prank(stranger);
        c.claimInspectionOnTimeout();

        assertEq(usdc.balanceOf(luis), RATE); // always paid to the provider
        assertEq(usdc.balanceOf(stranger), 0);
        assertEq(uint256(c.inspectionRecord(1).outcome), uint256(OMPilot.InspectionOutcome.PaidOnTimeout));
        assertEq(c.currentInspection(), 2);
    }

    function test_owner_can_also_settle_an_overdue_payment() public {
        vm.warp(due1 + 30 days);
        vm.prank(dana);
        c.claimInspectionOnTimeout();
        assertEq(usdc.balanceOf(luis), RATE);
    }

    function test_refuses_timeout_payment_one_second_before_the_deadline() public {
        vm.warp(due1 + 7 days - 1);
        vm.expectRevert(OMPilot.ReviewStillOpen.selector);
        vm.prank(luis);
        c.claimInspectionOnTimeout();
    }

    function test_refuses_timeout_payment_when_nothing_awaits_review() public {
        rejectAsDana(NOTE);
        vm.warp(due1 + 30 days);
        vm.expectRevert(OMPilot.NotPendingReview.selector);
        vm.prank(luis);
        c.claimInspectionOnTimeout();
    }
}
