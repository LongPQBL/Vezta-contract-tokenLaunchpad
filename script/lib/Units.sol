// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Converts a human-readable decimal string ("0.4", "12000") into the token's smallest unit.
library Units {
    error InvalidNumber(string value);
    error TooManyDecimals(string value, uint8 decimals);

    function parseUnits(string memory value, uint8 decimals) internal pure returns (uint256) {
        bytes memory b = bytes(value);
        if (b.length == 0) revert InvalidNumber(value);
        uint256 whole;
        uint256 frac;
        uint256 fracDigits;
        bool seenDot;
        bool seenDigit;
        for (uint256 i; i < b.length; ++i) {
            bytes1 ch = b[i];
            if (ch == ".") {
                if (seenDot) revert InvalidNumber(value);
                seenDot = true;
                continue;
            }
            if (ch < "0" || ch > "9") revert InvalidNumber(value);
            seenDigit = true;
            uint256 digit = uint8(ch) - 48;
            if (seenDot) {
                if (fracDigits == decimals) revert TooManyDecimals(value, decimals);
                frac = frac * 10 + digit;
                ++fracDigits;
            } else {
                whole = whole * 10 + digit;
            }
        }
        if (!seenDigit) revert InvalidNumber(value);
        return whole * 10 ** decimals + frac * 10 ** (decimals - fracDigits);
    }
}
