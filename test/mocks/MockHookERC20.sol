// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

/// @notice Quote token with an ERC777-style hook: on every transfer it calls back into a
///         configured target, simulating a malicious token that the owner whitelisted by mistake.
contract MockHookERC20 is MockERC20 {
    address public hookTarget;
    bytes public hookData;
    bool public hookSucceeded;
    bytes public hookRevertData;
    bool private _inHook;

    constructor() MockERC20("Hook Token", "HOOK", 18) {}

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (hookTarget != address(0) && !_inHook && from != address(0)) {
            _inHook = true;
            (hookSucceeded, hookRevertData) = hookTarget.call(hookData);
            _inHook = false;
        }
    }
}
