// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OMPilot} from "../contracts/OMPilot.sol";
import {OMPilotTestBase} from "./helpers/OMPilotTestBase.sol";

/// Stage 2, part 6 — end of term: Ended (settling) → Closed, the lock released
/// step by step (decision 67), activity after the end date (decision 66), and the
/// end-of-term cutoff (end + 14 days) for inspections and claims (§8.8).
/// Short schedule: 30-day interval, 5-day tolerance, 90-day term. With inspections
/// accepted on their due dates, #3 falls due exactly on the end date (decision 73).
contract OMPilotEndOfTermTest is OMPilotTestBase {
    OMPilot internal c;
    uint256 internal start;
    uint256 internal end;
    uint256 internal constant RATE = 1_500e6;
    uint256 internal constant BUDGET = 2_000e6;

    // Stored once (not `constant`): sha256 is itself a call — see OMPilot.Rework.t.sol.
    bytes32 internal E1 = sha256("inspection 1");
    bytes32 internal E2 = sha256("inspection 2");
    bytes32 internal E3 = sha256("inspection 3");
    bytes32 internal E3B = sha256("inspection 3, attempt 2");
    bytes32 internal R1 = sha256("repair, attempt 1");
    bytes32 internal R2 = sha256("repair, attempt 2");
    bytes32 internal R3 = sha256("repair, attempt 3");
    bytes32 internal NOTE = sha256("rejection note");

    function setUp() public override {
        super.setUp();
        OMPilot.Terms memory t = validTerms();
        t.inspectionInterval = 30 days;
        t.tolerance = 5 days;
        t.endDate = t.startDate + 90 days;
        c = deployAsDana(t, validPriceList());
        start = t.startDate;
        end = t.endDate;

        vm.prank(luis);
        c.accept();
        mockUsdc.mint(dana, 10_000e6);
        vm.prank(dana);
        usdc.approve(address(c), 10_000e6);
        vm.prank(dana);
        c.deposit(10_000e6);
    }

    // --- helpers -------------------------------------------------------

    function inspectAt(uint256 when, bytes32 evidence) internal {
        vm.warp(when);
        vm.prank(luis);
        c.submitInspection(evidence, OMPilot.Finding.NoIssuesFound);
        vm.prank(dana);
        c.confirmInspection();
    }

    /// Inspections #1 and #2 done on their due dates, so #3 is due on the end date.
    function firstTwoInspections() internal {
        inspectAt(start + 30 days, E1);
        inspectAt(start + 60 days, E2);
        (, uint256 due3,,) = c.currentInspectionInfo();
        assertEq(due3, end);
    }

    function claimAt(uint256 when) internal returns (uint256 id) {
        vm.warp(when);
        OMPilot.ClaimLine[] memory lines = new OMPilot.ClaimLine[](1);
        lines[0] = OMPilot.ClaimLine(3, 1); // combiner breaker, 400
        vm.prank(luis);
        id = c.submitClaim(lines, R1);
    }

    function assertStatus(OMPilot.Status expected) internal view {
        assertEq(uint256(c.status()), uint256(expected));
    }

    // --- Ended → Closed ------------------------------------------------

    function test_ended_while_the_last_inspection_is_open_then_closed() public {
        firstTwoInspections();
        vm.warp(end);
        assertStatus(OMPilot.Status.Ended);
        assertEq(c.lockedAmount(), RATE); // only the open inspection's fee

        vm.prank(luis);
        c.submitInspection(E3, OMPilot.Finding.NoIssuesFound); // due on the end date: still allowed
        vm.prank(dana);
        c.confirmInspection();

        assertStatus(OMPilot.Status.Closed);
        assertEq(c.lockedAmount(), 0);
        assertEq(c.availableToWithdraw(), c.balance()); // everything is Dana's again
    }

    function test_unused_budget_is_released_at_the_end_date() public {
        firstTwoInspections();
        vm.warp(end - 1);
        assertEq(c.lockedAmount(), RATE + BUDGET);
        vm.warp(end);
        assertEq(c.lockedAmount(), RATE); // the 2,000 budget released at once
    }

    function test_a_pending_claim_keeps_it_ended_until_resolved() public {
        firstTwoInspections();
        uint256 id = claimAt(end - 1 days);
        inspectAt(end, E3); // last inspection resolved

        assertStatus(OMPilot.Status.Ended);
        assertEq(c.lockedAmount(), 400e6); // only the pending claim
        vm.prank(dana);
        c.confirmClaim(id);
        assertStatus(OMPilot.Status.Closed);
        assertEq(c.lockedAmount(), 0);
    }

    function test_an_unrecorded_miss_keeps_it_ended_until_recorded() public {
        firstTwoInspections();
        vm.warp(end + 5 days); // #3's window closed, nobody recorded the miss
        assertStatus(OMPilot.Status.Ended);
        assertEq(c.lockedAmount(), RATE);

        vm.prank(dana);
        c.markMissed(); // Dana records it to close the account
        assertStatus(OMPilot.Status.Closed);
        assertEq(c.lockedAmount(), 0);
    }

    function test_deposits_and_withdrawals_still_work_after_the_end() public {
        firstTwoInspections();
        vm.warp(end);
        mockUsdc.mint(dana, 100e6);
        vm.prank(dana);
        usdc.approve(address(c), 100e6);
        vm.prank(dana);
        c.deposit(100e6); // allowed after the end date (decision 66)

        uint256 available = c.availableToWithdraw();
        vm.prank(dana);
        c.withdraw(available);
        assertEq(c.balance(), RATE); // exactly the open inspection's fee remains
    }

    // --- the end-of-term cutoff: inspections ----------------------------

    function test_end_cutoff_shortens_an_inspection_resubmission_period() public {
        firstTwoInspections();
        vm.warp(end);
        vm.prank(luis);
        c.submitInspection(E3, OMPilot.Finding.IssuesFound);
        vm.warp(end + 3 days);
        vm.prank(dana);
        c.rejectInspection(NOTE);

        (uint256 resubmitBy,) = c.inspectionRework();
        assertEq(resubmitBy, end + 14 days); // not end + 17 days
    }

    function test_an_inspection_dispute_unresolved_at_the_end_cutoff_is_missed_and_closes() public {
        test_end_cutoff_shortens_an_inspection_resubmission_period();
        vm.warp(end + 14 days);
        c.markMissed();

        OMPilot.InspectionRecord memory r = c.inspectionRecord(3);
        assertEq(uint256(r.outcome), uint256(OMPilot.InspectionOutcome.Missed));
        assertEq(r.missedAt, end + 14 days);
        assertStatus(OMPilot.Status.Closed);
    }

    // --- the end-of-term cutoff: claims ---------------------------------

    function test_end_cutoff_shortens_a_claim_resubmission_period() public {
        firstTwoInspections();
        uint256 id = claimAt(end - 1 days);
        vm.warp(end + 5 days);
        vm.prank(dana);
        c.rejectClaim(id, NOTE);
        assertEq(c.claim(id).resubmitDeadline, end + 14 days); // not end + 19 days
    }

    function test_a_claim_rejected_after_the_end_cutoff_gets_a_full_period_then_ends() public {
        firstTwoInspections();
        uint256 id = claimAt(end - 1 days);
        vm.warp(end + 5 days);
        vm.prank(dana);
        c.rejectClaim(id, NOTE); // attempt 1 rejected (period shortened to end + 14)

        vm.warp(end + 13 days);
        vm.prank(luis);
        c.resubmitClaim(id, R2); // attempt 2, under review across the cutoff
        vm.warp(end + 15 days);
        vm.prank(dana);
        c.rejectClaim(id, NOTE); // after the cutoff: a full 14 days
        assertEq(c.claim(id).resubmitDeadline, end + 15 days + 14 days);

        vm.warp(end + 20 days);
        vm.prank(luis);
        c.resubmitClaim(id, R3); // attempt 3
        vm.warp(end + 21 days);
        vm.prank(dana);
        c.rejectClaim(id, NOTE); // final
        assertEq(uint256(c.claim(id).state), uint256(OMPilot.ClaimState.Lapsed));
        assertEq(c.lockedAmount(), RATE); // only inspection #3's fee is left
    }
}
