// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";
import {TokenFactory} from "../../contracts/TokenFactory.sol";

/// @dev Runs once per quote token (see concrete contracts at the bottom).
abstract contract BuyTestBase is BaseTest {
    address internal quote;
    address internal token;

    function _quoteToken() internal view virtual returns (address);

    function setUp() public override {
        super.setUp();
        quote = _quoteToken();
        token = _createToken(quote);
    }

    function test_BuyChargesCostPlusFeeAndSendsTokens() public {
        uint256 amount = 10_000_000e18;
        (uint256 previewOut, uint256 cost, uint256 fee) = curve.previewBuy(token, amount);
        assertEq(previewOut, amount);
        assertEq(fee, cost * TRADE_FEE_BPS / 10_000);

        (uint256 out, uint256 paid) = _buy(alice, token, amount);

        assertEq(out, amount);
        assertEq(paid, cost + fee);
        assertEq(IERC20(token).balanceOf(alice), amount);
        assertEq(IERC20(quote).balanceOf(alice), 0);
        assertEq(IERC20(quote).balanceOf(address(curve)), cost + fee);
    }

    function test_BuyUpdatesReservesAndKeepsRealEqualsVirtualMinusInitial() public {
        VeztaLaunchToken.Curve memory before = curve.getCurve(token);
        (, uint256 cost,) = curve.previewBuy(token, 5_000_000e18);
        _buy(alice, token, 5_000_000e18);
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);

        assertEq(c.virtualTokenReserves, before.virtualTokenReserves - 5_000_000e18);
        assertEq(c.realTokenReserves, before.realTokenReserves - 5_000_000e18);
        assertEq(c.virtualQuoteReserves, before.virtualQuoteReserves + cost);
        assertEq(c.realQuoteReserves, cost); // curve receives the full pricing amount; fee is separate
        assertEq(c.realQuoteReserves, c.virtualQuoteReserves - c.initialVirtualQuoteReserves);
    }

    function test_BuySplitsFeeBetweenCreatorAndPlatform() public {
        (,, uint256 fee) = curve.previewBuy(token, 50_000_000e18);
        _buy(alice, token, 50_000_000e18);
        uint256 creatorPart = fee * CREATOR_FEE_BPS / 10_000;
        assertEq(curve.creatorFees(creator, quote), creatorPart);
        assertEq(curve.totalCreatorFees(quote), creatorPart);
        assertEq(curve.accruedQuoteFees(quote), fee - creatorPart);
    }

    function test_BuyEmitsTrade() public {
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e18);
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        _fundQuote(alice, quote, cost * 2);
        vm.startPrank(alice);
        IERC20(quote).approve(address(curve), type(uint256).max);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.Trade(
            token, cost, 1e18, true, alice, block.timestamp, c.virtualQuoteReserves + cost, c.virtualTokenReserves - 1e18, fee
        );
        curve.buy(token, 1e18, type(uint256).max);
        vm.stopPrank();
    }

    function test_BuyToCompletionClipsAtFloorAndCompletes() public {
        (uint256 previewOut, uint256 cost, uint256 fee) = curve.previewBuy(token, type(uint256).max);
        assertEq(previewOut, SUPPLY - FLOOR);
        _fundQuote(alice, quote, cost + fee);
        vm.startPrank(alice);
        IERC20(quote).approve(address(curve), cost + fee);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.Complete(alice, token, block.timestamp);
        uint256 out = curve.buy(token, type(uint256).max, cost + fee);
        vm.stopPrank();

        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        assertEq(out, SUPPLY - FLOOR);
        assertEq(c.realTokenReserves, FLOOR);
        assertTrue(c.complete);
        assertApproxEqAbs(c.realQuoteReserves, _graduationOf(quote), 2);
    }

    function test_GraduationAcrossManyBuysCollectsGraduationAmount() public {
        uint256 step = (SUPPLY - FLOOR) / 7;
        for (uint256 i; i < 7; ++i) {
            _buy(i % 2 == 0 ? alice : bob, token, step);
        }
        _buyToCompletion(alice, token);
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        assertTrue(c.complete);
        assertApproxEqAbs(c.realQuoteReserves, _graduationOf(quote), 40); // <= 4 units of rounding per trade
    }

    function test_BuyingExactlyTheRemainingAmountCompletes() public {
        _buy(alice, token, SUPPLY - FLOOR - 1);
        assertFalse(curve.getCurve(token).complete);
        (uint256 out,) = _buy(bob, token, 1);
        assertEq(out, 1);
        assertTrue(curve.getCurve(token).complete);
        assertEq(curve.getCurve(token).realTokenReserves, FLOOR);
    }

    function test_RevertWhen_BuyExceedsMaxQuoteCost() public {
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
        _fundQuote(alice, quote, cost + fee);
        vm.startPrank(alice);
        IERC20(quote).approve(address(curve), cost + fee);
        vm.expectRevert(VeztaLaunchToken.SlippageExceeded.selector);
        curve.buy(token, 1e24, cost + fee - 1);
        vm.stopPrank();
    }

    function test_RevertWhen_BuyZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(VeztaLaunchToken.ZeroAmount.selector);
        curve.buy(token, 0, type(uint256).max);
    }

    function test_RevertWhen_BuyUnknownToken() public {
        vm.prank(alice);
        vm.expectRevert(VeztaLaunchToken.CurveNotFound.selector);
        curve.buy(alice, 1, type(uint256).max);
    }

    function test_RevertWhen_BuyWithoutApproval() public {
        _fundQuote(alice, quote, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        curve.buy(token, 1e18, type(uint256).max);
    }

    function test_RevertWhen_BuyAfterComplete() public {
        _buyToCompletion(alice, token);
        vm.prank(bob);
        vm.expectRevert(VeztaLaunchToken.CurveCompleted.selector);
        curve.buy(token, 1, type(uint256).max);
        vm.expectRevert(VeztaLaunchToken.CurveCompleted.selector);
        curve.previewBuy(token, 1);
    }
}

