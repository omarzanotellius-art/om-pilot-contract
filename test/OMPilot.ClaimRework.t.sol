// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OMPilot} from "../contracts/OMPilot.sol";
import {OMPilotTestBase} from "./helpers/OMPilotTestBase.sol";

/// Stage 2, part 5b — claim rejection with a note, resubmission with new evidence
/// only (decision 79), the 3-attempt limit (decision 64), timeout payment by anyone,
/// and lapses recorded by anyone (decision 80).
contract OMPilotClaimReworkTest is OMPilotTestBase {
    OMPilot internal c;
    uint256 internal id;
    uint256 internal t0; // when the claim was first submitted
    uint256 internal constant BUDGET = 2_000e6;
    uint256 internal constant AMOUNT = 180e6; // 2 × connector (90)

    // Stored once (not `constant`): sha256 is itself a call — see OMPilot.Rework.t.sol.
    bytes32 internal R1 = sha256("repair evidence, attempt 1");
    bytes32 internal R2 = sha256("repair evidence, attempt 2");
    bytes32 internal R3 = sha256("repair evidence, attempt 3");
    bytes32 internal NOTE = sha256("rejection note");

    function setUp() public override {
        super.setUp();
        c = deployValid();
        vm.prank(luis);
        c.accept(); // entry 1
        mockUsdc.mint(dana, 10_000e6);
        vm.prank(dana);
        usdc.approve(address(c), 10_000e6);
        vm.prank(dana);
        c.deposit(10_000e6);

        t0 = c.startDate() + 1 days;
        vm.warp(t0);
        OMPilot.ClaimLine[] memory lines = new OMPilot.ClaimLine[](1);
        lines[0] = OMPilot.ClaimLine(1, 2);
        vm.prank(luis);
        id = c.submitClaim(lines, R1); // entry 2
    }

    // --- helpers -------------------------------------------------------

    function rejectAsDana() internal returns (uint256) {
        vm.prank(dana);
        return c.rejectClaim(id, NOTE);
    }

    function resubmitAsLuis(bytes32 evidence) internal returns (uint256) {
        vm.prank(luis);
        return c.resubmitClaim(id, evidence);
    }

    function state() internal view returns (OMPilot.ClaimState) {
        return c.claim(id).state;
    }

    // --- rejecting -----------------------------------------------------

    function test_owner_rejects_with_a_note_and_the_money_stays_reserved() public {
        vm.warp(t0 + 2 days);
        uint256 noteEntry = rejectAsDana();

        assertEq(noteEntry, 3);
        assertEq(uint256(c.entry(3).kind), uint256(OMPilot.EntryKind.RejectionNote));
        assertEq(c.entry(3).relatesTo, 2); // points to the rejected submission
        assertEq(uint256(state()), uint256(OMPilot.ClaimState.Rejected));
        assertEq(c.claim(id).resubmitDeadline, t0 + 2 days + 14 days);
        (, uint256 pending) = c.periodBudget(0);
        assertEq(pending, AMOUNT); // still reserved during the rework
        assertEq(c.availableRepairBudget(), BUDGET - AMOUNT);
    }

    function test_refuses_rejection_without_a_note_by_the_provider_or_after_the_deadline() public {
        vm.expectRevert(OMPilot.EmptyFingerprint.selector);
        vm.prank(dana);
        c.rejectClaim(id, bytes32(0));

        vm.expectRevert(OMPilot.NotOwner.selector);
        vm.prank(luis);
        c.rejectClaim(id, NOTE);

        vm.warp(t0 + 7 days);
        vm.expectRevert(OMPilot.ReviewDeadlinePassed.selector);
        rejectAsDana();
    }

    // --- resubmitting --------------------------------------------------

    function test_resubmission_carries_new_evidence_and_keeps_lines_and_amount() public {
        rejectAsDana();
        vm.warp(t0 + 5 days);
        uint256 n = resubmitAsLuis(R2);

        OMPilot.Claim memory cl = c.claim(id);
        assertEq(uint256(cl.state), uint256(OMPilot.ClaimState.PendingReview));
        assertEq(cl.attempts, 2);
        assertEq(cl.amount, AMOUNT); // unchanged (decision 79)
        assertEq(c.claimLines(id)[0].quantity, 2);
        assertEq(cl.pendingEntry, n);
        assertEq(cl.reviewDeadline, t0 + 5 days + 7 days); // Dana's clock restarts
        assertEq(c.entry(n).relatesTo, id);
    }

    function test_refuses_resubmitting_the_same_evidence() public {
        rejectAsDana();
        vm.expectRevert(OMPilot.SameEvidenceAsRejected.selector);
        resubmitAsLuis(R1);
    }

    function test_refuses_resubmission_unless_rejected_or_by_anyone_but_the_provider() public {
        vm.expectRevert(abi.encodeWithSelector(OMPilot.ClaimNotAwaitingResubmission.selector, id));
        resubmitAsLuis(R2); // still under review, not rejected

        rejectAsDana();
        vm.expectRevert(OMPilot.NotProvider.selector);
        vm.prank(dana);
        c.resubmitClaim(id, R2);
    }

    // --- the 3-attempt limit (decision 64) -------------------------------

    function test_the_third_rejection_lapses_the_claim_and_frees_the_budget() public {
        rejectAsDana(); // attempt 1 rejected
        resubmitAsLuis(R2);
        rejectAsDana(); // attempt 2 rejected
        resubmitAsLuis(R3);
        assertEq(c.claim(id).attempts, 3);

        vm.expectEmit(true, true, false, true, address(c));
        emit OMPilot.ClaimLapsed(id, block.timestamp, dana);
        rejectAsDana(); // attempt 3 rejected: final

        assertEq(uint256(state()), uint256(OMPilot.ClaimState.Lapsed));
        (uint256 paid, uint256 pending) = c.periodBudget(0);
        assertEq(paid, 0);
        assertEq(pending, 0);
        assertEq(c.availableRepairBudget(), BUDGET); // budget freed
        assertEq(usdc.balanceOf(luis), 0); // unpaid
    }

    // --- timeout payment -------------------------------------------------

    function test_anyone_can_trigger_payment_after_the_deadline() public {
        vm.warp(t0 + 7 days); // Dana stayed silent
        vm.expectEmit(true, true, false, true, address(c));
        emit OMPilot.ClaimPaid(id, AMOUNT, OMPilot.ClaimState.PaidOnTimeout, stranger);
        vm.prank(stranger);
        c.claimClaimOnTimeout(id);

        assertEq(uint256(state()), uint256(OMPilot.ClaimState.PaidOnTimeout));
        assertEq(usdc.balanceOf(luis), AMOUNT); // always paid to the provider
        assertEq(c.claim(id).pendingEntry, 2); // shows which submission was paid
    }

    function test_refuses_timeout_payment_before_the_deadline() public {
        vm.warp(t0 + 7 days - 1);
        vm.expectRevert(OMPilot.ReviewStillOpen.selector);
        c.claimClaimOnTimeout(id);
    }

    // --- lapse when the resubmission period runs out (decision 80) --------

    function test_anyone_can_record_a_lapse_once_the_period_is_over() public {
        rejectAsDana(); // at t0: Luis may resubmit until t0 + 14 days
        vm.warp(t0 + 14 days);
        vm.expectEmit(true, true, false, true, address(c));
        emit OMPilot.ClaimLapsed(id, t0 + 14 days, stranger);
        vm.prank(stranger);
        c.markClaimLapsed(id);

        assertEq(uint256(state()), uint256(OMPilot.ClaimState.Lapsed));
        assertEq(c.availableRepairBudget(), BUDGET);
    }

    function test_until_the_lapse_is_recorded_the_money_stays_reserved() public {
        rejectAsDana();
        vm.warp(t0 + 30 days); // period over, but nobody recorded the lapse
        (, uint256 pending) = c.periodBudget(0);
        assertEq(pending, AMOUNT); // errs on the side of protecting Luis
    }

    function test_refuses_recording_a_lapse_before_the_period_is_over() public {
        rejectAsDana();
        vm.warp(t0 + 14 days - 1);
        vm.expectRevert(OMPilot.NothingToRecord.selector);
        c.markClaimLapsed(id);
    }

    function test_late_resubmission_says_period_over_and_records_nothing() public {
        rejectAsDana();
        vm.warp(t0 + 14 days);
        vm.expectRevert(OMPilot.ResubmissionPeriodOver.selector);
        resubmitAsLuis(R2);
        assertEq(uint256(state()), uint256(OMPilot.ClaimState.Rejected)); // unchanged
    }
}
