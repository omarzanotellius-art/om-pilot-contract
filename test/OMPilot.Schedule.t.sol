// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {OMPilot} from "../contracts/OMPilot.sol";
import {OMPilotTestBase} from "./helpers/OMPilotTestBase.sol";

/// Stage 2, part 2 — the inspection schedule: which inspection is current,
/// when it is due, and whether its window is open.
/// (Moving on to the next inspection arrives with parts 3–4, where inspections
/// can be accepted or missed.)
contract OMPilotScheduleTest is OMPilotTestBase {
    OMPilot internal c;
    uint256 internal due1;
    uint256 internal closes1;

    function setUp() public override {
        super.setUp();
        c = deployValid();
        due1 = c.startDate() + 182 days;
        closes1 = due1 + 14 days;
        vm.prank(luis);
        c.accept();
    }

    function phase() internal view returns (OMPilot.InspectionPhase p) {
        (,,, p) = c.currentInspectionInfo();
    }

    function assertPhase(OMPilot.InspectionPhase expected) internal view {
        assertEq(uint256(phase()), uint256(expected));
    }

    // --- the first inspection ------------------------------------------

    function test_inspection_1_is_due_one_interval_after_the_start() public view {
        (uint256 number, uint256 dueDate, uint256 windowClosesAt, OMPilot.InspectionPhase p) =
            c.currentInspectionInfo();
        assertEq(number, 1);
        assertEq(dueDate, due1);
        assertEq(windowClosesAt, closes1);
        assertEq(uint256(p), uint256(OMPilot.InspectionPhase.NotYetDue));
    }

    // --- window boundaries (decision 72) -------------------------------

    function test_not_yet_due_until_the_due_moment() public {
        vm.warp(due1 - 1);
        assertPhase(OMPilot.InspectionPhase.NotYetDue);
    }

    function test_window_opens_at_the_due_moment() public {
        vm.warp(due1);
        assertPhase(OMPilot.InspectionPhase.WindowOpen);
    }

    function test_window_still_open_one_second_before_it_closes() public {
        vm.warp(closes1 - 1);
        assertPhase(OMPilot.InspectionPhase.WindowOpen);
    }

    function test_window_closed_at_exactly_due_plus_tolerance() public {
        vm.warp(closes1);
        assertPhase(OMPilot.InspectionPhase.WindowClosed);
    }

    // --- no schedule for a contract that never activated ---------------

    function test_none_scheduled_if_never_activated() public {
        OMPilot unaccepted = deployValid(); // nobody accepts this one
        vm.warp(unaccepted.startDate() + 182 days); // would be the due moment
        (,,, OMPilot.InspectionPhase p) = unaccepted.currentInspectionInfo();
        assertEq(uint256(p), uint256(OMPilot.InspectionPhase.NoneScheduled));
    }

    // --- an inspection due exactly on the end date counts (decision 73) -

    function test_term_of_exactly_one_interval_still_has_its_inspection() public {
        OMPilot.Terms memory t = validTerms();
        t.endDate = t.startDate + t.inspectionInterval; // inspection #1 falls due on the end date
        OMPilot shortTerm = deployAsDana(t, validPriceList());
        vm.prank(luis);
        shortTerm.accept();

        vm.warp(t.endDate);
        (, uint256 dueDate,, OMPilot.InspectionPhase p) = shortTerm.currentInspectionInfo();
        assertEq(dueDate, t.endDate);
        assertEq(uint256(p), uint256(OMPilot.InspectionPhase.WindowOpen));
    }
}
