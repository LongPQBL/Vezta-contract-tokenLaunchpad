// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {MockFeeOnTransferERC20} from "../mocks/MockFeeOnTransferERC20.sol";
import {MockFalseReturnERC20} from "../mocks/MockFalseReturnERC20.sol";
import {MockNoReturnERC20} from "../mocks/MockNoReturnERC20.sol";
import {MockBlacklistERC20} from "../mocks/MockBlacklistERC20.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";

contract NonStandardTokensTest is BaseTest {
    function _enable(address quote) internal {
        vm.prank(owner);
        curve.setQuote(quote, 1e18, true);
    }

    function test_Attack_FeeOnTransferQuoteIsRejectedOnBuy() public {
        MockFeeOnTransferERC20 feeToken = new MockFeeOnTransferERC20();
        _enable(address(feeToken));
        address token = _createToken(address(feeToken));
        feeToken.mint(alice, 1e18);
        vm.startPrank(alice);
        feeToken.approve(address(curve), type(uint256).max);
        vm.expectRevert(VeztaLaunchToken.QuoteTransferMismatch.selector);
        curve.buy(token, 1e24, type(uint256).max);
        vm.stopPrank();
        assertEq(curve.getCurve(token).realQuoteReserves, 0);
    }

    function test_Attack_FalseReturningQuoteCannotCreditFakePayment() public {
        MockFalseReturnERC20 falseToken = new MockFalseReturnERC20();
        _enable(address(falseToken));
        address token = _createToken(address(falseToken));
        vm.startPrank(alice); // alice holds no balance: transferFrom returns false
        falseToken.approve(address(curve), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(falseToken)));
        curve.buy(token, 1e24, type(uint256).max);
        vm.stopPrank();
        assertEq(IERC20(token).balanceOf(alice), 0);
    }

    function test_NoReturnValueQuoteWorksEndToEnd() public {
        MockNoReturnERC20 usdt = new MockNoReturnERC20();
        _enable(address(usdt));
        address token = _createToken(address(usdt));
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, type(uint256).max);
        usdt.mint(alice, cost + fee);
        vm.startPrank(alice);
        usdt.approve(address(curve), cost + fee);
        curve.buy(token, type(uint256).max, cost + fee);
        vm.stopPrank();
        curve.migrate(token);
        curve.claimFees(address(usdt));
        assertTrue(curve.getCurve(token).migrated);
        assertGt(usdt.balanceOf(feeRecipient), 0);
    }

    function test_BlacklistedCurveOnlyFreezesThatQuote() public {
        MockBlacklistERC20 frozen = new MockBlacklistERC20();
        _enable(address(frozen));
        address frozenLaunch = _createToken(address(frozen));
        address wethLaunch = _createToken(weth);
        (, uint256 cost, uint256 fee) = curve.previewBuy(frozenLaunch, 1e24);
        frozen.mint(alice, cost + fee);
        vm.startPrank(alice);
        frozen.approve(address(curve), cost + fee);
        curve.buy(frozenLaunch, 1e24, cost + fee);
        vm.stopPrank();

        frozen.setBlacklisted(address(curve), true);

        vm.startPrank(alice);
        IERC20(frozenLaunch).approve(address(curve), 1e24);
        vm.expectRevert("blacklisted");
        curve.sell(frozenLaunch, 1e24, 0);
        vm.stopPrank();

        // other quotes are unaffected
        _buy(bob, wethLaunch, 1e24);
        _sell(bob, wethLaunch, 1e24);
        curve.claimFees(weth);
    }
}
