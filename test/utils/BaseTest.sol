// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniswapV2Deployer} from "./UniswapV2Deployer.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";
import {TokenFactory} from "../../contracts/TokenFactory.sol";
import {IWETH} from "../../contracts/interfaces/IUniswapV2.sol";

/// @notice Shared fixture: local Uniswap V2 + launchpad wired together with WETH and a
///         6-decimal USDC stand-in whitelisted as quote tokens.
abstract contract BaseTest is Test {
    uint256 internal constant SUPPLY = 1e27;
    uint256 internal constant FLOOR = SUPPLY / 5;
    uint256 internal constant CREATE_FEE = 0.001 ether;
    uint256 internal constant TRADE_FEE_BPS = 100;
    uint256 internal constant CREATOR_FEE_BPS = 2_000;
    uint256 internal constant WETH_GRADUATION = 0.4 ether;
    uint256 internal constant USDC_GRADUATION = 1_000e6;

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    address internal uniFactory;
    address internal weth;
    address internal router;
    MockERC20 internal usdc;
    VeztaLaunchToken internal curve;
    TokenFactory internal factory;

    function setUp() public virtual {
        (uniFactory, weth, router) = UniswapV2Deployer.deployAll(address(this));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        (curve, factory) = _deployLaunchpad(UniswapV2Deployer.pairInitCodeHash());
    }

    function _deployLaunchpad(bytes32 initCodeHash) internal returns (VeztaLaunchToken c, TokenFactory f) {
        c = new VeztaLaunchToken(owner, feeRecipient, CREATE_FEE, TRADE_FEE_BPS, CREATOR_FEE_BPS, router, initCodeHash);
        f = new TokenFactory(owner);
        vm.startPrank(owner);
        f.setBondingCurve(address(c));
        c.setFactory(address(f));
        c.setQuote(weth, WETH_GRADUATION, true);
        c.setQuote(address(usdc), USDC_GRADUATION, true);
        vm.stopPrank();
    }

    function _graduationOf(address quote) internal view returns (uint256 amount) {
        (, amount) = curve.quotes(quote);
    }

    function _createToken(address quote) internal returns (address) {
        return _createTokenWith(factory, creator, quote);
    }

    function _createTokenWith(TokenFactory f, address who, address quote) internal returns (address token) {
        vm.deal(who, who.balance + CREATE_FEE);
        vm.prank(who);
        token = f.deployERC20Token{value: CREATE_FEE}("Vezta Test", "VZT", "ipfs://metadata", quote);
    }

    function _fundQuote(address who, address quote, uint256 amount) internal {
        if (quote == weth) {
            vm.deal(who, who.balance + amount);
            vm.prank(who);
            IWETH(weth).deposit{value: amount}();
        } else {
            MockERC20(quote).mint(who, amount);
        }
    }

    /// @dev Funds `who` with exactly the quote needed, then buys through `buy`.
    function _buy(address who, address token, uint256 amount) internal returns (uint256 amountOut, uint256 paid) {
        return _buyOn(curve, who, token, amount);
    }

    function _buyOn(VeztaLaunchToken c, address who, address token, uint256 amount)
        internal
        returns (uint256 amountOut, uint256 paid)
    {
        (, uint256 cost, uint256 fee) = c.previewBuy(token, amount);
        paid = cost + fee;
        address quote = c.getCurve(token).quoteToken;
        _fundQuote(who, quote, paid);
        vm.startPrank(who);
        IERC20(quote).approve(address(c), paid);
        amountOut = c.buy(token, amount, paid);
        vm.stopPrank();
    }

    function _buyToCompletion(address who, address token) internal returns (uint256 amountOut) {
        (amountOut,) = _buy(who, token, type(uint256).max);
    }

    function _sell(address who, address token, uint256 amount) internal returns (uint256 payout) {
        vm.startPrank(who);
        IERC20(token).approve(address(curve), amount);
        payout = curve.sell(token, amount, 0);
        vm.stopPrank();
    }
}