contract BuyWethTest is BuyTestBase {
    function _quoteToken() internal view override returns (address) {
        return weth;
    }
}

contract BuyUsdcTest is BuyTestBase {
    function _quoteToken() internal view override returns (address) {
        return address(usdc);
    }
}

/// @notice Native-ETH entry point.
contract BuyWithEthTest is BaseTest {
    address internal token;

    function setUp() public override {
        super.setUp();
        token = _createToken(weth);
    }

    function test_BuyWithEthWrapsAndRefundsExcess() public {
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 out = curve.buyWithEth{value: 1 ether}(token, 1e24, cost + fee);

        assertEq(out, 1e24);
        assertEq(alice.balance, 1 ether - cost - fee);
        assertEq(IERC20(weth).balanceOf(address(curve)), cost + fee);
        assertEq(address(curve).balance, curve.accruedEth()); // only create fees stay as native ETH
    }

    function test_BuyWithEthExactValue() public {
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
        vm.deal(alice, cost + fee);
        vm.prank(alice);
        curve.buyWithEth{value: cost + fee}(token, 1e24, cost + fee);
        assertEq(alice.balance, 0);
    }

    function test_BuyWithEthToCompletionRefundsClippedPart() public {
        (uint256 out, uint256 cost, uint256 fee) = curve.previewBuy(token, type(uint256).max);
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 received = curve.buyWithEth{value: 10 ether}(token, type(uint256).max, 10 ether);
        assertEq(received, out);
        assertEq(alice.balance, 10 ether - cost - fee);
        assertTrue(curve.getCurve(token).complete);
    }

    function test_RevertWhen_BuyWithEthInsufficientValue() public {
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(VeztaLaunchToken.InsufficientValue.selector);
        curve.buyWithEth{value: cost + fee - 1}(token, 1e24, type(uint256).max);
    }

    function test_RevertWhen_BuyWithEthSlippage() public {
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(VeztaLaunchToken.SlippageExceeded.selector);
        curve.buyWithEth{value: 1 ether}(token, 1e24, cost + fee - 1);
    }

    function test_ReplacedFactoryCannotCreateButOldCurvesKeepTrading() public {
        address oldToken = _createToken(weth);
        TokenFactory newFactory = new TokenFactory(owner);
        vm.startPrank(owner);
        newFactory.setBondingCurve(address(curve));
        curve.setFactory(address(newFactory));
        vm.stopPrank();

        vm.deal(creator, CREATE_FEE);
        vm.prank(creator);
        vm.expectRevert(VeztaLaunchToken.NotFactory.selector);
        factory.deployERC20Token{value: CREATE_FEE}("Old", "OLD", "", weth);

        _createTokenWith(newFactory, creator, weth);
        _buy(alice, oldToken, 1e24);
        assertEq(IERC20(oldToken).balanceOf(alice), 1e24);
    }

    function test_RevertWhen_BuyWithEthOnNonWethCurve() public {
        address usdcToken = _createToken(address(usdc));
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(VeztaLaunchToken.QuoteNotWeth.selector);
        curve.buyWithEth{value: 1 ether}(usdcToken, 1e18, type(uint256).max);
    }
}
