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
        address quoteToken
    ) external payable nonReentrant returns (address token) {
        IVeztaLaunchToken curve = bondingCurve;
        if (address(curve) == address(0)) revert BondingCurveNotSet();
        uint256 fee = curve.createFee();
        if (msg.value < fee) revert InsufficientValue();

        Token newToken = new Token(name, ticker, INITIAL_AMOUNT, address(curve));
        token = address(newToken);
        // slither-disable-next-line unused-return (OpenZeppelin ERC20.approve returns true or reverts)
        newToken.approve(address(curve), INITIAL_AMOUNT);
        curve.createPool{value: fee}(token, INITIAL_AMOUNT, msg.sender, quoteToken);

        uint256 refund = msg.value - fee;
        if (refund != 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert EthTransferFailed();
        }
        emit TokenCreated(token, msg.sender, quoteToken, name, ticker, metadataURI);
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
