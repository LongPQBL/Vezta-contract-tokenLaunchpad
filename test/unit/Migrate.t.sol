// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";
import {TokenFactory} from "../../contracts/TokenFactory.sol";
import {Token} from "../../contracts/Token.sol";
import {IUniswapV2Factory, IUniswapV2Pair} from "../../contracts/interfaces/IUniswapV2.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

abstract contract MigrateTestBase is BaseTest {
    uint256 internal constant MINIMUM_LIQUIDITY = 1_000; // locked by Uniswap V2 at address(0)
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address internal quote;
    address internal token;

    function _quoteToken() internal view virtual returns (address);

    function setUp() public virtual override {
        super.setUp();
        quote = _quoteToken();
        token = _createToken(quote);
    }

    function _reservesOf(address pair) internal view returns (uint256 quoteReserve, uint256 tokenReserve) {
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        (quoteReserve, tokenReserve) = IUniswapV2Pair(pair).token0() == quote ? (r0, r1) : (r1, r0);
    }

    function test_MigrateSeedsPoolAtLastCurvePriceAndBurnsLp() public {
        _buyToCompletion(alice, token);
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);

        vm.expectEmit(true, true, false, true, address(curve));
        emit VeztaLaunchToken.Migrated(token, c.pair, c.realQuoteReserves, c.realTokenReserves);
        vm.prank(bob); // anyone can migrate
        curve.migrate(token);

        address pair = IUniswapV2Factory(uniFactory).getPair(token, quote);
        assertEq(pair, c.pair);
        (uint256 quoteReserve, uint256 tokenReserve) = _reservesOf(pair);
        assertEq(quoteReserve, c.realQuoteReserves);
        assertEq(tokenReserve, FLOOR);
        assertApproxEqAbs(quoteReserve, _graduationOf(quote), 2);

        // seamless price: last curve price vQ / vT equals pool price quoteReserve / tokenReserve
        assertApproxEqRel(c.virtualQuoteReserves * tokenReserve, quoteReserve * c.virtualTokenReserves, 1e13);

        uint256 lpSupply = IUniswapV2Pair(pair).totalSupply();
        assertEq(IUniswapV2Pair(pair).balanceOf(DEAD), lpSupply - MINIMUM_LIQUIDITY);
        assertEq(IUniswapV2Pair(pair).balanceOf(address(curve)), 0);

        VeztaLaunchToken.Curve memory after_ = curve.getCurve(token);
        assertTrue(after_.migrated);
        assertEq(after_.realQuoteReserves, 0);
        assertEq(after_.realTokenReserves, 0);
        assertEq(IERC20(token).balanceOf(address(curve)), 0);
        assertTrue(Token(token).tradingOpen());
    }

    function test_TransfersToPairAllowedAfterMigrate() public {
        _buyToCompletion(alice, token);
        curve.migrate(token);
        address pair = curve.getCurve(token).pair;
        vm.prank(alice);
        IERC20(token).transfer(pair, 1e18);
    }

    function test_MigrateSucceedsWhenPairWasPreCreatedEmpty() public {
        IUniswapV2Factory(uniFactory).createPair(token, quote);
        _buyToCompletion(alice, token);
        curve.migrate(token);
        (uint256 quoteReserve, uint256 tokenReserve) = _reservesOf(curve.getCurve(token).pair);
        assertApproxEqAbs(quoteReserve, _graduationOf(quote), 2);
        assertEq(tokenReserve, FLOOR);
    }

    function test_Attack_QuoteDonatedToPairAndSyncedDoesNotBreakMigrate() public {
        address pair = IUniswapV2Factory(uniFactory).createPair(token, quote);
        uint256 donation = _graduationOf(quote) / 10;
        _fundQuote(bob, quote, donation);
        vm.prank(bob);
        IERC20(quote).transfer(pair, donation);
        IUniswapV2Pair(pair).sync();

        _buyToCompletion(alice, token);
        uint256 collected = curve.getCurve(token).realQuoteReserves;
        curve.migrate(token);

        (uint256 quoteReserve, uint256 tokenReserve) = _reservesOf(pair);
        assertEq(quoteReserve, collected + donation); // donation only adds to the pool
        assertEq(tokenReserve, FLOOR);
        assertEq(IUniswapV2Pair(pair).balanceOf(bob), 0); // attacker holds no LP
        assertEq(IUniswapV2Pair(pair).balanceOf(DEAD), IUniswapV2Pair(pair).totalSupply() - MINIMUM_LIQUIDITY);
    }

    function test_Attack_TokenCannotReachPairBeforeMigrate() public {
        _buy(bob, token, 1e24);
        address pair = curve.getCurve(token).pair;
        vm.prank(bob);
        vm.expectRevert(Token.TransferToPairLocked.selector);
        IERC20(token).transfer(pair, 1e24);
    }

    function test_RevertWhen_MigrateBeforeComplete() public {
        _buy(alice, token, 1e24);
        vm.expectRevert(VeztaLaunchToken.NotCompleted.selector);
        curve.migrate(token);
    }

    function test_RevertWhen_MigrateTwice() public {
        _buyToCompletion(alice, token);
        curve.migrate(token);
        vm.expectRevert(VeztaLaunchToken.AlreadyMigrated.selector);
        curve.migrate(token);
    }

    function test_RevertWhen_MigrateUnknownToken() public {
        vm.expectRevert(VeztaLaunchToken.CurveNotFound.selector);
        curve.migrate(alice);
    }

    function test_RevertWhen_TradeAfterMigrate() public {
        _buyToCompletion(alice, token);
        curve.migrate(token);
        vm.expectRevert(VeztaLaunchToken.CurveCompleted.selector);
        curve.buy(token, 1, type(uint256).max);
        vm.expectRevert(VeztaLaunchToken.CurveCompleted.selector);
        curve.sell(token, 1, 0);
    }

    function test_MigrateStillWorksAfterQuoteIsDisabled() public {
        _buyToCompletion(alice, token);
        vm.prank(owner);
        curve.setQuote(quote, 0, false);
        curve.migrate(token);
        assertTrue(curve.getCurve(token).migrated);
    }

    function test_Attack_WrongInitCodeHashRevertsAndKeepsFunds() public {
        (VeztaLaunchToken badCurve, TokenFactory badFactory) = _deployLaunchpad(bytes32(uint256(1)));
        uint256 graduation = _graduationOf(quote); // read before prank: prank applies to the next call only
        vm.prank(owner);
        badCurve.setQuote(quote, graduation, true);
        address badToken = _createTokenWith(badFactory, creator, quote);
        _buyOn(badCurve, alice, badToken, type(uint256).max);
        uint256 held = IERC20(quote).balanceOf(address(badCurve));

        vm.expectRevert(VeztaLaunchToken.PairMismatch.selector);
        badCurve.migrate(badToken);

        assertEq(IERC20(quote).balanceOf(address(badCurve)), held);
        assertFalse(badCurve.getCurve(badToken).migrated);
    }
}

contract MigrateWethTest is MigrateTestBase {
    function _quoteToken() internal view override returns (address) {
        return weth;
    }
}

contract MigrateUsdcTest is MigrateTestBase {
    function _quoteToken() internal view override returns (address) {
        return address(usdc);
    }
}

/// @notice A 2-decimal quote at the smallest allowed graduation still graduates at a seamless price.
contract MigrateLowDecimalsTest is MigrateTestBase {
    MockERC20 internal cents;

    function setUp() public override {
        cents = new MockERC20("Cents", "CNT", 2);
        BaseTest.setUp();
        vm.prank(owner);
        curve.setQuote(address(cents), 1_000_000, true); // 10,000.00 CNT
        quote = address(cents);
        token = _createToken(quote);
    }

    function _quoteToken() internal view override returns (address) {
        return address(cents);
    }
}
