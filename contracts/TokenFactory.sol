// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Token} from "./Token.sol";
import {IVeztaLaunchToken} from "./interfaces/IVeztaLaunchToken.sol";

/// @notice Entry point for launching a token: deploys it and seeds its bonding curve.
contract TokenFactory is Ownable2Step, ReentrancyGuard {
    uint256 public constant INITIAL_AMOUNT = 10 ** 27; // 1 billion tokens, 18 decimals

    IVeztaLaunchToken public bondingCurve;

    event TokenCreated(
        address indexed token,
        address indexed creator,
        address indexed quoteToken,
        string name,
        string ticker,
        string metadataURI
    );
    event BondingCurveSet(address indexed bondingCurve);

    error ZeroAddress();
    error BondingCurveNotSet();
    error InsufficientValue();
    error EthTransferFailed();
    error RenounceDisabled();

    constructor(address owner_) Ownable(owner_) {}

    function setBondingCurve(address bondingCurve_) external onlyOwner {
        if (bondingCurve_ == address(0)) revert ZeroAddress();
        bondingCurve = IVeztaLaunchToken(bondingCurve_);
        emit BondingCurveSet(bondingCurve_);
    }

    function deployERC20Token(
        string calldata name,
        string calldata ticker,
        string calldata metadataURI,
        address quoteToken,
        uint32 antiSniperWindow
    ) external payable nonReentrant returns (address token) {
        IVeztaLaunchToken curve = bondingCurve;
        if (address(curve) == address(0)) revert BondingCurveNotSet();
        uint256 fee = curve.createFee();
        if (msg.value < fee) revert InsufficientValue();

        token = address(new Token(name, ticker, INITIAL_AMOUNT, address(curve)));
        _seedCurve(curve, token, fee, quoteToken, antiSniperWindow);
        _refund(msg.value - fee);
        emit TokenCreated(token, msg.sender, quoteToken, name, ticker, metadataURI);
    }

    function _seedCurve(IVeztaLaunchToken curve, address token, uint256 fee, address quoteToken, uint32 window)
        private
    {
        // slither-disable-next-line unused-return (OpenZeppelin ERC20.approve returns true or reverts)
        Token(token).approve(address(curve), INITIAL_AMOUNT);
        curve.createPool{value: fee}(token, INITIAL_AMOUNT, msg.sender, quoteToken, window);
    }

    function _refund(uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
