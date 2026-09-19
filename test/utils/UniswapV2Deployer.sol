// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @notice Deploys the official Uniswap V2 contracts from vendored, pre-built bytecode
///         (compiled with solc 0.5.16 / 0.6.6, which this project cannot import directly).
library UniswapV2Deployer {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function bytecode(string memory name) internal view returns (bytes memory) {
        return vm.parseBytes(vm.readFile(string.concat("test/uniswap-v2/", name, ".hex")));
    }

    function pairInitCodeHash() internal view returns (bytes32) {
        return keccak256(bytecode("UniswapV2Pair"));
    }

    function deploy(string memory name, bytes memory constructorArgs) internal returns (address addr) {
        bytes memory code = abi.encodePacked(bytecode(name), constructorArgs);
        assembly {
            addr := create(0, add(code, 0x20), mload(code))
        }
        require(addr != address(0), string.concat("UniswapV2Deployer: failed to deploy ", name));
    }

    /// @return factory UniswapV2Factory
    /// @return weth WETH9
    /// @return router UniswapV2Router02
    function deployAll(address feeToSetter) internal returns (address factory, address weth, address router) {
        factory = deploy("UniswapV2Factory", abi.encode(feeToSetter));
        weth = deploy("WETH9", "");
        router = deploy("UniswapV2Router02", abi.encode(factory, weth));
    }
}
