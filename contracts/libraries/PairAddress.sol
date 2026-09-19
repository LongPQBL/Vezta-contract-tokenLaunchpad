// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Computes Uniswap V2 pair addresses without deploying the pair (CREATE2).
library PairAddress {
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function compute(address factory, bytes32 initCodeHash, address tokenA, address tokenB)
        internal
        pure
        returns (address pair)
    {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(
            uint160(
                uint256(keccak256(abi.encodePacked(hex"ff", factory, keccak256(abi.encodePacked(token0, token1)), initCodeHash)))
            )
        );
    }
}
