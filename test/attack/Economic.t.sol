// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";

abstract contract EconomicTestBase is BaseTest {
    address internal quote;
    address internal token;

    function _quoteToken() internal view virtual returns (address);

    function setUp() public override {
        super.setUp();
        quote = _quoteToken();
        token = _createToken(quote);
    }

    function _roundTrip(address who, uint256 amount) internal returns (uint256 paid, uint256 received) {
        (, paid) = _buy(who, token, amount);
        received = _sell(who, token, amount);
    }

    function test_Attack_DustRoundTripsNeverProfit() public {
        _buy(bob, token, 300_000_000e18); // move the price away from launch
        uint256 totalPaid;
        uint256 totalReceived;
        for (uint256 i = 1; i <= 50; ++i) {
            (uint256 paid, uint256 received) = _roundTrip(alice, i);
            totalPaid += paid;
            totalReceived += received;
        }
        assertLe(totalReceived, totalPaid);
    }

    function test_Attack_DustRoundTripsNeverProfitWithZeroFee() public {
        vm.prank(owner);
        curve.setTradeFeeBps(0);
        _buy(bob, token, 300_000_000e18);
        for (uint256 i = 1; i <= 50; ++i) {
            (uint256 paid, uint256 received) = _roundTrip(alice, i * 7);
            assertLe(received, paid);
        }
    }

    function testFuzz_Attack_RoundTripNeverProfits(uint256 preBuy, uint256 amount, uint256 feeBps) public {
        preBuy = bound(preBuy, 0, SUPPLY - FLOOR - 1);
        amount = bound(amount, 1, SUPPLY - FLOOR - preBuy);
        feeBps = bound(feeBps, 0, 500);
        vm.prank(owner);
        curve.setTradeFeeBps(feeBps);
        if (preBuy > 0) _buy(bob, token, preBuy);
        if (curve.getCurve(token).complete) return;
        (uint256 out, uint256 paid) = _buy(alice, token, amount);
        if (curve.getCurve(token).complete) return; // cannot sell back into a completed curve
        uint256 received = _sell(alice, token, out);
        assertLe(received, paid);
    }

    function test_Attack_SandwichIsBoundedByVictimSlippage() public {
        uint256 victimAmount = 50_000_000e18;
        (, uint256 fairCost, uint256 fairFee) = curve.previewBuy(token, victimAmount);
        uint256 maxCost = (fairCost + fairFee) * 101 / 100; // victim tolerates 1%

        _buy(bob, token, 200_000_000e18); // front-run

        _fundQuote(alice, quote, maxCost);
        vm.startPrank(alice);
        IERC20(quote).approve(address(curve), maxCost);
        vm.expectRevert(VeztaLaunchToken.SlippageExceeded.selector);
        curve.buy(token, victimAmount, maxCost);
        vm.stopPrank();
    }

    function test_Attack_OwnerFeeFrontRunIsCaughtBySlippage() public {
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
        vm.prank(owner);
        curve.setTradeFeeBps(500);
        _fundQuote(alice, quote, cost + fee);
        vm.startPrank(alice);
        IERC20(quote).approve(address(curve), cost + fee);
        vm.expectRevert(VeztaLaunchToken.SlippageExceeded.selector);
        curve.buy(token, 1e24, cost + fee);
        vm.stopPrank();
    }

    function test_Attack_MaxUintBuyCannotOvershootFloor() public {
        _buy(bob, token, 700_000_000e18);
        (uint256 out,) = _buy(alice, token, type(uint256).max);
        assertEq(out, 100_000_000e18);
        assertEq(curve.getCurve(token).realTokenReserves, FLOOR);
    }

    function testFuzz_FeeSplitAlwaysSumsToFee(uint256 amount, uint256 creatorBps) public {
        creatorBps = bound(creatorBps, 0, 5_000);
        vm.prank(owner);
        curve.setCreatorFeeBps(creatorBps);
        address fresh = _createToken(quote);
        amount = bound(amount, 1, SUPPLY - FLOOR);
        (,, uint256 fee) = curve.previewBuy(fresh, amount);
        uint256 creatorBefore = curve.creatorFees(creator, quote);
        uint256 platformBefore = curve.accruedQuoteFees(quote);
        _buy(alice, fresh, amount);
        uint256 creatorPart = curve.creatorFees(creator, quote) - creatorBefore;
        uint256 platformPart = curve.accruedQuoteFees(quote) - platformBefore;
        assertEq(creatorPart + platformPart, fee);
        assertEq(creatorPart, fee * creatorBps / 10_000);
    }

    function test_Attack_CreatorSelfTradingLosesMoney() public {
        uint256 amount = 100_000_000e18;
        (, uint256 paid) = _buy(creator, token, amount);
        uint256 received = _sell(creator, token, amount);
        curve.claimCreatorFees(creator, quote);
        uint256 creatorFeesBack = IERC20(quote).balanceOf(creator) - received;
        assertLt(received + creatorFeesBack, paid);
    }

    function test_ParameterChangesMidCurveDoNotAffectGraduation() public {
        _buy(alice, token, 300_000_000e18);
        vm.startPrank(owner);
        curve.setQuote(quote, 1e24, true);
        curve.setCreatorFeeBps(0);
        curve.setTradeFeeBps(500);
        vm.stopPrank();
        _buyToCompletion(bob, token);
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        assertApproxEqAbs(c.realQuoteReserves, _originalGraduation(), 10); // snapshot kept, not 1e24
        assertEq(c.creatorFeeBps, CREATOR_FEE_BPS);
    }

    function _originalGraduation() internal view returns (uint256) {
        return quote == weth ? WETH_GRADUATION : USDC_GRADUATION;
    }
}

contract EconomicWethTest is EconomicTestBase {
    function _quoteToken() internal view override returns (address) {
        return weth;
    }
}

contract EconomicUsdcTest is EconomicTestBase {
    function _quoteToken() internal view override returns (address) {
        return address(usdc);
    }
}
