// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";
import {CurveMath} from "../../contracts/libraries/CurveMath.sol";

/// @dev Anti-sniper launch tax: buys during the creator-chosen window pay a tax that decays
///      linearly from 98% (plus the 1% base fee, about 99% in total) to zero. Sells are never taxed.
abstract contract LaunchTaxTestBase is BaseTest {
    address internal quote;

    function _quoteToken() internal view virtual returns (address);

    function setUp() public virtual override {
        super.setUp();
        quote = _quoteToken();
    }

    function test_CreatePoolStoresWindowAndLaunchTime() public {
        uint256 launchedAt = block.timestamp;
        address token = _createTokenWithWindow(quote, 600);
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        assertEq(c.antiSniperWindow, 600);
        assertEq(c.launchTime, launchedAt);
    }

    function test_EveryPresetWindowIsAccepted() public {
        uint32[4] memory windows = [uint32(0), 60, 600, 5_880];
        for (uint256 i; i < windows.length; ++i) {
            address token = _createTokenWithWindow(quote, windows[i]);
            assertEq(curve.getCurve(token).antiSniperWindow, windows[i]);
        }
    }

    function test_RevertWhen_WindowIsNotAPreset() public {
        uint32[4] memory bad = [uint32(1), 30, 601, 5_881];
        for (uint256 i; i < bad.length; ++i) {
            vm.deal(creator, CREATE_FEE);
            vm.prank(creator);
            vm.expectRevert(VeztaLaunchToken.InvalidAntiSniperWindow.selector);
            factory.deployERC20Token{value: CREATE_FEE}("X", "X", "", quote, bad[i]);
        }
    }

    function test_BuyPaysLaunchTaxAtCreation() public {
        address token = _createTokenWithWindow(quote, 60);
        uint256 amount = 10_000_000e18;
        assertEq(curve.currentLaunchTaxBps(token), 9_800);

        (, uint256 cost, uint256 fee) = curve.previewBuy(token, amount);
        uint256 baseFee = cost * TRADE_FEE_BPS / 10_000;
        uint256 tax = CurveMath.taxOn(cost + baseFee, 9_800);
        assertEq(fee, baseFee + tax);
        assertGt(tax, (cost + baseFee) * 48); // about 49x the price of the tokens

        (, uint256 paid) = _buy(alice, token, amount);
        assertEq(paid, cost + fee);
        assertEq(curve.getCurve(token).realQuoteReserves, cost); // tax never enters the curve
        uint256 creatorPart = fee * CREATOR_FEE_BPS / 10_000;
        assertEq(curve.creatorFees(creator, quote), creatorPart);
        assertEq(curve.accruedQuoteFees(quote), fee - creatorPart);
    }

    function test_TaxDecaysLinearlyAndVanishesAtWindowEnd() public {
        uint256 start = block.timestamp;
        address token = _createTokenWithWindow(quote, 60);
        uint256[5] memory elapsed = [uint256(0), 15, 30, 45, 60];
        uint256[5] memory expected = [uint256(9_800), 7_350, 4_900, 2_450, 0];
        for (uint256 i; i < elapsed.length; ++i) {
            vm.warp(start + elapsed[i]);
            assertEq(curve.currentLaunchTaxBps(token), expected[i]);
        }
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
        assertEq(fee, cost * TRADE_FEE_BPS / 10_000); // base fee only
        vm.warp(start + 100_000);
        assertEq(curve.currentLaunchTaxBps(token), 0);
    }

    function test_TaxIsStillChargedOneSecondBeforeTheWindowEnds() public {
        uint256 start = block.timestamp;
        address token = _createTokenWithWindow(quote, 60);
        vm.warp(start + 59);
        assertEq(curve.currentLaunchTaxBps(token), 163);
        vm.warp(start + 60);
        assertEq(curve.currentLaunchTaxBps(token), 0);
    }

    function test_NoTaxWhenWindowIsZero() public {
        address token = _createTokenWithWindow(quote, 0);
        assertEq(curve.currentLaunchTaxBps(token), 0);
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
        assertEq(fee, cost * TRADE_FEE_BPS / 10_000);
    }

    function test_SellIsNeverTaxed() public {
        address token = _createTokenWithWindow(quote, 600);
        (uint256 out,) = _buy(alice, token, 5_000_000e18);
        (uint256 quoteOut, uint256 fee) = curve.previewSell(token, out);
        assertEq(fee, quoteOut * TRADE_FEE_BPS / 10_000);
        uint256 payout = _sell(alice, token, out);
        assertEq(payout, quoteOut - fee);
    }

    function test_TaxDoesNotChangeCurveMathOrGraduation() public {
        address token = _createTokenWithWindow(quote, 60);
        _buyToCompletion(alice, token);
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        assertTrue(c.complete);
        assertApproxEqAbs(c.realQuoteReserves, _graduationOf(quote), 2);
        curve.migrate(token);
        assertTrue(curve.getCurve(token).migrated);
    }

    function test_MaxQuoteCostProtectsTheBuyerFromTheTax() public {
        uint256 start = block.timestamp;
        address token = _createTokenWithWindow(quote, 60);
        vm.warp(start + 60);
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
        uint256 limit = cost + fee; // quoted after the window, included before it ends
        vm.warp(start + 10);
        _fundQuote(alice, quote, limit * 100);
        vm.startPrank(alice);
        IERC20(quote).approve(address(curve), type(uint256).max);
        vm.expectRevert(VeztaLaunchToken.SlippageExceeded.selector);
        curve.buy(token, 1e24, limit);
        vm.stopPrank();
    }

    function test_CreatorSelfSnipingStillPaysMostOfTheTax() public {
        address token = _createTokenWithWindow(quote, 60);
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 10_000_000e18);
        (, uint256 paid) = _buy(creator, token, 10_000_000e18);
        curve.claimCreatorFees(creator, quote);
        uint256 recovered = IERC20(quote).balanceOf(creator);
        assertEq(recovered, fee * CREATOR_FEE_BPS / 10_000); // only the creator share comes back
        assertGe(paid - recovered, cost + fee - fee / 5);
    }

    function test_TradeEventCarriesTheLaunchTax() public {
        address token = _createTokenWithWindow(quote, 60);
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e18);
        uint256 tax = fee - cost * TRADE_FEE_BPS / 10_000;
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        _fundQuote(alice, quote, (cost + fee) * 2);
        vm.startPrank(alice);
        IERC20(quote).approve(address(curve), type(uint256).max);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.Trade(
            token,
            cost,
            1e18,
            true,
            alice,
            block.timestamp,
            c.virtualQuoteReserves + cost,
            c.virtualTokenReserves - 1e18,
            fee,
            tax
        );
        curve.buy(token, 1e18, type(uint256).max);
        vm.stopPrank();
        assertGt(tax, 0);
    }

    function test_RevertWhen_LaunchTaxQueriedForUnknownToken() public {
        vm.expectRevert(VeztaLaunchToken.CurveNotFound.selector);
        curve.currentLaunchTaxBps(alice);
    }
}

contract LaunchTaxWethTest is LaunchTaxTestBase {
    function _quoteToken() internal view override returns (address) {
        return weth;
    }
}

contract LaunchTaxUsdcTest is LaunchTaxTestBase {
    function _quoteToken() internal view override returns (address) {
        return address(usdc);
    }
}

/// @notice Native-ETH entry point during the tax window.
contract LaunchTaxEthTest is BaseTest {
    function test_BuyWithEthPaysTaxAndRefundsTheExcess() public {
        address token = _createTokenWithWindow(weth, 60);
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
        uint256 total = cost + fee;
        vm.deal(alice, total + 5 ether);
        vm.prank(alice);
        curve.buyWithEth{value: total + 5 ether}(token, 1e24, total);
        assertEq(alice.balance, 5 ether);
        assertEq(curve.getCurve(token).realQuoteReserves, cost);
    }
}
