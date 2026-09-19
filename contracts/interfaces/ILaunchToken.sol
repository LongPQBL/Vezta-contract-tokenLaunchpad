// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Hooks the bonding curve calls on a launched token.
interface ILaunchToken {
    function setPair(address pair) external;
    function openTrading() external;
}
