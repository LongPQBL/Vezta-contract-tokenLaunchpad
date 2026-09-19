// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CurveMath} from "../../contracts/libraries/CurveMath.sol";

contract CurveMathTest is Test {
    uint256 internal constant S = 1e27;

    function test_InitialParameters() public pure {
        assertEq(CurveMath.initialVirtualToken(S), 1_066_666_666_666_666_666_666_666_666);
        assertEq(CurveMath.initialVirtualQuote(0.4 ether), 133_333_333_333_333_333);
        assertEq(CurveMath.initialVirtualQuote(4 ether), 1_333_333_333_333_333_333);
        assertEq(CurveMath.floorOf(S), 2e26);
    }

    /// @dev Selling 80% of supply in one buy collects the graduation amount (within rounding).
    function testFuzz_GraduationCollectsGraduationAmount(uint256 graduation) public pure {
        graduation = bound(graduation, 1_000_000, 1e24);
        uint256 t0 = CurveMath.initialVirtualToken(S);
        uint256 q0 = CurveMath.initialVirtualQuote(graduation);
        uint256 collected = CurveMath.buyCost(t0, q0, S - CurveMath.floorOf(S));
        assertApproxEqAbs(collected, graduation, 2);
    }

    /// @dev Last curve price equals the pool price after graduation (seamless price).
    function testFuzz_LastCurvePriceEqualsPoolPrice(uint256 graduation) public pure {
        graduation = bound(graduation, 1_000_000, 1e24);
        uint256 floor = CurveMath.floorOf(S);
        uint256 t0 = CurveMath.initialVirtualToken(S);
        uint256 q0 = CurveMath.initialVirtualQuote(graduation);
        uint256 collected = CurveMath.buyCost(t0, q0, S - floor);
        uint256 vT = t0 - (S - floor);
        uint256 vQ = q0 + collected;
        // curve price vQ / vT == pool price collected / floor  <=>  vQ * floor == collected * vT
        assertApproxEqRel(vQ * floor, collected * vT, 1e13); // 0.001%
    }

    function test_PriceRises16xFromLaunchToGraduation() public pure {
        uint256 floor = CurveMath.floorOf(S);
        uint256 t0 = CurveMath.initialVirtualToken(S);
        uint256 q0 = CurveMath.initialVirtualQuote(4 ether);
        uint256 collected = CurveMath.buyCost(t0, q0, S - floor);
        uint256 startPrice = q0 * 1e36 / t0;
        uint256 endPrice = (q0 + collected) * 1e36 / (t0 - (S - floor));
        assertApproxEqRel(endPrice, startPrice * 16, 1e12);
    }

    function testFuzz_BuyNeverDecreasesK(uint256 vT, uint256 vQ, uint256 amount) public pure {
        vT = bound(vT, 1e18, 1e30);
        vQ = bound(vQ, 1_000, 1e30);
        amount = bound(amount, 1, vT - 1);
        uint256 cost = CurveMath.buyCost(vT, vQ, amount);
        assertGe((vT - amount) * (vQ + cost), vT * vQ);
    }

    function testFuzz_SellNeverDecreasesK(uint256 vT, uint256 vQ, uint256 amount) public pure {
        vT = bound(vT, 1e18, 1e30);
        vQ = bound(vQ, 1_000, 1e30);
        amount = bound(amount, 1, 1e30);
        uint256 out = CurveMath.sellOutput(vT, vQ, amount);
        assertGe((vT + amount) * (vQ - out), vT * vQ);
    }

    function testFuzz_BuyThenSellNeverProfits(uint256 vT, uint256 vQ, uint256 amount) public pure {
        vT = bound(vT, 1e18, 1e30);
        vQ = bound(vQ, 1_000, 1e30);
        amount = bound(amount, 1, vT - 1);
        uint256 cost = CurveMath.buyCost(vT, vQ, amount);
        uint256 out = CurveMath.sellOutput(vT - amount, vQ + cost, amount);
        assertLe(out, cost);
    }

    function test_BuyingOneUnitCostsAtLeastOneQuoteUnit() public pure {
        uint256 t0 = CurveMath.initialVirtualToken(S);
        uint256 q0 = CurveMath.initialVirtualQuote(1_000_000); // smallest allowed graduation
        assertGe(CurveMath.buyCost(t0, q0, 1), 1);
    }

    function test_FeeOf() public pure {
        assertEq(CurveMath.feeOf(1 ether, 100), 0.01 ether);
        assertEq(CurveMath.feeOf(99, 100), 0); // rounds down
        assertEq(CurveMath.feeOf(1 ether, 0), 0);
    }
}
