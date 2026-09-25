// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {OMPilot} from "../contracts/OMPilot.sol";
import {OMPilotTestBase} from "./helpers/OMPilotTestBase.sol";

/// Stage 2, part 3a — submitting an inspection, the owner confirming, payment,
/// and moving on to the next inspection. (Rejection and timeout: part 3b.)
contract OMPilotInspectionTest is OMPilotTestBase {
    OMPilot internal c;
    uint256 internal due1;

    bytes32 internal constant EVIDENCE_1 = sha256("inspection 1 evidence manifest");
    bytes32 internal constant EVIDENCE_2 = sha256("inspection 2 evidence manifest");
    uint256 internal constant RATE = 1_500e6;

    function setUp() public override {
        super.setUp();
        c = deployValid();
        due1 = c.startDate() + 182 days;
        vm.prank(luis);
        c.accept(); // entry 1
        fund(5_000e6);
    }

    // --- helpers -------------------------------------------------------

    function fund(uint256 amount) internal {
        mockUsdc.mint(dana, amount);
        vm.prank(dana);
        usdc.approve(address(c), amount);
        vm.prank(dana);
        c.deposit(amount);
    }

    function submitAsLuis(bytes32 fingerprint, OMPilot.Finding finding) internal returns (uint256) {
        vm.prank(luis);
        return c.submitInspection(fingerprint, finding);
    }

    function confirmAsDana() internal {
        vm.prank(dana);
        c.confirmInspection();
    }

    function reviewState() internal view returns (OMPilot.ReviewState state) {
        (state,,,) = c.inspectionReview();
    }

    // --- submitting ----------------------------------------------------

    function test_provider_submits_in_the_window_and_it_becomes_an_entry() public {
        vm.warp(due1);
        bytes32 fp = EVIDENCE_1;
        vm.expectEmit(true, false, false, true, address(c));
        emit OMPilot.InspectionSubmitted(1, 2, OMPilot.Finding.IssuesFound);
        uint256 n = submitAsLuis(fp, OMPilot.Finding.IssuesFound);

        assertEq(n, 2); // entry 1 is the acceptance
        OMPilot.Entry memory e = c.entry(2);
        assertEq(uint256(e.kind), uint256(OMPilot.EntryKind.InspectionSubmission));
        assertEq(e.author, luis);
        assertEq(e.relatesTo, 1); // inspection #1
        assertEq(e.detail, uint8(OMPilot.Finding.IssuesFound));

        (OMPilot.ReviewState state, uint256 pending, uint256 submittedAt, uint256 deadline) = c.inspectionReview();
        assertEq(uint256(state), uint256(OMPilot.ReviewState.PendingReview));
        assertEq(pending, 2);
        assertEq(submittedAt, due1);
        assertEq(deadline, due1 + 7 days);
    }

    function test_refuses_submission_by_anyone_but_the_provider() public {
        vm.warp(due1);
        bytes32 fp = EVIDENCE_1;
        vm.expectRevert(OMPilot.NotProvider.selector);
        vm.prank(dana);
        c.submitInspection(fp, OMPilot.Finding.NoIssuesFound);
    }

    function test_refuses_submission_before_the_window_opens() public {
        vm.warp(due1 - 1);
        bytes32 fp = EVIDENCE_1;
        vm.expectRevert(abi.encodeWithSelector(OMPilot.WindowNotOpen.selector, OMPilot.InspectionPhase.NotYetDue));
        submitAsLuis(fp, OMPilot.Finding.NoIssuesFound);
    }

    function test_refuses_submission_once_the_window_has_closed() public {
        vm.warp(due1 + 14 days);
        bytes32 fp = EVIDENCE_1;
        vm.expectRevert(abi.encodeWithSelector(OMPilot.WindowNotOpen.selector, OMPilot.InspectionPhase.WindowClosed));
        submitAsLuis(fp, OMPilot.Finding.NoIssuesFound);
    }

    function test_refuses_submission_with_empty_fingerprint() public {
        vm.warp(due1);
        vm.expectRevert(OMPilot.EmptyFingerprint.selector);
        submitAsLuis(bytes32(0), OMPilot.Finding.NoIssuesFound);
    }

    function test_refuses_submission_when_the_fee_is_not_covered() public {
        OMPilot poor = deployValid();
        vm.prank(luis);
        poor.accept();
        mockUsdc.mint(dana, 1_000e6);
        vm.prank(dana);
        usdc.approve(address(poor), 1_000e6);
        vm.prank(dana);
        poor.deposit(1_000e6); // less than the 1,500 rate

        vm.warp(due1);
        bytes32 fp = EVIDENCE_1;
        vm.expectRevert(abi.encodeWithSelector(OMPilot.InspectionUnfunded.selector, RATE, 1_000e6));
        vm.prank(luis);
        poor.submitInspection(fp, OMPilot.Finding.NoIssuesFound);
    }

    function test_refuses_a_second_submission_while_one_awaits_review() public {
        vm.warp(due1);
        submitAsLuis(EVIDENCE_1, OMPilot.Finding.NoIssuesFound);
        bytes32 fp = EVIDENCE_2;
        vm.expectRevert(OMPilot.SubmissionNotExpected.selector);
        submitAsLuis(fp, OMPilot.Finding.NoIssuesFound);
    }

    // --- confirming and paying -----------------------------------------

    function test_owner_confirms_and_the_provider_is_paid() public {
        vm.warp(due1);
        submitAsLuis(EVIDENCE_1, OMPilot.Finding.IssuesFound);
        vm.warp(due1 + 3 days);

        vm.expectEmit(true, true, false, true, address(c));
        emit OMPilot.InspectionPaid(1, RATE, OMPilot.InspectionOutcome.Confirmed, dana);
        confirmAsDana();

        assertEq(usdc.balanceOf(luis), RATE);
        assertEq(c.balance(), 5_000e6 - RATE);

        OMPilot.InspectionRecord memory r = c.inspectionRecord(1);
        assertEq(uint256(r.outcome), uint256(OMPilot.InspectionOutcome.Confirmed));
        assertEq(uint256(r.finding), uint256(OMPilot.Finding.IssuesFound));
        assertEq(r.acceptedAt, due1);
        assertEq(r.acceptedEntry, 2);
        assertEq(uint256(reviewState()), uint256(OMPilot.ReviewState.Open));
    }

    function test_next_inspection_is_due_one_interval_after_the_accepted_submission() public {
        vm.warp(due1 + 10 days); // Luis submits late in the window
        submitAsLuis(EVIDENCE_1, OMPilot.Finding.NoIssuesFound);
        confirmAsDana();

        (uint256 number, uint256 dueDate,, OMPilot.InspectionPhase phase) = c.currentInspectionInfo();
        assertEq(number, 2);
        assertEq(dueDate, due1 + 10 days + 182 days); // being late pushes the schedule later (§8.3)
        assertEq(uint256(phase), uint256(OMPilot.InspectionPhase.NotYetDue));
    }

    function test_two_full_cycles() public {
        vm.warp(due1);
        submitAsLuis(EVIDENCE_1, OMPilot.Finding.NoIssuesFound);
        confirmAsDana();

        uint256 due2 = due1 + 182 days;
        vm.warp(due2);
        submitAsLuis(EVIDENCE_2, OMPilot.Finding.NoIssuesFound);
        confirmAsDana();

        assertEq(usdc.balanceOf(luis), 2 * RATE);
        assertEq(c.currentInspection(), 3);
        assertEq(uint256(c.inspectionRecord(2).outcome), uint256(OMPilot.InspectionOutcome.Confirmed));
    }

    function test_confirming_one_second_before_the_deadline_works() public {
        vm.warp(due1);
        submitAsLuis(EVIDENCE_1, OMPilot.Finding.NoIssuesFound);
        vm.warp(due1 + 7 days - 1);
        confirmAsDana();
        assertEq(usdc.balanceOf(luis), RATE);
    }

    // --- confirming: refusals ------------------------------------------

    function test_refuses_confirmation_at_exactly_the_deadline() public {
        vm.warp(due1);
        submitAsLuis(EVIDENCE_1, OMPilot.Finding.NoIssuesFound);
        vm.warp(due1 + 7 days); // the deadline is final (decision 61)
        vm.expectRevert(OMPilot.ReviewDeadlinePassed.selector);
        confirmAsDana();
    }

    function test_refuses_confirmation_by_anyone_but_the_owner() public {
        vm.warp(due1);
        submitAsLuis(EVIDENCE_1, OMPilot.Finding.NoIssuesFound);
        vm.expectRevert(OMPilot.NotOwner.selector);
        vm.prank(luis);
        c.confirmInspection();
    }

    function test_refuses_confirmation_when_nothing_awaits_review() public {
        vm.expectRevert(OMPilot.NotPendingReview.selector);
        confirmAsDana();
    }
}
