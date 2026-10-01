// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {OMPilot} from "../contracts/OMPilot.sol";
import {OMPilotTestBase} from "./helpers/OMPilotTestBase.sol";

/// Stage 1, part C — the owner's deposits, and what counts as the balance.
contract OMPilotDepositTest is OMPilotTestBase {
    OMPilot internal c;

    function setUp() public override {
        super.setUp();
        c = deployValid();
        mockUsdc.mint(dana, 10_000e6); // Dana starts with 10,000 test USDC
        mockUsdc.mint(stranger, 1_000e6);
    }

    /// The two-step handshake: approve on the token, then deposit on the contract.
    function approveAndDeposit(address who, uint256 amount) internal {
        vm.prank(who);
        usdc.approve(address(c), amount);
        vm.prank(who);
        c.deposit(amount);
    }

    // --- works ---------------------------------------------------------

    function test_owner_deposits_and_balance_rises() public {
        vm.prank(dana);
        usdc.approve(address(c), 3_000e6);

        vm.expectEmit(true, false, false, true, address(c));
        emit OMPilot.Deposited(dana, 3_000e6, 3_000e6);
        vm.prank(dana);
        c.deposit(3_000e6);

        assertEq(c.balance(), 3_000e6);
        assertEq(usdc.balanceOf(dana), 7_000e6);
        assertEq(usdc.allowance(dana, address(c)), 0); // the approval was used up
    }

    function test_deposits_work_in_every_live_status() public {
        approveAndDeposit(dana, 1_000e6); // awaiting acceptance

        vm.prank(luis);
        c.accept();
        approveAndDeposit(dana, 1_000e6); // accepted

        vm.warp(c.startDate());
        approveAndDeposit(dana, 1_000e6); // active

        assertEq(c.balance(), 3_000e6);
    }

    function test_usdc_sent_directly_counts_in_the_balance() public {
        // Anyone can send tokens straight to the contract's address; it can't be prevented.
        // Decision 58: it simply counts as part of the balance (the owner's money).
        approveAndDeposit(dana, 1_000e6);
        vm.prank(stranger);
        usdc.transfer(address(c), 50e6);

        assertEq(c.balance(), 1_050e6);
    }

    // --- refuses -------------------------------------------------------

    function test_refuses_deposit_by_stranger() public {
        vm.prank(stranger);
        usdc.approve(address(c), 100e6);

        vm.expectRevert(OMPilot.NotOwner.selector);
        vm.prank(stranger);
        c.deposit(100e6);
    }

    function test_refuses_deposit_by_provider() public {
        vm.expectRevert(OMPilot.NotOwner.selector);
        vm.prank(luis);
        c.deposit(100e6);
    }

    function test_refuses_zero_deposit() public {
        vm.expectRevert(OMPilot.ZeroAmount.selector);
        vm.prank(dana);
        c.deposit(0);
    }

    function test_deposit_without_approval_is_refused_by_the_token() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(c), 0, 500e6)
        );
        vm.prank(dana);
        c.deposit(500e6);
    }

    function test_deposit_above_approval_is_refused_by_the_token() public {
        vm.prank(dana);
        usdc.approve(address(c), 100e6);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(c), 100e6, 101e6)
        );
        vm.prank(dana);
        c.deposit(101e6);
    }

    function test_refuses_deposit_into_never_activated_contract() public {
        vm.warp(c.startDate()); // the start passed without acceptance
        vm.prank(dana);
        usdc.approve(address(c), 100e6);

        vm.expectRevert(OMPilot.ContractNeverActivated.selector);
        vm.prank(dana);
        c.deposit(100e6);
    }
}
