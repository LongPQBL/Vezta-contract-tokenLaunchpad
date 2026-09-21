// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Token} from "../../contracts/Token.sol";

/// @dev This test contract plays the role of the bonding curve.
contract TokenTest is Test {
    Token internal token;
    address internal holder = makeAddr("holder");
    address internal other = makeAddr("other");
    address internal pair = makeAddr("pair");

    function setUp() public {
        token = new Token("Vezta Test", "VZT", 1e27, address(this));
        token.transfer(holder, 1_000e18);
    }

    function test_MintsSupplyToDeployer() public view {
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27 - 1_000e18);
        assertEq(token.bondingCurve(), address(this));
        assertEq(token.decimals(), 18);
    }

    function test_RevertWhen_SetPairByNonCurve() public {
        vm.prank(holder);
        vm.expectRevert(Token.NotBondingCurve.selector);
        token.setPair(pair);
    }

    function test_RevertWhen_SetPairTwice() public {
        token.setPair(pair);
        vm.expectRevert(Token.PairAlreadySet.selector);
        token.setPair(other);
    }

    function test_RevertWhen_OpenTradingByNonCurve() public {
        vm.prank(holder);
        vm.expectRevert(Token.NotBondingCurve.selector);
        token.openTrading();
    }

    function test_RevertWhen_TransferToPairBeforeTradingOpens() public {
        token.setPair(pair);
        vm.prank(holder);
        vm.expectRevert(Token.TransferToPairLocked.selector);
        token.transfer(pair, 1);
    }

    function test_RevertWhen_TransferFromToPairBeforeTradingOpens() public {
        token.setPair(pair);
        vm.prank(holder);
        token.approve(other, 1);
        vm.prank(other);
        vm.expectRevert(Token.TransferToPairLocked.selector);
        token.transferFrom(holder, pair, 1);
    }

    function test_WalletToWalletTransferAllowedBeforeTradingOpens() public {
        token.setPair(pair);
        vm.prank(holder);
        token.transfer(other, 1);
        assertEq(token.balanceOf(other), 1);
    }

    function test_CurveCanTransferToPairBeforeTradingOpens() public {
        token.setPair(pair);
        token.transfer(pair, 1);
        assertEq(token.balanceOf(pair), 1);
    }

    function test_AnyoneCanTransferToPairAfterTradingOpens() public {
        token.setPair(pair);
        token.openTrading();
        vm.prank(holder);
        token.transfer(pair, 1);
        assertEq(token.balanceOf(pair), 1);
        assertTrue(token.tradingOpen());
    }

    // ------------------------------------------------------------------
    // The bonding curve may always take tokens from whoever calls it, so selling needs no approve transaction.
    // ------------------------------------------------------------------

    function test_BondingCurveAllowanceIsAlwaysMax() public view {
        assertEq(token.allowance(holder, address(this)), type(uint256).max);
        assertEq(token.allowance(other, address(this)), type(uint256).max);
        assertEq(token.allowance(address(0xBEEF), address(this)), type(uint256).max);
    }

    function test_CurveCanTransferFromWithoutApproval() public {
        token.transferFrom(holder, other, 400e18);
        assertEq(token.balanceOf(holder), 600e18);
        assertEq(token.balanceOf(other), 400e18);
    }

    function test_CurveAllowanceIsNotUsedUp() public {
        token.transferFrom(holder, other, 400e18);
        token.transferFrom(holder, other, 100e18);
        assertEq(token.allowance(holder, address(this)), type(uint256).max);
    }

    function test_AllowanceOfEveryoneElseIsUnchanged() public {
        assertEq(token.allowance(holder, other), 0);
        vm.prank(holder);
        token.approve(other, 500e18);
        assertEq(token.allowance(holder, other), 500e18);
        vm.prank(other);
        token.transferFrom(holder, other, 200e18);
        assertEq(token.allowance(holder, other), 300e18); // an ordinary allowance is still spent
    }

    function test_RevertWhen_OtherSpenderPullsWithoutApproval() public {
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, other, 0, 1));
        token.transferFrom(holder, other, 1);
    }

    function test_RevertWhen_OtherSpenderPullsMoreThanApproved() public {
        vm.prank(holder);
        token.approve(other, 10);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, other, 10, 11));
        token.transferFrom(holder, other, 11);
    }

    function test_RevertWhen_CurveTransfersMoreThanTheHolderHas() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 1_000e18, 1_000e18 + 1));
        token.transferFrom(holder, other, 1_000e18 + 1);
    }

    /// @dev The pre-approval is for taking tokens, not for opening the pair early: the launch lock still applies to a transfer the curve
    ///      itself starts from a holder into the pair.
    function test_RevertWhen_CurvePullsFromAHolderIntoThePairBeforeTradingOpens() public {
        token.setPair(pair);
        vm.expectRevert(Token.TransferToPairLocked.selector);
        token.transferFrom(holder, pair, 1);
    }

    /// @dev Approving the curve does nothing, and so revoking it does nothing: it cannot be withdrawn. That is the price of one-step
    ///      selling, and it is what the tests pin so it is never a surprise.
    function test_ApprovingOrRevokingTheCurveChangesNothing() public {
        vm.prank(holder);
        token.approve(address(this), 5);
        assertEq(token.allowance(holder, address(this)), type(uint256).max);
        vm.prank(holder);
        token.approve(address(this), 0);
        assertEq(token.allowance(holder, address(this)), type(uint256).max);
        token.transferFrom(holder, other, 1); // the curve can still take
        assertEq(token.balanceOf(other), 1);
    }

    function test_AllowanceOfTheCurveDoesNotLeakToAnotherAddress(address spender) public view {
        vm.assume(spender != address(this));
        assertEq(token.allowance(holder, spender), 0);
    }

    function testFuzz_CurveCanPullAnyAmountUpToTheBalance(uint256 amount) public {
        amount = bound(amount, 0, 1_000e18);
        token.transferFrom(holder, other, amount);
        assertEq(token.balanceOf(holder), 1_000e18 - amount);
        assertEq(token.balanceOf(other), amount);
    }
}
