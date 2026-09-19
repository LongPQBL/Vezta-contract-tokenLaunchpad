// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Subset of VeztaLaunchToken used by TokenFactory.
interface IVeztaLaunchToken {
    function createFee() external view returns (uint256);
    function createPool(address token, uint256 amount, address creator, address quoteToken, uint32 antiSniperWindow)
        external
        payable;
}
