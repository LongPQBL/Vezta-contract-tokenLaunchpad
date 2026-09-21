// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {Token} from "../../contracts/Token.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";

/// @notice The token treats its bonding curve as always approved (so a sale is one transaction). These try to turn that into a way to take
///         tokens that are not the caller's, or to get at the pool early.
contract PreApprovalTest is BaseTest {
    address internal token;
    address internal attacker = makeAddr("attacker");

    function setUp() public override {
        super.setUp();
        token = _createToken(weth);
        _buy(alice, token, 100_000_000e18);
    }

    /// @dev The curve only ever pulls from msg.sender. Someone else selling gets nothing of Alice's, and is refused for having no tokens.
    function test_Attack_SellPullsOnlyFromTheCaller() public {
        uint256 aliceBefore = IERC20(token).balanceOf(alice);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, attacker, 0, 1e18));
        curve.sellForEth(token, 1e18, 0);
        assertEq(IERC20(token).balanceOf(alice), aliceBefore);
        assertEq(attacker.balance, 0);
    }

    /// @dev Only the curve is pre-approved. An attacker cannot spend Alice's tokens as a spender of their own, nor by claiming to be the curve.
    function test_Attack_OnlyTheCurveItselfIsPreApproved() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, attacker, 0, 1e18));
        IERC20(token).transferFrom(alice, attacker, 1e18);
        assertEq(IERC20(token).allowance(alice, attacker), 0);
        assertEq(IERC20(token).allowance(alice, address(0xdead)), 0);
    }

    /// @dev A token is pre-approved for ITS curve only: a token made for a second launchpad does not approve this one.
    function test_Attack_AnotherLaunchpadsTokenDoesNotApproveThisCurve() public {
        Token foreign = new Token("Foreign", "FRN", 1_000e18, address(0xF00D)); // its curve is someone else
        foreign.transfer(alice, 1_000e18);
        assertEq(foreign.allowance(alice, address(curve)), 0);
        vm.prank(address(curve));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(curve), 0, 1));
        foreign.transferFrom(alice, address(curve), 1);
    }

    /// @dev Revoking cannot take the curve's ability away, and selling still works after a "revoke": pinned, so nobody is told otherwise.
    function test_Attack_RevokeIsAnIllusionButHarmless() public {
        vm.prank(alice);
        IERC20(token).approve(address(curve), 0);
        assertEq(IERC20(token).allowance(alice, address(curve)), type(uint256).max);
        vm.prank(alice);
        uint256 payout = curve.sellForEth(token, 10_000_000e18, 0);
        assertGt(payout, 0);
    }

    /// @dev The pool is still closed before migration: pre-approval gives the curve no way to seed it from a holder's tokens, and a holder
    ///      cannot send there either.
    function test_Attack_PoolStaysClosedBeforeMigration() public {
        address pair = curve.getCurve(token).pair;
        vm.prank(alice);
        vm.expectRevert(Token.TransferToPairLocked.selector);
        IERC20(token).transfer(pair, 1e18);
        vm.prank(address(curve));
        vm.expectRevert(Token.TransferToPairLocked.selector);
        IERC20(token).transferFrom(alice, pair, 1e18);
    }

    /// @dev A holder who sells everything back is paid and left with nothing, and no allowance is left behind that could be turned on
    ///      someone else: the pre-approval is the same before and after.
    function test_Attack_SellingEverythingLeavesNothingBehind() public {
        uint256 all = IERC20(token).balanceOf(alice);
        vm.prank(alice);
        curve.sellForEth(token, all, 0);
        assertEq(IERC20(token).balanceOf(alice), 0);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, attacker, 0, 1));
        IERC20(token).transferFrom(alice, attacker, 1);
    }

    /// @dev A hostile contract cannot use its own callback during a sale to pull tokens through the pre-approval: it is not the curve.
    function testFuzz_Attack_NoOneButTheCurveCanPull(address spender, uint256 amount) public {
        vm.assume(spender != address(curve) && spender != address(0));
        amount = bound(amount, 1, IERC20(token).balanceOf(alice));
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, amount));
        IERC20(token).transferFrom(alice, spender, amount);
    }
}
