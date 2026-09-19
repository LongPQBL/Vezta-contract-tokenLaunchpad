// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Units} from "../../script/lib/Units.sol";

contract UnitsHarness {
    function parse(string memory value, uint8 decimals) external pure returns (uint256) {
        return Units.parseUnits(value, decimals);
    }
}

contract UnitsTest is Test {
    UnitsHarness internal units = new UnitsHarness();

    function test_ParsesCommonAmounts() public view {
        assertEq(units.parse("4", 18), 4e18);
        assertEq(units.parse("0.4", 18), 4e17);
        assertEq(units.parse("12000", 6), 12_000e6);
        assertEq(units.parse("0.000001", 6), 1);
        assertEq(units.parse("1.5", 6), 1_500_000);
        assertEq(units.parse(".5", 18), 5e17);
    }

    function test_RevertWhen_TooManyDecimals() public {
        vm.expectRevert(abi.encodeWithSelector(Units.TooManyDecimals.selector, "0.0000001", uint8(6)));
        units.parse("0.0000001", 6);
    }

    function test_RevertWhen_NotANumber() public {
        vm.expectRevert(abi.encodeWithSelector(Units.InvalidNumber.selector, "4 ETH"));
        units.parse("4 ETH", 18);
        vm.expectRevert(abi.encodeWithSelector(Units.InvalidNumber.selector, "1.2.3"));
        units.parse("1.2.3", 18);
        vm.expectRevert(abi.encodeWithSelector(Units.InvalidNumber.selector, ""));
        units.parse("", 18);
        vm.expectRevert(abi.encodeWithSelector(Units.InvalidNumber.selector, "."));
        units.parse(".", 18);
    }
}
