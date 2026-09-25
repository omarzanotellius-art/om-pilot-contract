// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// TEST ONLY — never deployed anywhere real.
/// A stand-in for Circle's USDC on the local simulated chain: a standard
/// token with 6 decimals, plus a `mint` anyone can call to create test money.
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USD Coin (test only)", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
