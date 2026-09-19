// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {LaunchpadHandler} from "./LaunchpadHandler.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";

contract LaunchpadInvariantTest is BaseTest {
    LaunchpadHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new LaunchpadHandler(curve, factory, weth, usdc, owner);
        handler.createToken(0, 0); // one WETH curve
        handler.createToken(1, 1); // one USDC curve
        targetContract(address(handler));
    }

    function invariant_RealQuoteEqualsVirtualMinusInitial() public view {
        for (uint256 i; i < handler.tokenCount(); ++i) {
            VeztaLaunchToken.Curve memory c = curve.getCurve(handler.tokens(i));
            if (c.migrated) continue;
            assertEq(c.realQuoteReserves, c.virtualQuoteReserves - c.initialVirtualQuoteReserves);
        }
    }

    function invariant_RealTokensNeverBelowFloorAndCompleteExactlyAtFloor() public view {
        for (uint256 i; i < handler.tokenCount(); ++i) {
            VeztaLaunchToken.Curve memory c = curve.getCurve(handler.tokens(i));
            if (c.migrated) continue;
            assertGe(c.realTokenReserves, c.floor);
            assertEq(c.complete, c.realTokenReserves == c.floor);
        }
    }

    function invariant_KNeverDecreases() public view {
        assertFalse(handler.kDecreased());
    }

    function invariant_QuoteBalanceCoversReservesAndFees() public view {
        address[2] memory quoteList = [weth, address(usdc)];
        for (uint256 q; q < quoteList.length; ++q) {
            uint256 owed = curve.accruedQuoteFees(quoteList[q]) + curve.totalCreatorFees(quoteList[q]);
            for (uint256 i; i < handler.tokenCount(); ++i) {
                VeztaLaunchToken.Curve memory c = curve.getCurve(handler.tokens(i));
                if (c.quoteToken == quoteList[q] && !c.migrated) owed += c.realQuoteReserves;
            }
            assertGe(IERC20(quoteList[q]).balanceOf(address(curve)), owed);
        }
    }

    function invariant_TokenBalanceCoversReserves() public view {
        for (uint256 i; i < handler.tokenCount(); ++i) {
            address token = handler.tokens(i);
            VeztaLaunchToken.Curve memory c = curve.getCurve(token);
            assertGe(IERC20(token).balanceOf(address(curve)), c.realTokenReserves);
        }
    }

    function invariant_EthBalanceCoversCreateFees() public view {
        assertGe(address(curve).balance, curve.accruedEth());
    }

    function invariant_NoTokenReachesPairBeforeMigrate() public view {
        assertFalse(handler.tokenReachedPairEarly());
    }

    /// @dev Records how much real work each run did, so a vacuous campaign is detectable.
    function afterInvariant() public {
        vm.writeLine(
            "cache/invariant-metrics.txt",
            string.concat(
                vm.toString(handler.successfulBuys()), " ", vm.toString(handler.successfulSells()), " ", vm.toString(handler.migrations())
            )
        );
    }

    function invariant_RoundTripsNeverProfit() public view {
        assertEq(handler.profitableRoundTrips(), 0);
    }
}
