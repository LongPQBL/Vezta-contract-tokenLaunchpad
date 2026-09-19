// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Constant-product bonding curve math with virtual reserves.
/// @dev With 20% of supply kept for the DEX pool (L = 0.2):
///      virtual token T0 = 16/15 * S, virtual quote Q0 = G / 3, floor = S / 5.
///      Selling down to the floor collects exactly 3 * Q0 = G real quote, and the
///      last curve price equals the pool price G / (S / 5) (seamless graduation).
library CurveMath {
    uint256 internal constant BPS = 10_000;

    function initialVirtualToken(uint256 supply) internal pure returns (uint256) {
        return supply * 16 / 15;
    }

    function initialVirtualQuote(uint256 graduationAmount) internal pure returns (uint256) {
        return graduationAmount / 3;
    }

    function floorOf(uint256 supply) internal pure returns (uint256) {
        return supply / 5;
    }

    /// @notice Quote the curve must receive to release `amount` tokens. Rounds up (favours the curve).
    function buyCost(uint256 virtualToken, uint256 virtualQuote, uint256 amount) internal pure returns (uint256) {
        uint256 newVirtualQuote = Math.mulDiv(virtualQuote, virtualToken, virtualToken - amount, Math.Rounding.Ceil);
        return newVirtualQuote - virtualQuote;
    }

    /// @notice Quote the curve releases when `amount` tokens come back. Rounds down (favours the curve).
    function sellOutput(uint256 virtualToken, uint256 virtualQuote, uint256 amount) internal pure returns (uint256) {
        uint256 newVirtualQuote = Math.mulDiv(virtualQuote, virtualToken, virtualToken + amount, Math.Rounding.Ceil);
        return virtualQuote - newVirtualQuote;
    }

    /// @notice Fee on `amount`, rounded down. Dust trades on quotes with very few decimals can round to
    ///         zero fee; the platform accepts that rather than over-charging every other trade.
    function feeOf(uint256 amount, uint256 feeBps) internal pure returns (uint256) {
        return amount * feeBps / BPS;
    }
}
