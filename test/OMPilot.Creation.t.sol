// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {Test} from "forge-std/src/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OMPilot} from "../contracts/OMPilot.sol";

/// Stage 1, part A — creating the contract with the tender terms.
/// Each rule has a test showing it works and a test showing what it refuses.
contract OMPilotCreationTest is Test {
    address internal dana = makeAddr("dana"); // owner
    address internal luis = makeAddr("luis"); // provider
    IERC20 internal usdc = IERC20(makeAddr("usdc")); // stand-in address; no token needed for part A

    uint256 internal constant NOW = 1_000_000;

    function setUp() public {
        vm.warp(NOW); // a realistic "current time" for the tests
    }

    // --- helpers -------------------------------------------------------

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

    function expectRefusal(OMPilot.Terms memory t, OMPilot.PriceItem[] memory list, bytes memory reason) internal {
        vm.expectRevert(reason);
        deployAsDana(t, list);
    }

    // --- works ---------------------------------------------------------

    function test_valid_terms_are_stored_exactly() public {
        OMPilot.Terms memory t = validTerms();
        OMPilot c = deployAsDana(t, validPriceList());

        assertEq(c.owner(), dana);
        assertEq(c.provider(), luis);
        assertEq(address(c.token()), address(usdc));
        assertEq(c.assetName(), "Jupiter Ridge Solar");
        assertEq(c.tenderHash(), t.tenderHash);
        assertEq(c.startDate(), t.startDate);
        assertEq(c.endDate(), t.endDate);
        assertEq(c.inspectionInterval(), 182 days);
        assertEq(c.tolerance(), 14 days);
        assertEq(c.inspectionRate(), 1_500e6);
        assertEq(c.repairBudget(), 2_000e6);

        assertEq(c.priceListLength(), 4);
        (string memory name, uint256 price) = c.priceItem(2);
        assertEq(name, "Inverter reset visit");
        assertEq(price, 250e6);
    }

    function test_zero_repair_budget_is_allowed() public {
        OMPilot.Terms memory t = validTerms();
        t.repairBudget = 0;
        assertEq(deployAsDana(t, validPriceList()).repairBudget(), 0);
    }

    function test_edge_cases_that_just_pass() public {
        OMPilot.Terms memory t = validTerms();
        t.startDate = NOW + 1; // one second in the future
        t.tolerance = t.inspectionInterval - 1; // just shorter than the interval
        t.endDate = t.startDate + t.inspectionInterval; // term of exactly one interval
        deployAsDana(t, validPriceList());
    }

    // --- refuses -------------------------------------------------------

    function test_refuses_empty_token_address() public {
        OMPilot.Terms memory t = validTerms();
        t.token = IERC20(address(0));
        expectRefusal(t, validPriceList(), abi.encodeWithSelector(OMPilot.ZeroAddress.selector));
    }

    function test_refuses_empty_provider_address() public {
        OMPilot.Terms memory t = validTerms();
        t.provider = address(0);
        expectRefusal(t, validPriceList(), abi.encodeWithSelector(OMPilot.ZeroAddress.selector));
    }

    function test_refuses_owner_as_provider() public {
        OMPilot.Terms memory t = validTerms();
        t.provider = dana;
        expectRefusal(t, validPriceList(), abi.encodeWithSelector(OMPilot.SameOwnerAndProvider.selector));
    }

    function test_refuses_start_date_not_in_future() public {
        OMPilot.Terms memory t = validTerms();
        t.startDate = NOW; // "now" is not in the future
        expectRefusal(t, validPriceList(), abi.encodeWithSelector(OMPilot.StartNotInFuture.selector));
    }

    function test_refuses_end_not_after_start() public {
        OMPilot.Terms memory t = validTerms();
        t.endDate = t.startDate;
        expectRefusal(t, validPriceList(), abi.encodeWithSelector(OMPilot.EndNotAfterStart.selector));
    }

    function test_refuses_zero_interval() public {
        OMPilot.Terms memory t = validTerms();
        t.inspectionInterval = 0;
        expectRefusal(t, validPriceList(), abi.encodeWithSelector(OMPilot.ZeroInterval.selector));
    }

    function test_refuses_zero_tolerance() public {
        OMPilot.Terms memory t = validTerms();
        t.tolerance = 0;
        expectRefusal(t, validPriceList(), abi.encodeWithSelector(OMPilot.InvalidTolerance.selector));
    }

    function test_refuses_tolerance_not_shorter_than_interval() public {
        OMPilot.Terms memory t = validTerms();
        t.tolerance = t.inspectionInterval;
        expectRefusal(t, validPriceList(), abi.encodeWithSelector(OMPilot.InvalidTolerance.selector));
    }

    function test_refuses_term_shorter_than_one_interval() public {
        OMPilot.Terms memory t = validTerms();
        t.endDate = t.startDate + t.inspectionInterval - 1;
        expectRefusal(t, validPriceList(), abi.encodeWithSelector(OMPilot.TermShorterThanInterval.selector));
    }

    function test_refuses_zero_inspection_rate() public {
        OMPilot.Terms memory t = validTerms();
        t.inspectionRate = 0;
        expectRefusal(t, validPriceList(), abi.encodeWithSelector(OMPilot.ZeroRate.selector));
    }

    function test_refuses_empty_price_list() public {
        expectRefusal(validTerms(), new OMPilot.PriceItem[](0), abi.encodeWithSelector(OMPilot.EmptyPriceList.selector));
    }

    function test_refuses_price_item_without_name() public {
        OMPilot.PriceItem[] memory list = validPriceList();
        list[1].name = "";
        expectRefusal(validTerms(), list, abi.encodeWithSelector(OMPilot.InvalidPriceItem.selector, 1));
    }

    function test_refuses_price_item_with_zero_price() public {
        OMPilot.PriceItem[] memory list = validPriceList();
        list[3].price = 0;
        expectRefusal(validTerms(), list, abi.encodeWithSelector(OMPilot.InvalidPriceItem.selector, 3));
    }
}
