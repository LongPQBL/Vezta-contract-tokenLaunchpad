// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
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
}
