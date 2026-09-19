// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Attacker contract: whenever it receives ETH it tries to call back into `target`.
///         The outcome of the re-entrant call is recorded so tests can assert it was blocked.
contract ReentrantReceiver {
    address public target;
    bytes public payload;
    bool public attempted;
    bool public reentrySucceeded;
    bytes public reentryRevertData;

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        attempted = false;
    }

    function execute(address to, uint256 value, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    function approve(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    receive() external payable {
        if (target != address(0) && !attempted) {
            attempted = true;
            (reentrySucceeded, reentryRevertData) = target.call(payload);
        }
    }
}
