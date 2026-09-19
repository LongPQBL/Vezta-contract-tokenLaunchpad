// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice A holder of the whole allowed quote supply must not be able to brick `migrate` by
///         donating it to the (not yet deployed) pair: Uniswap V2 reserves are uint112.
contract SupplyLimitTest is BaseTest {
    function test_Attack_WholeAllowedSupplyDonatedToPairCannotBrickMigrate() public {
        MockERC20 whale = new MockERC20("Whale", "WHL", 18);
        uint256 graduation = 1_000 ether;
        uint256 supply = type(uint112).max - graduation;
        whale.mint(alice, supply);
        vm.prank(owner);
        curve.setQuote(address(whale), graduation, true);

        address token = _createToken(address(whale));
        address pair = curve.getCurve(token).pair;
        vm.prank(alice);
        whale.transfer(pair, supply); // donated to an address that has no code yet

        _buyToCompletion(bob, token);
        curve.migrate(token);

        assertTrue(curve.getCurve(token).migrated);
    }
}
