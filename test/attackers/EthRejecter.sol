// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Refuses every native ETH transfer, but can still initiate calls.
contract EthRejecter {
    function execute(address to, bytes calldata data) external payable {
        (bool ok, bytes memory ret) = to.call{value: msg.value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    receive() external payable {
        revert("EthRejecter: no ETH");
    }
}
