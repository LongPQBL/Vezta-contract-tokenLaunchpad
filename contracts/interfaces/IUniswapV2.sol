// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Uniswap V2 interfaces used by the launchpad.
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function allPairs(uint256 index) external view returns (address pair);
    function allPairsLength() external view returns (uint256);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function mint(address to) external returns (uint256 liquidity);
    function sync() external;
}

interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
