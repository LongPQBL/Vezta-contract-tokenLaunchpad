// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {VeztaLaunchToken} from "../contracts/VeztaLaunchToken.sol";
import {Units} from "./lib/Units.sol";

/// @notice Owner script to whitelist or update a quote token using human-readable amounts.
///         Env: CURVE (address), QUOTE (address), AMOUNT (e.g. "0.4" or "12000"), ENABLED (default true).
///         Usage: CURVE=0x.. QUOTE=0x.. AMOUNT=0.4 forge script script/SetQuote.s.sol --rpc-url sepolia --account <owner> --broadcast
contract SetQuote is Script {
    function run() external {
        VeztaLaunchToken curve = VeztaLaunchToken(payable(vm.envAddress("CURVE")));
        address quote = vm.envAddress("QUOTE");
        bool enabled = vm.envOr("ENABLED", true);
        uint8 decimals = IERC20Metadata(quote).decimals();
        uint256 raw = Units.parseUnits(vm.envString("AMOUNT"), decimals);

        if (enabled) {
            require(decimals <= 18, "SetQuote: more than 18 decimals is unsupported");
            require(raw >= 10 ** decimals / 1000, "SetQuote: amount below 0.001 token looks like a typo");
        }
        console.log("Quote:", quote);
        console.log("Decimals:", decimals);
        console.log("graduationAmount (raw units):", raw);
        console.log("enabled:", enabled);

        vm.broadcast();
        curve.setQuote(quote, raw, enabled);
    }
}
