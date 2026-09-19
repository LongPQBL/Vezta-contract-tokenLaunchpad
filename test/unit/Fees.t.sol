// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {EthRejecter} from "../attackers/EthRejecter.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";

contract FeesTest is BaseTest {
    address internal wethToken;
    address internal usdcToken;

    function setUp() public override {
        super.setUp();
        wethToken = _createToken(weth);
        usdcToken = _createToken(address(usdc));
        _buy(alice, wethToken, 200_000_000e18);
        _buy(alice, usdcToken, 200_000_000e18);
        _sell(alice, wethToken, 50_000_000e18);
    }

    function test_ClaimFeesSendsPlatformShareToRecipient() public {
        uint256 amount = curve.accruedQuoteFees(weth);
        assertGt(amount, 0);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.FeesClaimed(weth, feeRecipient, amount);
        vm.prank(bob); // anyone can trigger the claim
        curve.claimFees(weth);
        assertEq(IERC20(weth).balanceOf(feeRecipient), amount);
        assertEq(IERC20(weth).balanceOf(bob), 0);
        assertEq(curve.accruedQuoteFees(weth), 0);
    }

    function test_ClaimFeesPerQuoteIsIndependent() public {
        uint256 usdcFees = curve.accruedQuoteFees(address(usdc));
        curve.claimFees(weth);
        assertEq(curve.accruedQuoteFees(address(usdc)), usdcFees);
        curve.claimFees(address(usdc));
        assertEq(usdc.balanceOf(feeRecipient), usdcFees);
    }

    function test_ClaimCreateFeesSendsNativeEth() public {
        uint256 amount = curve.accruedEth();
        assertEq(amount, 2 * CREATE_FEE);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.CreateFeesClaimed(feeRecipient, amount);
        vm.prank(bob);
        curve.claimCreateFees();
        assertEq(feeRecipient.balance, amount);
        assertEq(curve.accruedEth(), 0);
    }

    function test_ClaimCreatorFeesPaysCreator() public {
        uint256 amount = curve.creatorFees(creator, weth);
        assertGt(amount, 0);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.CreatorFeesClaimed(creator, weth, amount);
        vm.prank(bob);
        curve.claimCreatorFees(creator, weth);
        assertEq(IERC20(weth).balanceOf(creator), amount);
        assertEq(curve.creatorFees(creator, weth), 0);
        assertEq(curve.totalCreatorFees(weth), 0);
    }

    function test_RevertWhen_NothingToClaim() public {
        vm.expectRevert(VeztaLaunchToken.NothingToClaim.selector);
        curve.claimFees(alice);
        vm.expectRevert(VeztaLaunchToken.NothingToClaim.selector);
        curve.claimCreatorFees(alice, weth);
        curve.claimCreateFees();
        vm.expectRevert(VeztaLaunchToken.NothingToClaim.selector);
        curve.claimCreateFees();
    }

    function test_ClaimsNeverTouchCurveReserves() public {
        uint256 wethReserve = curve.getCurve(wethToken).realQuoteReserves;
        curve.claimFees(weth);
        curve.claimCreatorFees(creator, weth);
        curve.claimCreateFees();
        assertEq(curve.getCurve(wethToken).realQuoteReserves, wethReserve);
        assertEq(IERC20(weth).balanceOf(address(curve)), wethReserve);
        assertEq(address(curve).balance, 0);
    }

    function test_RejectingRecipientOnlyBlocksItsOwnClaim() public {
        EthRejecter rejecter = new EthRejecter();
        vm.prank(owner);
        curve.setFeeRecipient(address(rejecter));

        vm.expectRevert(VeztaLaunchToken.EthTransferFailed.selector);
        curve.claimCreateFees();

        // users keep trading and creating tokens
        _buy(bob, wethToken, 1e24);
        _createToken(weth);

        vm.prank(owner);
        curve.setFeeRecipient(feeRecipient);
        curve.claimCreateFees();
        assertEq(feeRecipient.balance, 3 * CREATE_FEE);
    }
}
