// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {UniswapV2Deployer} from "../utils/UniswapV2Deployer.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";
import {TokenFactory} from "../../contracts/TokenFactory.sol";
import {Token} from "../../contracts/Token.sol";
import {CurveMath} from "../../contracts/libraries/CurveMath.sol";
import {PairAddress} from "../../contracts/libraries/PairAddress.sol";
import {EthRejecter} from "../attackers/EthRejecter.sol";

contract TokenFactoryTest is BaseTest {
    function test_CreateTokenInitializesCurveForEachQuote() public {
        address[2] memory quoteList = [weth, address(usdc)];
        for (uint256 i; i < quoteList.length; ++i) {
            address quote = quoteList[i];
            address token = _createToken(quote);
            VeztaLaunchToken.Curve memory c = curve.getCurve(token);

            assertEq(c.quoteToken, quote);
            assertEq(c.creator, creator);
            assertEq(c.tokenTotalSupply, SUPPLY);
            assertEq(c.realTokenReserves, SUPPLY);
            assertEq(c.realQuoteReserves, 0);
            assertEq(c.floor, FLOOR);
            assertEq(c.virtualTokenReserves, CurveMath.initialVirtualToken(SUPPLY));
            assertEq(c.virtualQuoteReserves, _graduationOf(quote) / 3);
            assertEq(c.initialVirtualQuoteReserves, _graduationOf(quote) / 3);
            assertEq(c.creatorFeeBps, CREATOR_FEE_BPS);
            assertFalse(c.complete);
            assertFalse(c.migrated);

            address expectedPair = PairAddress.compute(uniFactory, UniswapV2Deployer.pairInitCodeHash(), token, quote);
            assertEq(c.pair, expectedPair);
            assertEq(Token(token).pair(), expectedPair);
            assertEq(expectedPair.code.length, 0); // pair is not deployed at creation
            assertEq(Token(token).balanceOf(address(curve)), SUPPLY);
            assertEq(Token(token).balanceOf(address(factory)), 0);
        }
        assertEq(curve.accruedEth(), 2 * CREATE_FEE);
    }

    function test_CreateTokenEmitsEvents() public {
        vm.deal(creator, CREATE_FEE);
        vm.expectEmit(false, true, true, true, address(factory));
        emit TokenFactory.TokenCreated(address(0), creator, weth, "Vezta Test", "VZT", "ipfs://metadata");
        vm.prank(creator);
        factory.deployERC20Token{value: CREATE_FEE}("Vezta Test", "VZT", "ipfs://metadata", weth);
    }

    function test_CreateTokenRefundsExcessEth() public {
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        factory.deployERC20Token{value: 1 ether}("Vezta Test", "VZT", "ipfs://metadata", weth);
        assertEq(creator.balance, 1 ether - CREATE_FEE);
        assertEq(address(factory).balance, 0);
    }

    function test_RevertWhen_CreatorRejectsRefund() public {
        EthRejecter rejecter = new EthRejecter();
        vm.deal(address(this), 1 ether);
        vm.expectRevert(TokenFactory.EthTransferFailed.selector);
        rejecter.execute{value: 1 ether}(
            address(factory), abi.encodeCall(factory.deployERC20Token, ("Vezta Test", "VZT", "", weth))
        );
    }

    function test_CreateTokenWithZeroCreateFee() public {
        vm.prank(owner);
        curve.setCreateFee(0);
        vm.prank(creator);
        address token = factory.deployERC20Token("Free", "FREE", "", weth);
        assertEq(curve.getCurve(token).tokenTotalSupply, SUPPLY);
        assertEq(curve.accruedEth(), 0);
    }

    function test_RevertWhen_CreateTokenInsufficientFee() public {
        vm.deal(creator, CREATE_FEE);
        vm.prank(creator);
        vm.expectRevert(TokenFactory.InsufficientValue.selector);
        factory.deployERC20Token{value: CREATE_FEE - 1}("Vezta Test", "VZT", "", weth);
    }

    function test_RevertWhen_CreateTokenWithQuoteNotEnabled() public {
        vm.deal(creator, CREATE_FEE);
        vm.prank(creator);
        vm.expectRevert(VeztaLaunchToken.QuoteNotEnabled.selector);
        factory.deployERC20Token{value: CREATE_FEE}("Vezta Test", "VZT", "", alice);
    }

    function test_RevertWhen_CreateTokenWithDisabledQuote() public {
        vm.prank(owner);
        curve.setQuote(address(usdc), 0, false);
        vm.deal(creator, CREATE_FEE);
        vm.prank(creator);
        vm.expectRevert(VeztaLaunchToken.QuoteNotEnabled.selector);
        factory.deployERC20Token{value: CREATE_FEE}("Vezta Test", "VZT", "", address(usdc));
    }

    function test_RevertWhen_CreateTokenBeforeCurveIsSet() public {
        TokenFactory fresh = new TokenFactory(owner);
        vm.expectRevert(TokenFactory.BondingCurveNotSet.selector);
        fresh.deployERC20Token("Vezta Test", "VZT", "", weth);
    }

    function test_Attack_CreatePoolDirectlyIsRejected() public {
        vm.deal(alice, CREATE_FEE);
        vm.prank(alice);
        vm.expectRevert(VeztaLaunchToken.NotFactory.selector);
        curve.createPool{value: CREATE_FEE}(alice, SUPPLY, alice, weth);
    }

    function test_Attack_CreatePoolCannotOverwriteExistingCurve() public {
        address token = _createToken(weth);
        vm.deal(address(factory), CREATE_FEE);
        vm.prank(address(factory));
        vm.expectRevert(VeztaLaunchToken.CurveExists.selector);
        curve.createPool{value: CREATE_FEE}(token, SUPPLY, alice, weth);
    }

    function test_RevertWhen_CreatePoolWrongValueOrZeroAmount() public {
        vm.deal(address(factory), 1 ether);
        vm.startPrank(address(factory));
        vm.expectRevert(VeztaLaunchToken.InsufficientValue.selector);
        curve.createPool{value: CREATE_FEE + 1}(alice, SUPPLY, alice, weth);
        vm.expectRevert(VeztaLaunchToken.ZeroAmount.selector);
        curve.createPool{value: CREATE_FEE}(alice, 0, alice, weth);
        vm.stopPrank();
    }

    function test_ParameterChangesOnlyAffectNewTokens() public {
        address oldToken = _createToken(weth);
        vm.startPrank(owner);
        curve.setQuote(weth, 4 ether, true);
        curve.setCreatorFeeBps(0);
        vm.stopPrank();
        address newToken = _createToken(weth);

        assertEq(curve.getCurve(oldToken).initialVirtualQuoteReserves, WETH_GRADUATION / 3);
        assertEq(curve.getCurve(oldToken).creatorFeeBps, CREATOR_FEE_BPS);
        assertEq(curve.getCurve(newToken).initialVirtualQuoteReserves, uint256(4 ether) / 3);
        assertEq(curve.getCurve(newToken).creatorFeeBps, 0);
    }

    function test_FactoryAdmin() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setBondingCurve(alice);

        vm.startPrank(owner);
        vm.expectRevert(TokenFactory.ZeroAddress.selector);
        factory.setBondingCurve(address(0));
        vm.expectEmit(address(factory));
        emit TokenFactory.BondingCurveSet(bob);
        factory.setBondingCurve(bob);
        vm.expectRevert(TokenFactory.RenounceDisabled.selector);
        factory.renounceOwnership();
        vm.stopPrank();
        assertEq(address(factory.bondingCurve()), bob);
    }
}
