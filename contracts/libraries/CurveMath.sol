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
    /// @dev Launch tax at the very start of the window, on top of the base fee (98% + 1% base is about 99%).
    uint256 internal constant MAX_LAUNCH_TAX_BPS = 9_800;

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

    /// @notice Anti-sniper launch tax rate: starts at MAX_LAUNCH_TAX_BPS and decays linearly to zero over
    ///         `window` seconds. Zero for an empty window or once the window has elapsed.
    function launchTaxBps(uint256 elapsed, uint256 window) internal pure returns (uint256) {
        if (window == 0 || elapsed >= window) return 0;
        return MAX_LAUNCH_TAX_BPS * (window - elapsed) / window;
    }

    /// @notice Tax such that tax / (subtotal + tax) equals `taxBps`. Rounds up (favours the platform).
    function taxOn(uint256 subtotal, uint256 taxBps) internal pure returns (uint256) {
        if (taxBps == 0) return 0;
        return Math.mulDiv(subtotal, taxBps, BPS - taxBps, Math.Rounding.Ceil);
    }

    /// @notice Fee on `amount`, rounded down. Dust trades on quotes with very few decimals can round to
    ///         zero fee; the platform accepts that rather than over-charging every other trade.
    function feeOf(uint256 amount, uint256 feeBps) internal pure returns (uint256) {
        return amount * feeBps / BPS;
    }
}
