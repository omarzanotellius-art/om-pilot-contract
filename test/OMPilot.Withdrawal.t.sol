// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {OMPilot} from "../contracts/OMPilot.sol";
import {OMPilotTestBase} from "./helpers/OMPilotTestBase.sol";

/// Stage 1, part D — withdrawals and the rolling lock (Stage 1 version).
/// With the Jupiter Ridge terms, the lock once accepted is 1,500 + 2,000 = 3,500 USDC.
contract OMPilotWithdrawalTest is OMPilotTestBase {
    OMPilot internal c;
    uint256 internal constant LOCK = 3_500e6;

    function setUp() public override {
        super.setUp();
        c = deployValid();
        mockUsdc.mint(dana, 10_000e6);
    }

    function depositAsDana(uint256 amount) internal {
        vm.prank(dana);
        usdc.approve(address(c), amount);
        vm.prank(dana);
        c.deposit(amount);
    }

    function acceptAsLuis() internal {
        vm.prank(luis);
        c.accept();
    }

    // --- the lock in each status ---------------------------------------

    function test_lock_is_zero_before_acceptance() public {
        depositAsDana(5_000e6);
        assertEq(c.lockedAmount(), 0);
        assertEq(c.availableToWithdraw(), 5_000e6);
    }

    function test_lock_is_rate_plus_budget_once_accepted_and_when_active() public {
        depositAsDana(5_000e6);
        acceptAsLuis();
        assertEq(c.lockedAmount(), LOCK);
        assertEq(c.availableToWithdraw(), 1_500e6);

        vm.warp(c.startDate()); // active
        assertEq(c.lockedAmount(), LOCK);
    }

    function test_lock_is_zero_if_never_activated() public {
        depositAsDana(5_000e6);
        vm.warp(c.startDate()); // start passed without acceptance
        assertEq(uint256(c.status()), uint256(OMPilot.Status.NeverActivated));
        assertEq(c.lockedAmount(), 0);
        assertEq(c.availableToWithdraw(), 5_000e6);
    }

    function test_available_is_zero_when_underfunded() public {
        depositAsDana(3_000e6); // below the 3,500 lock
        acceptAsLuis();
        assertEq(c.availableToWithdraw(), 0);
    }

    // --- withdrawals that work -----------------------------------------

    function test_owner_withdraws_everything_before_acceptance() public {
        depositAsDana(5_000e6);

        vm.expectEmit(true, false, false, true, address(c));
        emit OMPilot.Withdrawn(dana, 5_000e6, 0);
        vm.prank(dana);
        c.withdraw(5_000e6);

        assertEq(c.balance(), 0);
        assertEq(usdc.balanceOf(dana), 10_000e6); // all of it back in her own wallet
    }

    function test_owner_withdraws_exactly_the_unlocked_part_after_acceptance() public {
        depositAsDana(5_000e6);
        acceptAsLuis();

        vm.prank(dana);
        c.withdraw(1_500e6);

        assertEq(c.balance(), LOCK); // exactly the lock remains
        assertEq(c.availableToWithdraw(), 0);
    }

    function test_owner_withdraws_everything_if_never_activated() public {
        depositAsDana(5_000e6);
        vm.warp(c.startDate());

        vm.prank(dana);
        c.withdraw(5_000e6);
        assertEq(usdc.balanceOf(dana), 10_000e6);
    }

    // --- refuses -------------------------------------------------------

    function test_refuses_withdrawal_into_the_lock() public {
        depositAsDana(5_000e6);
        acceptAsLuis();

        vm.expectRevert(abi.encodeWithSelector(OMPilot.WithdrawalExceedsUnlocked.selector, 1_500e6 + 1, 1_500e6));
        vm.prank(dana);
        c.withdraw(1_500e6 + 1); // one unit too much
    }

    function test_refuses_any_withdrawal_when_underfunded() public {
        depositAsDana(3_000e6);
        acceptAsLuis();

        vm.expectRevert(abi.encodeWithSelector(OMPilot.WithdrawalExceedsUnlocked.selector, 1, 0));
        vm.prank(dana);
        c.withdraw(1);
    }

    function test_refuses_withdrawal_by_provider() public {
        depositAsDana(5_000e6);
        vm.expectRevert(OMPilot.NotOwner.selector);
        vm.prank(luis);
        c.withdraw(1_000e6);
    }

    function test_refuses_withdrawal_by_stranger() public {
        depositAsDana(5_000e6);
        vm.expectRevert(OMPilot.NotOwner.selector);
        vm.prank(stranger);
        c.withdraw(1_000e6);
    }

    function test_refuses_zero_withdrawal() public {
        vm.expectRevert(OMPilot.ZeroAmount.selector);
        vm.prank(dana);
        c.withdraw(0);
    }
}
