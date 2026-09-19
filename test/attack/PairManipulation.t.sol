// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {Token} from "../../contracts/Token.sol";

interface IRouterLiquidity {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256, uint256, uint256);

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256, uint256, uint256);
}

contract PairManipulationTest is BaseTest {
    address internal token;

    function setUp() public override {
        super.setUp();
        token = _createToken(weth);
        _buy(bob, token, 10_000_000e18);
    }

    function test_Attack_AddLiquidityViaRouterBeforeMigrateReverts() public {
        _fundQuote(bob, weth, 0.01 ether);
        vm.startPrank(bob);
        IERC20(token).approve(router, type(uint256).max);
        IERC20(weth).approve(router, type(uint256).max);
        vm.expectRevert(bytes("TransferHelper: TRANSFER_FROM_FAILED"));
        IRouterLiquidity(router).addLiquidity(token, weth, 1e24, 0.01 ether, 0, 0, bob, block.timestamp);
        vm.stopPrank();
    }

    function test_Attack_AddLiquidityEthViaRouterBeforeMigrateReverts() public {
        vm.deal(bob, 0.01 ether);
        vm.startPrank(bob);
        IERC20(token).approve(router, type(uint256).max);
        vm.expectRevert(bytes("TransferHelper: TRANSFER_FROM_FAILED"));
        IRouterLiquidity(router).addLiquidityETH{value: 0.01 ether}(token, 1e24, 0, 0, bob, block.timestamp);
        vm.stopPrank();
    }

    function test_Attack_ApprovedSpenderCannotPushTokensIntoPair() public {
        address pair = curve.getCurve(token).pair;
        vm.prank(bob);
        IERC20(token).approve(alice, 1e24);
        vm.prank(alice);
        vm.expectRevert(Token.TransferToPairLocked.selector);
        IERC20(token).transferFrom(bob, pair, 1e24);
    }
}
