// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";

contract LaunchTaxAttacksTest is BaseTest {
    /// @dev Splitting one buy into two cannot dodge the tax: the tax is a share of the money paid.
    function test_Attack_SplittingABuyDoesNotReduceTheTax() public {
        address whole = _createTokenWithWindow(weth, 60);
        address split = _createTokenWithWindow(weth, 60);
        uint256 half = 20_000_000e18;

        (, uint256 paidWhole) = _buy(alice, whole, 2 * half);
        (, uint256 paidFirst) = _buy(alice, split, half);
        (, uint256 paidSecond) = _buy(alice, split, half);

        // only per-trade rounding of the base fee can differ (a few wei), never the tax
        assertGe(paidFirst + paidSecond + 100, paidWhole);
    }

    /// @dev A sniper cannot reach the base-fee price by waiting one second less than the window.
    function test_Attack_TaxAtTheEdgeOfTheWindowIsNotBypassed() public {
        uint256 start = block.timestamp;
        address token = _createTokenWithWindow(weth, 600);
        vm.warp(start + 599);
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
        assertGt(fee, cost * TRADE_FEE_BPS / 10_000);
        vm.warp(start + 600);
        (, cost, fee) = curve.previewBuy(token, 1e24);
        assertEq(fee, cost * TRADE_FEE_BPS / 10_000);
    }

    /// @dev Re-running the launch does not restart the clock of an existing curve.
    function test_Attack_LaunchClockIsFixedAtCreation() public {
        uint256 start = block.timestamp;
        address token = _createTokenWithWindow(weth, 60);
        vm.warp(start + 30);
        _createTokenWithWindow(weth, 60); // another launch must not touch this curve
        assertEq(curve.currentLaunchTaxBps(token), 4_900);
        assertEq(curve.getCurve(token).launchTime, start);
    }
}
