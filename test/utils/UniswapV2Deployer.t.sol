// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniswapV2Deployer} from "./UniswapV2Deployer.sol";
import {PairAddress} from "../../contracts/libraries/PairAddress.sol";
import {IUniswapV2Factory, IUniswapV2Router02} from "../../contracts/interfaces/IUniswapV2.sol";

contract UniswapV2DeployerTest is Test {
    bytes32 internal constant OFFICIAL_INIT_CODE_HASH =
        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

    function test_DeploysOfficialUniswapV2() public {
        (address factory, address weth, address router) = UniswapV2Deployer.deployAll(address(this));
        assertEq(IUniswapV2Router02(router).factory(), factory);
        assertEq(IUniswapV2Router02(router).WETH(), weth);
    }

    function test_PairInitCodeHashMatchesOfficialValue() public view {
        assertEq(UniswapV2Deployer.pairInitCodeHash(), OFFICIAL_INIT_CODE_HASH);
    }

    function testFuzz_ComputedPairAddressMatchesFactory(address tokenA, address tokenB) public {
        vm.assume(tokenA != tokenB && tokenA != address(0) && tokenB != address(0));
        (address factory,,) = UniswapV2Deployer.deployAll(address(this));
        address predicted = PairAddress.compute(factory, UniswapV2Deployer.pairInitCodeHash(), tokenA, tokenB);
        address created = IUniswapV2Factory(factory).createPair(tokenA, tokenB);
        assertEq(created, predicted);
    }
}
