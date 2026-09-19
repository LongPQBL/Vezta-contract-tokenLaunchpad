// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract OwnerPowersTest is BaseTest {
    /// @dev The owner uses every privileged function (including pointing the fee recipient at
    ///      itself and claiming) and still cannot move the quote or tokens backing a live curve.
    function test_Attack_OwnerCannotDrainCurveFunds() public {
        address token = _createToken(weth);
        _buy(alice, token, 300_000_000e18);
        uint256 reserve = curve.getCurve(token).realQuoteReserves;
        uint256 tokenReserve = curve.getCurve(token).realTokenReserves;

        vm.startPrank(owner);
        curve.setFeeRecipient(owner);
        curve.setCreateFee(0);
        curve.setTradeFeeBps(500);
        curve.setCreatorFeeBps(5_000);
        curve.setQuote(weth, 1e24, false);
        curve.setFactory(owner);
        curve.claimFees(weth);
        curve.claimCreateFees();
        vm.stopPrank();

        assertEq(curve.getCurve(token).realQuoteReserves, reserve);
        assertGe(IERC20(weth).balanceOf(address(curve)), reserve + curve.totalCreatorFees(weth));
        assertEq(IERC20(token).balanceOf(address(curve)), tokenReserve);

        // holders can still exit
        uint256 payout = _sell(alice, token, 300_000_000e18);
        assertGt(payout, 0);
    }
}
