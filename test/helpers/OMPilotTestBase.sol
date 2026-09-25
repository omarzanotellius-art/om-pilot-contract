// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {Test} from "forge-std/src/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OMPilot} from "../../contracts/OMPilot.sol";
import {MockUSDC} from "./MockUSDC.sol";

/// Shared setup for all OMPilot tests: the cast, a fixed "now",
/// the test-only stablecoin, valid Jupiter Ridge Solar terms, and deployment as Dana.
abstract contract OMPilotTestBase is Test {
    address internal dana = makeAddr("dana"); // owner
    address internal luis = makeAddr("luis"); // provider
    address internal stranger = makeAddr("stranger");
    MockUSDC internal mockUsdc = new MockUSDC(); // test-only stand-in for USDC (6 decimals)
    IERC20 internal usdc = IERC20(address(mockUsdc));

    uint256 internal constant NOW = 1_000_000;

    function setUp() public virtual {
        vm.warp(NOW); // a realistic "current time" for the tests
    }

    /// Valid terms, based on the Jupiter Ridge Solar story (USDC has 6 decimals).
    function validTerms() internal view returns (OMPilot.Terms memory t) {
        t.provider = luis;
        t.token = usdc;
        t.assetName = "Jupiter Ridge Solar";
        t.tenderHash = sha256("signed tender award");
        t.startDate = NOW + 30 days;
        t.endDate = NOW + 30 days + 730 days;
        t.inspectionInterval = 182 days;
        t.tolerance = 14 days;
        t.inspectionRate = 1_500e6;
        t.repairBudget = 2_000e6;
    }

    function validPriceList() internal pure returns (OMPilot.PriceItem[] memory list) {
        list = new OMPilot.PriceItem[](4);
        list[0] = OMPilot.PriceItem("String fuse replacement", 150e6);
        list[1] = OMPilot.PriceItem("Connector replacement", 90e6);
        list[2] = OMPilot.PriceItem("Inverter reset visit", 250e6);
        list[3] = OMPilot.PriceItem("Combiner breaker replacement", 400e6);
    }

    function deployAsDana(OMPilot.Terms memory t, OMPilot.PriceItem[] memory list) internal returns (OMPilot) {
        vm.prank(dana); // the next call comes from Dana, so she becomes the owner
        return new OMPilot(t, list);
    }

    function deployValid() internal returns (OMPilot) {
        return deployAsDana(validTerms(), validPriceList());
    }
}
