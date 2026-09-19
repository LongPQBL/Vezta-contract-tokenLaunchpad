// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VeztaLaunchToken} from "../contracts/VeztaLaunchToken.sol";
import {TokenFactory} from "../contracts/TokenFactory.sol";
import {PairAddress} from "../contracts/libraries/PairAddress.sol";
import {IUniswapV2Factory, IUniswapV2Pair, IUniswapV2Router02} from "../contracts/interfaces/IUniswapV2.sol";

/// @notice Deploys and wires TokenFactory + VeztaLaunchToken from deploy/<DEPLOY_CONFIG>.json.
///         Zero `owner` / `feeRecipient` in the config mean "use the deployer".
///         Usage: forge script script/Deploy.s.sol --rpc-url sepolia --account <keystore> --broadcast --verify
contract Deploy is Script {
    struct Config {
        address owner;
        address feeRecipient;
        uint256 createFee;
        uint256 tradeFeeBps;
        uint256 creatorFeeBps;
        address router;
        bytes32 pairInitCodeHash;
        uint256 wethGraduationAmount;
    }

    function run() external returns (VeztaLaunchToken curve, TokenFactory factory) {
        Config memory cfg = loadConfig(vm.envOr("DEPLOY_CONFIG", string("sepolia")));
        verifyUniswap(cfg.router, cfg.pairInitCodeHash);

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address finalOwner = cfg.owner == address(0) ? deployer : cfg.owner;
        address feeRecipient = cfg.feeRecipient == address(0) ? deployer : cfg.feeRecipient;

        curve = new VeztaLaunchToken(
            deployer, feeRecipient, cfg.createFee, cfg.tradeFeeBps, cfg.creatorFeeBps, cfg.router, cfg.pairInitCodeHash
        );
        factory = new TokenFactory(deployer);
        factory.setBondingCurve(address(curve));
        curve.setFactory(address(factory));
        curve.setQuote(IUniswapV2Router02(cfg.router).WETH(), cfg.wethGraduationAmount, true);

        if (finalOwner != deployer) {
            // Two-step: finalOwner must call acceptOwnership() on both contracts.
            curve.transferOwnership(finalOwner);
            factory.transferOwnership(finalOwner);
        }
        vm.stopBroadcast();

        console.log("VeztaLaunchToken:", address(curve));
        console.log("TokenFactory:    ", address(factory));
        console.log("Owner (pending if different from deployer):", finalOwner);
    }

    function loadConfig(string memory name) public view returns (Config memory cfg) {
        string memory json = vm.readFile(string.concat("deploy/", name, ".json"));
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "Deploy: config is for another chain");
        cfg.owner = vm.parseJsonAddress(json, ".owner");
        cfg.feeRecipient = vm.parseJsonAddress(json, ".feeRecipient");
        cfg.createFee = vm.parseJsonUint(json, ".createFee");
        cfg.tradeFeeBps = vm.parseJsonUint(json, ".tradeFeeBps");
        cfg.creatorFeeBps = vm.parseJsonUint(json, ".creatorFeeBps");
        cfg.router = vm.parseJsonAddress(json, ".router");
        cfg.pairInitCodeHash = vm.parseJsonBytes32(json, ".pairInitCodeHash");
        cfg.wethGraduationAmount = vm.parseJsonUint(json, ".wethGraduationAmount");
    }

    /// @notice Fails unless the router is live and the init code hash reproduces an existing pair address.
    function verifyUniswap(address router, bytes32 pairInitCodeHash) public view {
        address uniFactory = IUniswapV2Router02(router).factory();
        address weth = IUniswapV2Router02(router).WETH();
        require(uniFactory != address(0) && weth != address(0), "Deploy: router not live");
        require(IUniswapV2Factory(uniFactory).allPairsLength() > 0, "Deploy: no pair to verify init code hash");
        address pair = IUniswapV2Factory(uniFactory).allPairs(0);
        address computed =
            PairAddress.compute(uniFactory, pairInitCodeHash, IUniswapV2Pair(pair).token0(), IUniswapV2Pair(pair).token1());
        require(computed == pair, "Deploy: pairInitCodeHash does not match this DEX");
    }
}
