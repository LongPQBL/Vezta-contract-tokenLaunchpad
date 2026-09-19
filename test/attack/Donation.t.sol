// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";

contract DonationTest is BaseTest {
    address internal token;

    function setUp() public override {
        super.setUp();
        token = _createToken(weth);
        _buy(alice, token, 100_000_000e18);
    }

    function test_Attack_QuoteDonationDoesNotChangeAccountingOrPrice() public {
        VeztaLaunchToken.Curve memory before = curve.getCurve(token);
        (, uint256 costBefore,) = curve.previewBuy(token, 1e24);
        uint256 feesBefore = curve.accruedQuoteFees(weth);

        _fundQuote(bob, weth, 1 ether);
        vm.prank(bob);
        IERC20(weth).transfer(address(curve), 1 ether);

        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        assertEq(c.realQuoteReserves, before.realQuoteReserves);
        assertEq(c.virtualQuoteReserves, before.virtualQuoteReserves);
        (, uint256 costAfter,) = curve.previewBuy(token, 1e24);
        assertEq(costAfter, costBefore);
        assertEq(curve.accruedQuoteFees(weth), feesBefore);
    }

    function test_Attack_TokenDonationDoesNotChangeAccounting() public {
        VeztaLaunchToken.Curve memory before = curve.getCurve(token);
        vm.prank(alice);
        IERC20(token).transfer(address(curve), 1e24);
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        assertEq(c.realTokenReserves, before.realTokenReserves);
        assertEq(c.virtualTokenReserves, before.virtualTokenReserves);
    }

    function test_Attack_ForcedEthDoesNotBreakFeeAccounting() public {
        uint256 accrued = curve.accruedEth();
        // Simulates SELFDESTRUCT force-sending ETH past receive().
        vm.deal(address(curve), address(curve).balance + 5 ether);
        assertEq(curve.accruedEth(), accrued);
        curve.claimCreateFees();
        assertEq(feeRecipient.balance, accrued); // only accounted fees are paid out
    }
}
