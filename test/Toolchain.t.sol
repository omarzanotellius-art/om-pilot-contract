// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {Test} from "forge-std/src/Test.sol";

/// Stage 0 check: proves the toolchain works before any real code exists.
/// - the pinned compiler (0.8.37) compiles this file,
/// - the Solidity test runner finds and runs it,
/// - the clock can be fast-forwarded, which the timeout, missed-inspection
///   and end-of-term tests will depend on.
contract ToolchainTest is Test {
    function test_clock_can_be_fast_forwarded_by_7_days() public {
        uint256 start = block.timestamp;
        vm.warp(start + 7 days);
        assertEq(block.timestamp, start + 7 days);
    }
}
