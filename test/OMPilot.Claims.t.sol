// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OMPilot} from "../contracts/OMPilot.sol";
import {OMPilotTestBase} from "./helpers/OMPilotTestBase.sol";

/// Stage 2, part 5a — repair claims (submit, confirm, pay), budget periods,
/// the full lock (decision 59) and the available budget.
/// Price list: 0 fuse 150 · 1 connector 90 · 2 inverter reset 250 · 3 combiner breaker 400.
/// Budget: 2,000 per 182-day period. Inspection rate: 1,500.
contract OMPilotClaimsTest is OMPilotTestBase {
    OMPilot internal c;
    uint256 internal constant RATE = 1_500e6;
    uint256 internal constant BUDGET = 2_000e6;
    uint256 internal constant INTERVAL = 182 days;

    // Stored once (not `constant`): sha256 is itself a call — see OMPilot.Rework.t.sol.
    bytes32 internal R1 = sha256("repair evidence 1");
    bytes32 internal R2 = sha256("repair evidence 2");

    function setUp() public override {
        super.setUp();
        c = deployValid();
        vm.prank(luis);
        c.accept();
        vm.warp(c.startDate() + 1 days); // Active, budget period 0
    }

    // --- helpers -------------------------------------------------------

    function fund(uint256 amount) internal {
        mockUsdc.mint(dana, amount);
        vm.prank(dana);
        usdc.approve(address(c), amount);
        vm.prank(dana);
        c.deposit(amount);
    }

    function line(uint256 item, uint256 quantity) internal pure returns (OMPilot.ClaimLine[] memory lines) {
        lines = new OMPilot.ClaimLine[](1);
        lines[0] = OMPilot.ClaimLine(item, quantity);
    }

    function claimAsLuis(OMPilot.ClaimLine[] memory lines, bytes32 fingerprint) internal returns (uint256) {
        vm.prank(luis);
        return c.submitClaim(lines, fingerprint);
    }

    function confirmAsDana(uint256 claimId) internal {
        vm.prank(dana);
        c.confirmClaim(claimId);
    }

    // --- submitting ----------------------------------------------------

    function test_provider_claims_and_the_contract_computes_the_amount() public {
        fund(10_000e6);
        vm.expectEmit(true, false, false, true, address(c));
        emit OMPilot.ClaimSubmitted(1, 2, 180e6, 0); // entry 1 is the acceptance
        uint256 id = claimAsLuis(line(1, 2), R1); // 2 × connector (90)

        OMPilot.Claim memory cl = c.claim(id);
        assertEq(uint256(cl.state), uint256(OMPilot.ClaimState.PendingReview));
        assertEq(cl.amount, 180e6);
        assertEq(cl.period, 0);
        assertEq(cl.attempts, 1);
        assertEq(cl.reviewDeadline, block.timestamp + 7 days);
        assertEq(c.claimLines(id)[0].quantity, 2);
        assertEq(c.entry(2).relatesTo, id);
        assertEq(uint256(c.entry(2).kind), uint256(OMPilot.EntryKind.ClaimSubmission));

        (uint256 paid, uint256 pending) = c.periodBudget(0);
        assertEq(paid, 0);
        assertEq(pending, 180e6);
        assertEq(c.availableRepairBudget(), BUDGET - 180e6);
        assertEq(c.lockedAmount(), RATE + BUDGET); // the pending claim sits inside the budget term
    }

    function test_several_claims_can_be_open_at_once() public {
        fund(10_000e6);
        claimAsLuis(line(0, 1), R1); // 150
        claimAsLuis(line(2, 1), R2); // 250
        assertEq(c.claimCount(), 2);
        assertEq(c.availableRepairBudget(), BUDGET - 400e6);
    }

    // --- confirming and paying -----------------------------------------

    function test_owner_confirms_and_the_provider_is_paid() public {
        fund(10_000e6);
        uint256 id = claimAsLuis(line(1, 2), R1);

        vm.expectEmit(true, true, false, true, address(c));
        emit OMPilot.ClaimPaid(id, 180e6, OMPilot.ClaimState.Confirmed, dana);
        confirmAsDana(id);

        assertEq(usdc.balanceOf(luis), 180e6);
        assertEq(uint256(c.claim(id).state), uint256(OMPilot.ClaimState.Confirmed));
        (uint256 paid, uint256 pending) = c.periodBudget(0);
        assertEq(paid, 180e6);
        assertEq(pending, 0);
        assertEq(c.lockedAmount(), RATE + BUDGET - 180e6); // the lock shrinks with payments
        assertEq(c.availableRepairBudget(), BUDGET - 180e6);
    }

    function test_withdrawal_can_not_touch_a_pending_claim() public {
        fund(10_000e6);
        claimAsLuis(line(3, 1), R1); // 400 pending
        assertEq(c.availableToWithdraw(), 10_000e6 - RATE - BUDGET);
        vm.expectRevert(
            abi.encodeWithSelector(OMPilot.WithdrawalExceedsUnlocked.selector, 6_500e6 + 1, 6_500e6)
        );
        vm.prank(dana);
        c.withdraw(6_500e6 + 1);
    }

    // --- underfunded: the inspection comes first ------------------------

    function test_when_underfunded_the_inspection_fee_comes_first() public {
        fund(1_600e6); // covers the 1,500 fee plus only 100
        assertEq(c.availableRepairBudget(), 100e6);
        OMPilot.ClaimLine[] memory fuse = line(0, 1); // 150
        bytes32 fp = R1;
        vm.expectRevert(abi.encodeWithSelector(OMPilot.ClaimExceedsAvailableBudget.selector, 150e6, 100e6));
        vm.prank(luis);
        c.submitClaim(fuse, fp);

        claimAsLuis(line(1, 1), R2); // 90 fits
        assertEq(c.availableRepairBudget(), 10e6);
    }

    // --- budget periods --------------------------------------------------

    function test_budget_resets_at_the_next_period() public {
        fund(10_000e6);
        OMPilot.ClaimLine[] memory big = new OMPilot.ClaimLine[](2);
        big[0] = OMPilot.ClaimLine(3, 4); // 4 × 400
        big[1] = OMPilot.ClaimLine(1, 2); // 2 × 90  → 1,780
        uint256 id = claimAsLuis(big, R1);
        confirmAsDana(id);
        assertEq(c.availableRepairBudget(), 220e6);

        vm.warp(c.startDate() + INTERVAL); // period 1 begins
        assertEq(c.currentPeriod(), 1);
        assertEq(c.availableRepairBudget(), BUDGET); // fresh budget; unused doesn't carry over
        assertEq(c.lockedAmount(), RATE + BUDGET);
    }

    function test_a_claim_pending_across_the_boundary_stays_reserved_and_counts_in_its_own_period() public {
        fund(10_000e6);
        vm.warp(c.startDate() + INTERVAL - 1 days); // last day of period 0
        uint256 id = claimAsLuis(line(3, 1), R1); // 400, period 0

        vm.warp(c.startDate() + INTERVAL + 1 days); // period 1
        assertEq(c.lockedAmount(), RATE + BUDGET + 400e6); // earlier pending claim added on top
        assertEq(c.availableRepairBudget(), BUDGET); // period 1's own budget is untouched

        confirmAsDana(id);
        (uint256 paid0,) = c.periodBudget(0);
        (uint256 paid1,) = c.periodBudget(1);
        assertEq(paid0, 400e6); // paid against the period it belongs to
        assertEq(paid1, 0);
        assertEq(c.lockedAmount(), RATE + BUDGET);
    }

    // --- refusals: submitting --------------------------------------------

    function test_refuses_claims_from_anyone_but_the_provider() public {
        fund(10_000e6);
        OMPilot.ClaimLine[] memory l = line(0, 1);
        bytes32 fp = R1;
        vm.expectRevert(OMPilot.NotProvider.selector);
        vm.prank(dana);
        c.submitClaim(l, fp);
    }

    function test_refuses_claims_before_the_start_and_from_the_end_date() public {
        uint256 later = block.timestamp;
        vm.warp(NOW); // create the second contract at the usual "now", so its start is in the future
        OMPilot early = deployValid();
        vm.prank(luis);
        early.accept(); // accepted, but the start date hasn't come
        OMPilot.ClaimLine[] memory l = line(0, 1);
        bytes32 fp = R1;
        vm.expectRevert(OMPilot.ClaimsNotAllowed.selector);
        vm.prank(luis);
        early.submitClaim(l, fp);

        vm.warp(later);
        vm.warp(c.endDate());
        vm.expectRevert(OMPilot.ClaimsNotAllowed.selector);
        vm.prank(luis);
        c.submitClaim(l, fp);
    }

    function test_refuses_no_lines_and_too_many_lines() public {
        fund(10_000e6);
        bytes32 fp = R1;
        OMPilot.ClaimLine[] memory none = new OMPilot.ClaimLine[](0);
        vm.expectRevert(OMPilot.InvalidClaimLines.selector);
        vm.prank(luis);
        c.submitClaim(none, fp);

        OMPilot.ClaimLine[] memory tooMany = new OMPilot.ClaimLine[](21);
        for (uint256 i = 0; i < 21; ++i) {
            tooMany[i] = OMPilot.ClaimLine(1, 1);
        }
        vm.expectRevert(OMPilot.InvalidClaimLines.selector);
        vm.prank(luis);
        c.submitClaim(tooMany, fp);
    }

    function test_refuses_an_item_not_on_the_price_list_or_a_zero_quantity() public {
        fund(10_000e6);
        bytes32 fp = R1;
        OMPilot.ClaimLine[] memory lines = new OMPilot.ClaimLine[](2);
        lines[0] = OMPilot.ClaimLine(1, 1);
        lines[1] = OMPilot.ClaimLine(4, 1); // item 4 doesn't exist (0–3)
        vm.expectRevert(abi.encodeWithSelector(OMPilot.InvalidClaimLine.selector, 1));
        vm.prank(luis);
        c.submitClaim(lines, fp);

        lines[1] = OMPilot.ClaimLine(2, 0); // quantity zero
        vm.expectRevert(abi.encodeWithSelector(OMPilot.InvalidClaimLine.selector, 1));
        vm.prank(luis);
        c.submitClaim(lines, fp);
    }

    function test_refuses_a_claim_above_the_budget() public {
        fund(10_000e6);
        OMPilot.ClaimLine[] memory l = line(3, 6); // 6 × 400 = 2,400 > 2,000
        bytes32 fp = R1;
        vm.expectRevert(abi.encodeWithSelector(OMPilot.ClaimExceedsAvailableBudget.selector, 2_400e6, BUDGET));
        vm.prank(luis);
        c.submitClaim(l, fp);
    }

    function test_refuses_a_claim_with_empty_fingerprint() public {
        fund(10_000e6);
        OMPilot.ClaimLine[] memory l = line(0, 1);
        vm.expectRevert(OMPilot.EmptyFingerprint.selector);
        vm.prank(luis);
        c.submitClaim(l, bytes32(0));
    }

    // --- refusals: confirming --------------------------------------------

    function test_refuses_confirmation_by_anyone_but_the_owner() public {
        fund(10_000e6);
        uint256 id = claimAsLuis(line(0, 1), R1);
        vm.expectRevert(OMPilot.NotOwner.selector);
        vm.prank(luis);
        c.confirmClaim(id);
    }

    function test_refuses_confirmation_at_exactly_the_deadline() public {
        fund(10_000e6);
        uint256 id = claimAsLuis(line(0, 1), R1);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(OMPilot.ReviewDeadlinePassed.selector);
        confirmAsDana(id);
    }

    function test_refuses_confirming_an_unknown_or_already_paid_claim() public {
        fund(10_000e6);
        vm.expectRevert(abi.encodeWithSelector(OMPilot.NoSuchClaim.selector, 1));
        confirmAsDana(1);

        uint256 id = claimAsLuis(line(0, 1), R1);
        confirmAsDana(id);
        vm.expectRevert(abi.encodeWithSelector(OMPilot.ClaimNotPendingReview.selector, id));
        confirmAsDana(id);
    }
}
