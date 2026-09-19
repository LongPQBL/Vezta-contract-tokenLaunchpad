// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ILaunchToken} from "./interfaces/ILaunchToken.sol";

/// @notice Launchpad token. Until the curve migrates, nobody but the bonding curve can
///         send tokens into the token's Uniswap pair, so nobody can seed the pool price first.
contract Token is ERC20, ILaunchToken {
    error NotBondingCurve();
    error PairAlreadySet();
    error TransferToPairLocked();

    address public immutable bondingCurve;
    address public pair;
    bool public tradingOpen;

    constructor(string memory name_, string memory symbol_, uint256 supply, address bondingCurve_)
        ERC20(name_, symbol_)
    {
        bondingCurve = bondingCurve_;
        _mint(msg.sender, supply);
    }

    modifier onlyBondingCurve() {
        if (msg.sender != bondingCurve) revert NotBondingCurve();
        _;
    }

    function setPair(address pair_) external onlyBondingCurve {
        if (pair != address(0)) revert PairAlreadySet();
        pair = pair_;
    }

    function openTrading() external onlyBondingCurve {
        tradingOpen = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!tradingOpen && to == pair && pair != address(0) && from != bondingCurve) {
            revert TransferToPairLocked();
        }
        super._update(from, to, value);
    }
}
