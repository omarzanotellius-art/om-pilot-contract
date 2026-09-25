// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {OMPilot} from "../contracts/OMPilot.sol";
import {OMPilotTestBase} from "./helpers/OMPilotTestBase.sol";

/// Stage 1, part B — the provider's acceptance and the contract's status.
contract OMPilotAcceptanceTest is OMPilotTestBase {
    OMPilot internal c;

    function setUp() public override {
        super.setUp();
        c = deployValid();
    }

    // --- works ---------------------------------------------------------

    function test_provider_accepts_and_it_is_recorded_and_announced() public {
        vm.expectEmit(true, false, false, true, address(c));
        emit OMPilot.Accepted(luis, c.tenderHash(), NOW);

        vm.prank(luis);
        c.accept();

        assertTrue(c.accepted());
        assertEq(c.acceptedAt(), NOW);
    }

    function test_accepting_one_second_before_start_works() public {
        vm.warp(c.startDate() - 1);
        vm.prank(luis);
        c.accept();
        assertTrue(c.accepted());
    }

    // --- refuses -------------------------------------------------------

    function test_refuses_acceptance_by_owner() public {
        vm.expectRevert(OMPilot.NotProvider.selector);
        vm.prank(dana);
        c.accept();
    }

    function test_refuses_acceptance_by_stranger() public {
        vm.expectRevert(OMPilot.NotProvider.selector);
        vm.prank(stranger);
        c.accept();
    }

    function test_refuses_second_acceptance() public {
        vm.prank(luis);
        c.accept();

        vm.expectRevert(OMPilot.AlreadyAccepted.selector);
        vm.prank(luis);
        c.accept();
    }

    function test_refuses_acceptance_at_exactly_the_start() public {
        vm.warp(c.startDate());
        vm.expectRevert(OMPilot.AcceptanceWindowClosed.selector);
        vm.prank(luis);
        c.accept();
    }

    function test_refuses_acceptance_after_the_start() public {
        vm.warp(c.startDate() + 1 days);
        vm.expectRevert(OMPilot.AcceptanceWindowClosed.selector);
        vm.prank(luis);
        c.accept();
    }

    // --- status --------------------------------------------------------

    function test_status_awaiting_then_accepted_then_active() public {
        assertEq(uint256(c.status()), uint256(OMPilot.Status.AwaitingAcceptance));

        vm.prank(luis);
        c.accept();
        assertEq(uint256(c.status()), uint256(OMPilot.Status.Accepted));

        vm.warp(c.startDate()); // becomes active by the clock alone — no transaction needed
        assertEq(uint256(c.status()), uint256(OMPilot.Status.Active));
    }

    function test_status_never_activated_if_start_passes_without_acceptance() public {
        vm.warp(c.startDate() - 1);
        assertEq(uint256(c.status()), uint256(OMPilot.Status.AwaitingAcceptance));

        vm.warp(c.startDate());
        assertEq(uint256(c.status()), uint256(OMPilot.Status.NeverActivated));
    }
}
