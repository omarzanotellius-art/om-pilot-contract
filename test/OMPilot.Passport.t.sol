// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OMPilot} from "../contracts/OMPilot.sol";
import {OMPilotTestBase} from "./helpers/OMPilotTestBase.sol";

/// Stage 2, part 1 — the passport (one numbered logbook) and unpaid records.
contract OMPilotPassportTest is OMPilotTestBase {
    OMPilot internal c;

    bytes32 internal constant HANDOVER_PHOTOS = sha256("handover site visit photos");
    bytes32 internal constant BASELINE_REPORT = sha256("baseline performance report");

    function setUp() public override {
        super.setUp();
        c = deployValid();
    }

    function acceptAsLuis() internal {
        vm.prank(luis);
        c.accept();
    }

    function logAs(address who, OMPilot.RecordType recordType, bytes32 fingerprint) internal returns (uint256) {
        vm.prank(who);
        return c.logRecord(recordType, fingerprint);
    }

    // --- entry 1: acceptance -------------------------------------------

    function test_passport_is_empty_before_acceptance() public view {
        assertEq(c.entryCount(), 0);
    }

    function test_acceptance_is_entry_1_with_the_tender_fingerprint() public {
        vm.expectEmit(true, true, false, true, address(c));
        emit OMPilot.EntryAdded(1, OMPilot.EntryKind.Acceptance, luis, c.tenderHash());
        acceptAsLuis();

        assertEq(c.entryCount(), 1);
        OMPilot.Entry memory e = c.entry(1);
        assertEq(uint256(e.kind), uint256(OMPilot.EntryKind.Acceptance));
        assertEq(e.author, luis);
        assertEq(e.timestamp, NOW);
        assertEq(e.fingerprint, c.tenderHash());
    }

    // --- unpaid records ------------------------------------------------

    function test_parties_log_records_after_acceptance_before_the_start() public {
        acceptAsLuis();
        uint256 n2 = logAs(luis, OMPilot.RecordType.SiteVisit, HANDOVER_PHOTOS); // handover visit
        uint256 n3 = logAs(dana, OMPilot.RecordType.PerformanceCheck, BASELINE_REPORT);

        assertEq(n2, 2);
        assertEq(n3, 3);
        OMPilot.Entry memory e2 = c.entry(2);
        assertEq(uint256(e2.kind), uint256(OMPilot.EntryKind.UnpaidRecord));
        assertEq(e2.author, luis);
        assertEq(e2.detail, uint8(OMPilot.RecordType.SiteVisit));
        assertEq(c.entry(3).author, dana);
    }

    function test_records_can_be_logged_while_active_until_just_before_the_end() public {
        acceptAsLuis();
        vm.warp(c.endDate() - 1);
        logAs(luis, OMPilot.RecordType.MaintenanceNote, sha256("note"));
        assertEq(c.entryCount(), 2);
    }

    // --- reading, verifying, finding -----------------------------------

    function test_verify_record_answers_true_only_for_the_exact_fingerprint() public {
        acceptAsLuis();
        logAs(luis, OMPilot.RecordType.SiteVisit, HANDOVER_PHOTOS);

        assertTrue(c.verifyRecord(2, HANDOVER_PHOTOS));
        assertFalse(c.verifyRecord(2, sha256("a different document")));
        assertTrue(c.verifyRecord(1, c.tenderHash()));
    }

    function test_verify_record_answers_false_for_entries_that_do_not_exist() public {
        acceptAsLuis();
        assertFalse(c.verifyRecord(0, c.tenderHash()));
        assertFalse(c.verifyRecord(2, c.tenderHash()));
    }

    function test_find_entries_lists_every_use_of_a_fingerprint() public {
        acceptAsLuis();
        logAs(luis, OMPilot.RecordType.SiteVisit, HANDOVER_PHOTOS); // entry 2
        logAs(dana, OMPilot.RecordType.Other, BASELINE_REPORT); // entry 3
        logAs(dana, OMPilot.RecordType.IncidentReport, HANDOVER_PHOTOS); // entry 4, same document again

        uint256[] memory found = c.findEntries(HANDOVER_PHOTOS);
        assertEq(found.length, 2);
        assertEq(found[0], 2);
        assertEq(found[1], 4);
        assertEq(c.findEntries(sha256("never submitted")).length, 0);
    }

    function test_reading_an_entry_that_does_not_exist_is_refused() public {
        vm.expectRevert(abi.encodeWithSelector(OMPilot.NoSuchEntry.selector, 1));
        c.entry(1);
    }

    // --- refuses -------------------------------------------------------

    function test_refuses_record_from_stranger() public {
        acceptAsLuis();
        bytes32 fp = sha256("x"); // computed first: sha256 is itself a call, and must not
        // be the "next call" that expectRevert watches
        vm.expectRevert(OMPilot.NotAParty.selector);
        logAs(stranger, OMPilot.RecordType.Other, fp);
    }

    function test_refuses_record_before_acceptance() public {
        bytes32 fp = sha256("x");
        vm.expectRevert(OMPilot.RecordingNotAllowed.selector);
        logAs(dana, OMPilot.RecordType.SiteVisit, fp);
    }

    function test_refuses_record_in_a_never_activated_contract() public {
        vm.warp(c.startDate());
        bytes32 fp = sha256("x");
        vm.expectRevert(OMPilot.RecordingNotAllowed.selector);
        logAs(dana, OMPilot.RecordType.SiteVisit, fp);
    }

    function test_refuses_record_at_exactly_the_end_date() public {
        acceptAsLuis();
        vm.warp(c.endDate());
        bytes32 fp = sha256("closing visit");
        vm.expectRevert(OMPilot.RecordingNotAllowed.selector);
        logAs(luis, OMPilot.RecordType.SiteVisit, fp);
    }

    function test_refuses_record_with_empty_fingerprint() public {
        acceptAsLuis();
        vm.expectRevert(OMPilot.EmptyFingerprint.selector);
        logAs(luis, OMPilot.RecordType.SiteVisit, bytes32(0));
    }
}
