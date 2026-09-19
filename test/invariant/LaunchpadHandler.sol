// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";
import {TokenFactory} from "../../contracts/TokenFactory.sol";
import {IWETH} from "../../contracts/interfaces/IUniswapV2.sol";

/// @notice Drives random sequences of normal and hostile actions against the launchpad.
///         A reverted action rolls back its ghost updates too, so ghosts only record facts.
contract LaunchpadHandler is Test {
    uint256 internal constant MAX_TOKENS = 6;

    VeztaLaunchToken public immutable curve;
    TokenFactory public immutable factory;
    address public immutable weth;
    MockERC20 public immutable usdc;
    address public immutable owner;

    address[] public tokens;
    address[] internal actors;
    address internal roundTripper = makeAddr("roundTripper");

    mapping(address token => uint256) public lastK;
    bool public kDecreased;
    bool public tokenReachedPairEarly;
    uint256 public profitableRoundTrips;
    uint256 public migrations;
    uint256 public successfulBuys;
    uint256 public successfulSells;

    constructor(VeztaLaunchToken curve_, TokenFactory factory_, address weth_, MockERC20 usdc_, address owner_) {
        curve = curve_;
        factory = factory_;
        weth = weth_;
        usdc = usdc_;
        owner = owner_;
        actors.push(makeAddr("actorA"));
        actors.push(makeAddr("actorB"));
        actors.push(makeAddr("actorC"));
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    // ------------------------------------------------------------------ normal actions

    function createToken(uint256 quoteSeed, uint256 actorSeed) external {
        if (tokens.length >= MAX_TOKENS) return;
        address quote = quoteSeed % 2 == 0 ? weth : address(usdc);
        address actor = _actor(actorSeed);
        uint256 fee = curve.createFee();
        vm.deal(actor, actor.balance + fee);
        vm.prank(actor);
        address token = factory.deployERC20Token{value: fee}("Fuzz", "FZ", "", quote);
        tokens.push(token);
        _recordK(token);
    }

    function buy(uint256 tokenSeed, uint256 actorSeed, uint256 amount, bool useEth) external {
        address token = _token(tokenSeed);
        if (token == address(0)) return;
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        if (c.complete) return;
        amount = bound(amount, 1, (c.realTokenReserves - c.floor) / 4 + 1); // completion comes from buyToCompletion
        _buyAs(_actor(actorSeed), token, amount, useEth);
        successfulBuys++;
        _checkK(token);
    }

    /// @dev Only acts on 1 in 5 calls so curves stay open long enough for two-way trading.
    function buyToCompletion(uint256 tokenSeed, uint256 actorSeed) external {
        if (actorSeed % 5 != 0) return;
        address token = _token(tokenSeed);
        if (token == address(0) || curve.getCurve(token).complete) return;
        _buyAs(_actor(actorSeed), token, type(uint256).max, false);
        successfulBuys++;
        _checkK(token);
    }

    function sell(uint256 tokenSeed, uint256 actorSeed, uint256 amount, bool forEth) external {
        address token = _token(tokenSeed);
        if (token == address(0) || curve.getCurve(token).complete) return;
        address actor = _holder(token, actorSeed);
        if (actor == address(0)) return;
        uint256 held = IERC20(token).balanceOf(actor);
        amount = bound(amount, 1, held);
        bool ethExit = forEth && curve.getCurve(token).quoteToken == weth;
        vm.startPrank(actor);
        IERC20(token).approve(address(curve), amount);
        if (ethExit) curve.sellForEth(token, amount, 0);
        else curve.sell(token, amount, 0);
        vm.stopPrank();
        successfulSells++;
        _checkK(token);
    }

    /// @dev Acts like the migrate bot: migrates the first completed, unmigrated curve it finds.
    function migrate(uint256 tokenSeed) external {
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[(tokenSeed + i) % tokens.length];
            VeztaLaunchToken.Curve memory c = curve.getCurve(token);
            if (c.complete && !c.migrated) {
                curve.migrate(token);
                migrations++;
                return;
            }
        }
    }

    function claimAll(uint256 seed) external {
        address quote = seed % 2 == 0 ? weth : address(usdc);
        if (curve.accruedQuoteFees(quote) > 0) curve.claimFees(quote);
        if (curve.accruedEth() > 0) curve.claimCreateFees();
        for (uint256 i; i < actors.length; ++i) {
            if (curve.creatorFees(actors[i], quote) > 0) curve.claimCreatorFees(actors[i], quote);
        }
    }

    /// @dev Buy then immediately sell back in one step: must never be profitable.
    function roundTrip(uint256 tokenSeed, uint256 amount) external {
        address token = _token(tokenSeed);
        if (token == address(0)) return;
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        if (c.complete) return;
        amount = bound(amount, 1, c.realTokenReserves - c.floor);
        address quote = c.quoteToken;
        (uint256 out, uint256 paid) = _buyAs(roundTripper, token, amount, false);
        if (curve.getCurve(token).complete) return;
        uint256 before = IERC20(quote).balanceOf(roundTripper);
        vm.startPrank(roundTripper);
        IERC20(token).approve(address(curve), out);
        curve.sell(token, out, 0);
        vm.stopPrank();
        uint256 received = IERC20(quote).balanceOf(roundTripper) - before;
        if (received > paid) profitableRoundTrips++;
        _checkK(token);
    }

    // ------------------------------------------------------------------ hostile actions

    function donateQuote(uint256 seed, uint256 amount) external {
        address quote = seed % 2 == 0 ? weth : address(usdc);
        amount = bound(amount, 1, 1e24);
        _fund(address(curve), quote, amount);
    }

    function donateToken(uint256 tokenSeed, uint256 actorSeed, uint256 amount) external {
        address token = _token(tokenSeed);
        if (token == address(0)) return;
        address actor = _actor(actorSeed);
        uint256 held = IERC20(token).balanceOf(actor);
        if (held == 0) return;
        vm.prank(actor);
        IERC20(token).transfer(address(curve), bound(amount, 1, held));
    }

    function forceSendEth(uint256 amount) external {
        vm.deal(address(curve), address(curve).balance + bound(amount, 1, 100 ether));
    }

    function tryPushTokenToPair(uint256 tokenSeed, uint256 actorSeed) external {
        address token = _token(tokenSeed);
        if (token == address(0)) return;
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        address actor = _actor(actorSeed);
        if (c.migrated || IERC20(token).balanceOf(actor) == 0) return;
        vm.prank(actor);
        try IERC20(token).transfer(c.pair, 1) {
            tokenReachedPairEarly = true;
        } catch {}
    }

    function ownerChangesParams(uint256 tradeFee, uint256 creatorFee, uint256 graduation, bool disableUsdc) external {
        vm.startPrank(owner);
        curve.setTradeFeeBps(bound(tradeFee, 0, 500));
        curve.setCreatorFeeBps(bound(creatorFee, 0, 5_000));
        curve.setQuote(weth, bound(graduation, 1e6, 1e21), true);
        curve.setQuote(address(usdc), 1_000e6, !disableUsdc);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _buyAs(address actor, address token, uint256 amount, bool useEth)
        internal
        returns (uint256 out, uint256 paid)
    {
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, amount);
        paid = cost + fee;
        address quote = curve.getCurve(token).quoteToken;
        if (useEth && quote == weth) {
            vm.deal(actor, actor.balance + paid);
            vm.prank(actor);
            out = curve.buyWithEth{value: paid}(token, amount, paid);
        } else {
            _fund(actor, quote, paid);
            vm.startPrank(actor);
            IERC20(quote).approve(address(curve), paid);
            out = curve.buy(token, amount, paid);
            vm.stopPrank();
        }
    }

    function _fund(address to, address quote, uint256 amount) internal {
        if (quote == weth) {
            vm.deal(address(this), amount);
            IWETH(weth).deposit{value: amount}();
            IERC20(weth).transfer(to, amount);
        } else {
            usdc.mint(to, amount);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev First actor (starting at `seed`) that holds some of `token`, or address(0).
    function _holder(address token, uint256 seed) internal view returns (address) {
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[(seed + i) % actors.length];
            if (IERC20(token).balanceOf(actor) > 0) return actor;
        }
        return address(0);
    }

    function _token(uint256 seed) internal view returns (address) {
        if (tokens.length == 0) return address(0);
        return tokens[seed % tokens.length];
    }

    function _k(address token) internal view returns (uint256) {
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        return c.virtualTokenReserves * c.virtualQuoteReserves;
    }

    function _recordK(address token) internal {
        lastK[token] = _k(token);
    }

    function _checkK(address token) internal {
        uint256 k = _k(token);
        if (k < lastK[token]) kDecreased = true;
        lastK[token] = k;
    }

    receive() external payable {}
}
