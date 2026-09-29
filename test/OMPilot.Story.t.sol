// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {OMPilot} from "../contracts/OMPilot.sol";
import {OMPilotTestBase} from "./helpers/OMPilotTestBase.sol";

/// Stage 2, part 7 — the whole Jupiter Ridge Solar story, end to end, on the
/// realistic schedule: 182-day interval, 14-day tolerance, two-year term,
/// 1,500 per inspection, 2,000 repair budget per period.
/// Dana (Aldermont Energy Holdings) is the owner; Luis (Tavistone Asset Services)
/// the provider. All names are fictional.
contract OMPilotJupiterRidgeStoryTest is OMPilotTestBase {
    OMPilot internal c;
    uint256 internal S; // start date

    // Every document's fingerprint, computed once (see OMPilot.Rework.t.sol for why)
    bytes32 internal HANDOVER_VISIT = sha256("handover site visit: photos and notes");
    bytes32 internal INSPECTION_1A = sha256("inspection 1, attempt 1: evidence manifest");
    bytes32 internal REJECTION_NOTE = sha256("rejection: photo 3 shows a scorched connector");
    bytes32 internal CONNECTOR_REPAIR = sha256("connector replacement x2: evidence");
    bytes32 internal INSPECTION_1B = sha256("inspection 1, attempt 2: evidence manifest");
    bytes32 internal INVERTER_RESET = sha256("inverter reset visit: evidence");
    bytes32 internal PERFORMANCE_CHECK = sha256("performance check: yield analysis");
    bytes32 internal OWNER_VISIT = sha256("owner site visit notes");
    bytes32 internal COMBINER_INCIDENT = sha256("incident: combiner box failure");
    bytes32 internal INSPECTION_3 = sha256("inspection 3: evidence manifest");

    function setUp() public override {
        super.setUp();
        c = deployValid(); // Jupiter Ridge terms; start = now + 30 days, two-year term
        S = c.startDate();
    }

    // --- small helpers (each prank comes right before its call) -----------

    function deposit(uint256 amount) internal {
        mockUsdc.mint(dana, amount);
        vm.prank(dana);
        usdc.approve(address(c), amount);
        vm.prank(dana);
        c.deposit(amount);
    }

    function lines1(uint256 item, uint256 quantity) internal pure returns (OMPilot.ClaimLine[] memory l) {
        l = new OMPilot.ClaimLine[](1);
        l[0] = OMPilot.ClaimLine(item, quantity);
    }

    function test_the_jupiter_ridge_story() public {
        // ---- 1. Signing ------------------------------------------------------
        vm.prank(luis);
        c.accept(); // entry 1: acceptance of the tender (its fingerprint)
        vm.prank(luis);
        c.logRecord(OMPilot.RecordType.SiteVisit, HANDOVER_VISIT); // entry 2: handover visit

        // ---- 2. Funding: 3,000 now; the lock would need 3,500 ------------------
        deposit(3_000e6);
        vm.warp(S + 1 days);
        assertEq(c.availableRepairBudget(), 1_500e6); // the inspection fee comes first
        vm.warp(S + 160 days);
        deposit(2_000e6); // topped up before inspection #1

        // ---- 3. Inspection #1: too early, rejected, repaired, confirmed ---------
        vm.warp(S + 178 days); // four days before the due date
        vm.expectRevert(abi.encodeWithSelector(OMPilot.WindowNotOpen.selector, OMPilot.InspectionPhase.NotYetDue));
        vm.prank(luis);
        c.submitInspection(INSPECTION_1A, OMPilot.Finding.IssuesFound);

        vm.warp(S + 185 days);
        vm.prank(luis);
        c.submitInspection(INSPECTION_1A, OMPilot.Finding.IssuesFound); // entry 3
        vm.warp(S + 189 days);
        vm.prank(dana);
        c.rejectInspection(REJECTION_NOTE); // entry 4

        vm.warp(S + 196 days);
        vm.prank(luis);
        uint256 connectorClaim = c.submitClaim(lines1(1, 2), CONNECTOR_REPAIR); // entry 5: 2 × 90
        vm.warp(S + 197 days);
        vm.prank(luis);
        c.submitInspection(INSPECTION_1B, OMPilot.Finding.NoIssuesFound); // entry 6
        vm.warp(S + 199 days);
        vm.prank(dana);
        c.confirmInspection();
        vm.prank(dana);
        c.confirmClaim(connectorClaim);
        assertEq(usdc.balanceOf(luis), 1_680e6); // 1,500 + 180

        // ---- 4. The inverter trips; Dana is travelling ------------------------
        vm.warp(S + 270 days);
        vm.prank(luis);
        uint256 inverterClaim = c.submitClaim(lines1(2, 1), INVERTER_RESET); // entry 7: 250
        vm.warp(S + 277 days); // 7 days, no decision
        vm.prank(luis);
        c.claimClaimOnTimeout(inverterClaim);
        assertEq(uint256(c.claim(inverterClaim).state), uint256(OMPilot.ClaimState.PaidOnTimeout));

        // ---- 5. Records, and a repair too big for the budget ------------------
        vm.warp(S + 300 days);
        vm.prank(luis);
        c.logRecord(OMPilot.RecordType.PerformanceCheck, PERFORMANCE_CHECK); // entry 8
        vm.warp(S + 310 days);
        vm.prank(dana);
        c.logRecord(OMPilot.RecordType.SiteVisit, OWNER_VISIT); // entry 9
        vm.warp(S + 330 days);
        OMPilot.ClaimLine[] memory combiner = lines1(3, 6); // 6 × 400 = 2,400
        bytes32 fp = COMBINER_INCIDENT;
        vm.expectRevert(abi.encodeWithSelector(OMPilot.ClaimExceedsAvailableBudget.selector, 2_400e6, 1_570e6));
        vm.prank(luis);
        c.submitClaim(combiner, fp); // agreed and paid off-chain instead...
        vm.prank(luis);
        c.logRecord(OMPilot.RecordType.IncidentReport, COMBINER_INCIDENT); // ...but on record: entry 10

        // ---- 6. Inspection #2 missed (snowstorm) --------------------------------
        // Due one interval after the accepted resubmission: day 197 + 182 = day 379
        (uint256 n2, uint256 due2,,) = c.currentInspectionInfo();
        assertEq(n2, 2);
        assertEq(due2, S + 379 days);
        vm.warp(S + 400 days); // window closed on day 393
        vm.prank(dana);
        c.markMissed();
        assertEq(uint256(c.inspectionRecord(2).missReason), uint256(OMPilot.MissReason.Missed)); // funded: Luis's side

        // ---- 7. Inspection #3 --------------------------------------------------
        // Due one interval after the MISSED due date: day 379 + 182 = day 561
        (, uint256 due3,,) = c.currentInspectionInfo();
        assertEq(due3, S + 561 days);
        vm.warp(S + 565 days);
        vm.prank(luis);
        c.submitInspection(INSPECTION_3, OMPilot.Finding.NoIssuesFound); // entry 11
        vm.warp(S + 569 days);
        vm.prank(dana);
        c.confirmInspection();
        (,,, OMPilot.InspectionPhase phase) = c.currentInspectionInfo();
        assertEq(uint256(phase), uint256(OMPilot.InspectionPhase.NoneScheduled)); // day 747 is past the end

        // ---- 8. The end date: nothing open → Closed; Dana withdraws the rest ---
        vm.warp(c.endDate());
        assertEq(uint256(c.status()), uint256(OMPilot.Status.Closed));
        assertEq(c.lockedAmount(), 0);
        uint256 remainder = c.availableToWithdraw();
        vm.prank(dana);
        c.withdraw(remainder);

        assertEq(usdc.balanceOf(luis), 3_430e6); // 1,500 + 180 + 250 + 1,500
        assertEq(usdc.balanceOf(dana), 5_000e6 - 3_430e6); // everything else came back
        assertEq(c.balance(), 0);

        // ---- 9. Two years later: a lender checks the evidence ---------------
        uint256[] memory found = c.findEntries(INSPECTION_1B); // no entry number needed
        assertEq(found.length, 1);
        assertEq(found[0], 6);
        assertTrue(c.verifyRecord(6, INSPECTION_1B));
        assertEq(c.entry(6).author, luis);
        assertEq(c.entry(6).timestamp, S + 197 days);
        assertEq(c.entry(4).relatesTo, 3); // and the rejection that came before it
        assertEq(uint256(c.inspectionRecord(1).outcome), uint256(OMPilot.InspectionOutcome.Confirmed));
        assertEq(c.entryCount(), 11);
    }
}
