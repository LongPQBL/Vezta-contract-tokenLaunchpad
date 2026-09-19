// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

/// @notice Issuer can freeze addresses, like USDC.
contract MockBlacklistERC20 is MockERC20 {
    mapping(address => bool) public blacklisted;

    constructor() MockERC20("Frozen USD", "FUSD", 6) {}

    function setBlacklisted(address account, bool value) external {
        blacklisted[account] = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blacklisted[from] && !blacklisted[to], "blacklisted");
        super._update(from, to, value);
    }
}
