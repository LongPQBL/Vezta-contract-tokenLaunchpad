// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {ReentrantReceiver} from "../attackers/ReentrantReceiver.sol";
import {MockHookERC20} from "../mocks/MockHookERC20.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";
import {TokenFactory} from "../../contracts/TokenFactory.sol";

contract ReentrancyTest is BaseTest {
    ReentrantReceiver internal attacker;
    address internal token;

    function setUp() public override {
        super.setUp();
        attacker = new ReentrantReceiver();
        token = _createToken(weth);
        _buy(alice, token, 100_000_000e18);
    }

    function _reentrancyError() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function _assertReentryBlocked() internal view {
        assertTrue(attacker.attempted());
        assertFalse(attacker.reentrySucceeded());
        assertEq(attacker.reentryRevertData(), _reentrancyError());
    }

    function test_Attack_ReenterDuringBuyWithEthRefund() public {
        attacker.arm(address(curve), abi.encodeCall(curve.buyWithEth, (token, 1e18, type(uint256).max)));
        vm.deal(address(attacker), 1 ether);
        uint256 reserveBefore = curve.getCurve(token).realQuoteReserves;
        (, uint256 cost,) = curve.previewBuy(token, 1e24);
        attacker.execute(address(curve), 1 ether, abi.encodeCall(curve.buyWithEth, (token, 1e24, type(uint256).max)));
        _assertReentryBlocked();
        assertEq(curve.getCurve(token).realQuoteReserves, reserveBefore + cost); // exactly one buy happened
    }

    function test_Attack_ReenterDuringSellForEthPayout() public {
        attacker.arm(address(curve), abi.encodeCall(curve.sell, (token, 1e18, 0)));
        vm.prank(alice);
        IERC20(token).transfer(address(attacker), 2e24);
        attacker.approve(token, address(curve), type(uint256).max);
        attacker.execute(address(curve), 0, abi.encodeCall(curve.sellForEth, (token, 1e24, 0)));
        _assertReentryBlocked();
        assertEq(IERC20(token).balanceOf(address(attacker)), 1e24); // only one sell went through
    }

    function test_Attack_ReenterClaimCreateFeesFromFeeRecipient() public {
        vm.prank(owner);
        curve.setFeeRecipient(address(attacker));
        attacker.arm(address(curve), abi.encodeCall(curve.claimCreateFees, ()));
        uint256 amount = curve.accruedEth();
        curve.claimCreateFees();
        _assertReentryBlocked();
        assertEq(address(attacker).balance, amount); // paid once
    }

    function test_Attack_ReenterMigrateFromRefund() public {
        _buy(bob, token, (SUPPLY - FLOOR) - 100_000_000e18 - 1e18); // leave 1 token to buy
        attacker.arm(address(curve), abi.encodeCall(curve.migrate, (token)));
        vm.deal(address(attacker), 1 ether);
        attacker.execute(address(curve), 1 ether, abi.encodeCall(curve.buyWithEth, (token, 1e18, type(uint256).max)));
        _assertReentryBlocked();
        assertTrue(curve.getCurve(token).complete);
        assertFalse(curve.getCurve(token).migrated); // migrate did not run inside the buy
    }

    function test_Attack_ReenterFactoryFromCreateRefund() public {
        attacker.arm(address(factory), abi.encodeCall(factory.deployERC20Token, ("X", "X", "", weth)));
        vm.deal(address(attacker), 1 ether);
        attacker.execute(address(factory), 1 ether, abi.encodeCall(factory.deployERC20Token, ("A", "A", "", weth)));
        _assertReentryBlocked();
        assertEq(curve.accruedEth(), 2 * CREATE_FEE); // setUp token + one attacker token
    }

    function test_Attack_MaliciousQuoteHookCannotReenter() public {
        MockHookERC20 hookToken = new MockHookERC20();
        vm.prank(owner);
        curve.setQuote(address(hookToken), 1e18, true);
        address hookedLaunch = _createToken(address(hookToken));

        hookToken.setHook(address(curve), abi.encodeCall(curve.sell, (hookedLaunch, 1, 0)));
        _buy(alice, hookedLaunch, 1e24); // transferFrom triggers the hook mid-buy
        assertFalse(hookToken.hookSucceeded());
        assertEq(hookToken.hookRevertData(), _reentrancyError());

        hookToken.setHook(address(curve), abi.encodeCall(curve.buy, (hookedLaunch, 1, type(uint256).max)));
        _sell(alice, hookedLaunch, 1e23); // transfer of the payout triggers the hook mid-sell
        assertFalse(hookToken.hookSucceeded());
        assertEq(hookToken.hookRevertData(), _reentrancyError());
    }
}
