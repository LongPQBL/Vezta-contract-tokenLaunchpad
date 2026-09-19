// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {UniswapV2Deployer} from "../utils/UniswapV2Deployer.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract AdminTest is BaseTest {
    function test_ConstructorWiresUniswapFromRouter() public view {
        assertEq(curve.owner(), owner);
        assertEq(address(curve.weth()), weth);
        assertEq(address(curve.uniswapFactory()), uniFactory);
        assertEq(curve.pairInitCodeHash(), UniswapV2Deployer.pairInitCodeHash());
        assertEq(curve.feeRecipient(), feeRecipient);
        assertEq(curve.createFee(), CREATE_FEE);
        assertEq(curve.tradeFeeBps(), TRADE_FEE_BPS);
        assertEq(curve.creatorFeeBps(), CREATOR_FEE_BPS);
        assertEq(curve.factory(), address(factory));
    }

    function test_RevertWhen_ConstructorZeroFeeRecipient() public {
        vm.expectRevert(VeztaLaunchToken.ZeroAddress.selector);
        new VeztaLaunchToken(owner, address(0), CREATE_FEE, TRADE_FEE_BPS, CREATOR_FEE_BPS, router, bytes32(0));
    }

    function test_RevertWhen_ConstructorZeroRouter() public {
        vm.expectRevert(VeztaLaunchToken.ZeroAddress.selector);
        new VeztaLaunchToken(owner, feeRecipient, CREATE_FEE, TRADE_FEE_BPS, CREATOR_FEE_BPS, address(0), bytes32(0));
    }

    function test_RevertWhen_ConstructorZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new VeztaLaunchToken(address(0), feeRecipient, CREATE_FEE, TRADE_FEE_BPS, CREATOR_FEE_BPS, router, bytes32(0));
    }

    function test_RevertWhen_ConstructorTradeFeeTooHigh() public {
        vm.expectRevert(VeztaLaunchToken.FeeTooHigh.selector);
        new VeztaLaunchToken(owner, feeRecipient, CREATE_FEE, 501, CREATOR_FEE_BPS, router, bytes32(0));
    }

    function test_RevertWhen_ConstructorCreatorFeeTooHigh() public {
        vm.expectRevert(VeztaLaunchToken.FeeTooHigh.selector);
        new VeztaLaunchToken(owner, feeRecipient, CREATE_FEE, TRADE_FEE_BPS, 5_001, router, bytes32(0));
    }

    function test_Attack_NonOwnerCannotCallAnyAdminFunction() public {
        bytes[] memory calls = new bytes[](7);
        calls[0] = abi.encodeCall(curve.setFactory, (alice));
        calls[1] = abi.encodeCall(curve.setFeeRecipient, (alice));
        calls[2] = abi.encodeCall(curve.setCreateFee, (0));
        calls[3] = abi.encodeCall(curve.setTradeFeeBps, (0));
        calls[4] = abi.encodeCall(curve.setCreatorFeeBps, (0));
        calls[5] = abi.encodeCall(curve.setQuote, (alice, 1e18, true));
        calls[6] = abi.encodeCall(curve.transferOwnership, (alice));
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(alice);
            (bool ok, bytes memory ret) = address(curve).call(calls[i]);
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        }
    }

    function test_OwnerSettersUpdateStateAndEmit() public {
        vm.startPrank(owner);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.FeeRecipientSet(alice);
        curve.setFeeRecipient(alice);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.CreateFeeSet(0);
        curve.setCreateFee(0);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.TradeFeeBpsSet(500);
        curve.setTradeFeeBps(500);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.CreatorFeeBpsSet(5_000);
        curve.setCreatorFeeBps(5_000);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.FactorySet(bob);
        curve.setFactory(bob);
        vm.stopPrank();
        assertEq(curve.feeRecipient(), alice);
        assertEq(curve.createFee(), 0);
        assertEq(curve.tradeFeeBps(), 500);
        assertEq(curve.creatorFeeBps(), 5_000);
        assertEq(curve.factory(), bob);
    }

    function test_RevertWhen_SettersGetInvalidValues() public {
        vm.startPrank(owner);
        vm.expectRevert(VeztaLaunchToken.ZeroAddress.selector);
        curve.setFeeRecipient(address(0));
        vm.expectRevert(VeztaLaunchToken.ZeroAddress.selector);
        curve.setFactory(address(0));
        vm.expectRevert(VeztaLaunchToken.FeeTooHigh.selector);
        curve.setTradeFeeBps(501);
        vm.expectRevert(VeztaLaunchToken.FeeTooHigh.selector);
        curve.setCreatorFeeBps(5_001);
        vm.stopPrank();
    }

    function test_SetQuote() public {
        MockERC20 quote = new MockERC20("Quote", "Q", 6);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.QuoteSet(address(quote), 1_000_000, true);
        vm.prank(owner);
        curve.setQuote(address(quote), 1_000_000, true);
        (bool enabled, uint256 graduation) = curve.quotes(address(quote));
        assertTrue(enabled);
        assertEq(graduation, 1_000_000);
    }

    function test_SetQuoteDisableAllowsAnyAmount() public {
        vm.prank(owner);
        curve.setQuote(weth, 0, false);
        (bool enabled,) = curve.quotes(weth);
        assertFalse(enabled);
    }

    function test_RevertWhen_SetQuoteZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(VeztaLaunchToken.ZeroAddress.selector);
        curve.setQuote(address(0), 1e18, true);
    }

    function test_RevertWhen_SetQuoteGraduationTooSmall() public {
        vm.prank(owner);
        vm.expectRevert(VeztaLaunchToken.GraduationTooSmall.selector);
        curve.setQuote(weth, 999_999, true);
    }

    function test_RevertWhen_SetQuoteGraduationTooLarge() public {
        uint256 max = curve.MAX_GRADUATION_AMOUNT();
        vm.startPrank(owner);
        curve.setQuote(weth, max, true); // boundary is allowed
        vm.expectRevert(VeztaLaunchToken.GraduationTooLarge.selector);
        curve.setQuote(weth, max + 1, true);
        vm.stopPrank();
    }

    function test_RevertWhen_SetQuoteSupplyTooLarge() public {
        MockERC20 whale = new MockERC20("Whale", "WHL", 18);
        uint256 graduation = 1_000 ether;
        whale.mint(alice, type(uint112).max - graduation + 1);
        vm.prank(owner);
        vm.expectRevert(VeztaLaunchToken.QuoteSupplyTooLarge.selector);
        curve.setQuote(address(whale), graduation, true);
    }

    function test_SetQuoteAtExactSupplyLimit() public {
        MockERC20 whale = new MockERC20("Whale", "WHL", 18);
        uint256 graduation = 1_000 ether;
        whale.mint(alice, type(uint112).max - graduation);
        vm.prank(owner);
        curve.setQuote(address(whale), graduation, true);
        (bool enabled,) = curve.quotes(address(whale));
        assertTrue(enabled);
    }

    function test_DisablingAQuoteIgnoresItsSupply() public {
        MockERC20 whale = new MockERC20("Whale", "WHL", 18);
        whale.mint(alice, type(uint112).max);
        vm.prank(owner);
        curve.setQuote(address(whale), 0, false);
        (bool enabled,) = curve.quotes(address(whale));
        assertFalse(enabled);
    }

    function test_RevertWhen_RenounceOwnership() public {
        vm.prank(owner);
        vm.expectRevert(VeztaLaunchToken.RenounceDisabled.selector);
        curve.renounceOwnership();
        assertEq(curve.owner(), owner);
    }

    function test_TwoStepOwnershipTransfer() public {
        vm.prank(owner);
        curve.transferOwnership(alice);
        assertEq(curve.owner(), owner); // not yet
        assertEq(curve.pendingOwner(), alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        curve.acceptOwnership();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        curve.setCreateFee(0); // pending owner has no power yet

        vm.prank(alice);
        curve.acceptOwnership();
        assertEq(curve.owner(), alice);
    }

    function test_RevertWhen_PlainEthSentToCurve() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(curve).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(VeztaLaunchToken.EthNotAccepted.selector));
    }
}
