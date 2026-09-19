// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";

abstract contract SellTestBase is BaseTest {
    address internal quote;
    address internal token;

    function _quoteToken() internal view virtual returns (address);

    function setUp() public override {
        super.setUp();
        quote = _quoteToken();
        token = _createToken(quote);
        _buy(alice, token, 100_000_000e18);
    }

    function test_SellPaysOutputMinusFee() public {
        (uint256 quoteOut, uint256 fee) = curve.previewSell(token, 40_000_000e18);
        assertEq(fee, quoteOut * TRADE_FEE_BPS / 10_000);
        uint256 payout = _sell(alice, token, 40_000_000e18);
        assertEq(payout, quoteOut - fee);
        assertEq(IERC20(quote).balanceOf(alice), quoteOut - fee);
        assertEq(IERC20(token).balanceOf(alice), 60_000_000e18);
    }

    function test_SellUpdatesReservesAndKeepsRealEqualsVirtualMinusInitial() public {
        VeztaLaunchToken.Curve memory before = curve.getCurve(token);
        (uint256 quoteOut,) = curve.previewSell(token, 40_000_000e18);
        _sell(alice, token, 40_000_000e18);
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);

        assertEq(c.virtualTokenReserves, before.virtualTokenReserves + 40_000_000e18);
        assertEq(c.realTokenReserves, before.realTokenReserves + 40_000_000e18);
        assertEq(c.virtualQuoteReserves, before.virtualQuoteReserves - quoteOut);
        assertEq(c.realQuoteReserves, before.realQuoteReserves - quoteOut);
        assertEq(c.realQuoteReserves, c.virtualQuoteReserves - c.initialVirtualQuoteReserves);
    }

    function test_SellSplitsFeeBetweenCreatorAndPlatform() public {
        uint256 creatorBefore = curve.creatorFees(creator, quote);
        uint256 platformBefore = curve.accruedQuoteFees(quote);
        (, uint256 fee) = curve.previewSell(token, 40_000_000e18);
        _sell(alice, token, 40_000_000e18);
        uint256 creatorPart = fee * CREATOR_FEE_BPS / 10_000;
        assertEq(curve.creatorFees(creator, quote) - creatorBefore, creatorPart);
        assertEq(curve.accruedQuoteFees(quote) - platformBefore, fee - creatorPart);
    }

    function test_SellEmitsTrade() public {
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        (uint256 quoteOut, uint256 fee) = curve.previewSell(token, 1e18);
        vm.startPrank(alice);
        IERC20(token).approve(address(curve), 1e18);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.Trade(
            token, quoteOut, 1e18, false, alice, block.timestamp, c.virtualQuoteReserves - quoteOut, c.virtualTokenReserves + 1e18, fee
        );
        curve.sell(token, 1e18, 0);
        vm.stopPrank();
    }

    function test_SellEverythingBackRestoresInitialVirtualQuoteAtMost() public {
        _sell(alice, token, IERC20(token).balanceOf(alice));
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        assertEq(c.realTokenReserves, SUPPLY);
        assertGe(c.virtualQuoteReserves, c.initialVirtualQuoteReserves); // rounding stays in the curve
    }

    function test_WalletToWalletRecipientCanSellBack() public {
        vm.prank(alice);
        IERC20(token).transfer(bob, 10_000_000e18);
        uint256 payout = _sell(bob, token, 10_000_000e18);
        assertGt(payout, 0);
        assertEq(IERC20(quote).balanceOf(bob), payout);
    }

    function test_RevertWhen_SellBelowMinOutput() public {
        (uint256 quoteOut, uint256 fee) = curve.previewSell(token, 1e24);
        vm.startPrank(alice);
        IERC20(token).approve(address(curve), 1e24);
        vm.expectRevert(VeztaLaunchToken.SlippageExceeded.selector);
        curve.sell(token, 1e24, quoteOut - fee + 1);
        vm.stopPrank();
    }

    function test_RevertWhen_SellZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(VeztaLaunchToken.ZeroAmount.selector);
        curve.sell(token, 0, 0);
        vm.expectRevert(VeztaLaunchToken.ZeroAmount.selector);
        curve.previewSell(token, 0);
    }

    function test_RevertWhen_SellWithoutApproval() public {
        vm.prank(alice);
        vm.expectRevert();
        curve.sell(token, 1e18, 0);
    }

    function test_RevertWhen_SellMoreThanHeld() public {
        vm.startPrank(bob);
        IERC20(token).approve(address(curve), 1e18);
        vm.expectRevert();
        curve.sell(token, 1e18, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_SellAfterComplete() public {
        _buyToCompletion(bob, token);
        vm.startPrank(alice);
        IERC20(token).approve(address(curve), 1e18);
        vm.expectRevert(VeztaLaunchToken.CurveCompleted.selector);
        curve.sell(token, 1e18, 0);
        vm.stopPrank();
    }
}

contract SellWethTest is SellTestBase {
    function _quoteToken() internal view override returns (address) {
        return weth;
    }
}

contract SellUsdcTest is SellTestBase {
    function _quoteToken() internal view override returns (address) {
        return address(usdc);
    }
}

contract SellForEthTest is BaseTest {
    address internal token;

    function setUp() public override {
        super.setUp();
        token = _createToken(weth);
        _buy(alice, token, 100_000_000e18);
    }

    function test_SellForEthPaysNativeEth() public {
        (uint256 quoteOut, uint256 fee) = curve.previewSell(token, 40_000_000e18);
        uint256 ethBefore = alice.balance;
        vm.startPrank(alice);
        IERC20(token).approve(address(curve), 40_000_000e18);
        uint256 payout = curve.sellForEth(token, 40_000_000e18, quoteOut - fee);
        vm.stopPrank();
        assertEq(payout, quoteOut - fee);
        assertEq(alice.balance - ethBefore, quoteOut - fee);
        assertEq(IERC20(weth).balanceOf(alice), 0);
    }

    function test_RevertWhen_SellForEthOnNonWethCurve() public {
        address usdcToken = _createToken(address(usdc));
        _buy(bob, usdcToken, 1e24);
        vm.startPrank(bob);
        IERC20(usdcToken).approve(address(curve), 1e24);
        vm.expectRevert(VeztaLaunchToken.QuoteNotWeth.selector);
        curve.sellForEth(usdcToken, 1e24, 0);
        vm.stopPrank();
    }
}
