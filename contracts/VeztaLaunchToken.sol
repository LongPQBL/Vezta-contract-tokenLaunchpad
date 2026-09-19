// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CurveMath} from "./libraries/CurveMath.sol";
import {PairAddress} from "./libraries/PairAddress.sol";
import {ILaunchToken} from "./interfaces/ILaunchToken.sol";
import {IVeztaLaunchToken} from "./interfaces/IVeztaLaunchToken.sol";
import {IUniswapV2Factory, IUniswapV2Pair, IUniswapV2Router02, IWETH} from "./interfaces/IUniswapV2.sol";

/// @title VeztaLaunchToken
/// @notice Bonding-curve AMM and vault for launchpad tokens. Each curve trades against one
///         whitelisted quote token (WETH, USDC, ...). When 80% of supply is sold the curve
///         completes and anyone can migrate the collected quote plus the remaining 20% of
///         supply into a Uniswap V2 pair, burning the LP tokens.
contract VeztaLaunchToken is IVeztaLaunchToken, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_TRADE_FEE_BPS = 500;
    uint256 public constant MAX_CREATOR_FEE_BPS = 5_000;
    uint256 public constant MIN_GRADUATION_AMOUNT = 1_000_000;
    /// @dev Uniswap V2 reserves are uint112; half of that leaves headroom for rounding and donations.
    uint256 public constant MAX_GRADUATION_AMOUNT = type(uint112).max / 2;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct QuoteConfig {
        bool enabled;
        uint256 graduationAmount;
    }

    struct Curve {
        address quoteToken;
        address creator;
        address pair;
        uint256 virtualTokenReserves;
        uint256 virtualQuoteReserves;
        uint256 initialVirtualQuoteReserves;
        uint256 realTokenReserves;
        uint256 realQuoteReserves;
        uint256 tokenTotalSupply;
        uint256 floor;
        uint256 creatorFeeBps;
        bool complete;
        bool migrated;
    }

    IWETH public immutable weth;
    IUniswapV2Factory public immutable uniswapFactory;
    bytes32 public immutable pairInitCodeHash;

    address public factory;
    address public feeRecipient;
    uint256 public createFee;
    uint256 public tradeFeeBps;
    uint256 public creatorFeeBps;

    mapping(address quote => QuoteConfig) public quotes;
    mapping(address token => Curve) internal curves;

    mapping(address quote => uint256) public accruedQuoteFees;
    uint256 public accruedEth;
    mapping(address creator => mapping(address quote => uint256)) public creatorFees;
    mapping(address quote => uint256) public totalCreatorFees;

    event CreatePool(address indexed mint, address indexed creator, address indexed quoteToken);
    event Trade(
        address indexed mint,
        uint256 quoteAmount,
        uint256 tokenAmount,
        bool isBuy,
        address indexed user,
        uint256 timestamp,
        uint256 virtualQuoteReserves,
        uint256 virtualTokenReserves
    );
    event Complete(address indexed user, address indexed mint, uint256 timestamp);
    event Migrated(address indexed mint, address indexed pair, uint256 quoteAmount, uint256 tokenAmount);
    event QuoteSet(address indexed quote, uint256 graduationAmount, bool enabled);
    event FeesClaimed(address indexed quote, address indexed recipient, uint256 amount);
    event CreateFeesClaimed(address indexed recipient, uint256 amount);
    event CreatorFeesClaimed(address indexed creator, address indexed quote, uint256 amount);
    event FactorySet(address indexed factory);
    event FeeRecipientSet(address indexed feeRecipient);
    event CreateFeeSet(uint256 createFee);
    event TradeFeeBpsSet(uint256 tradeFeeBps);
    event CreatorFeeBpsSet(uint256 creatorFeeBps);

    error NotFactory();
    error CurveExists();
    error CurveNotFound();
    error CurveCompleted();
    error NotCompleted();
    error AlreadyMigrated();
    error SlippageExceeded();
    error InsufficientValue();
    error FeeTooHigh();
    error ZeroAmount();
    error ZeroAddress();
    error QuoteNotEnabled();
    error QuoteNotWeth();
    error QuoteTransferMismatch();
    error PairMismatch();
    error EthTransferFailed();
    error EthNotAccepted();
    error NothingToClaim();
    error GraduationTooSmall();
    error GraduationTooLarge();
    error RenounceDisabled();

    constructor(
        address owner_,
        address feeRecipient_,
        uint256 createFee_,
        uint256 tradeFeeBps_,
        uint256 creatorFeeBps_,
        address router_,
        bytes32 pairInitCodeHash_
    ) Ownable(owner_) {
        if (feeRecipient_ == address(0) || router_ == address(0)) revert ZeroAddress();
        if (tradeFeeBps_ > MAX_TRADE_FEE_BPS || creatorFeeBps_ > MAX_CREATOR_FEE_BPS) revert FeeTooHigh();
        weth = IWETH(IUniswapV2Router02(router_).WETH());
        uniswapFactory = IUniswapV2Factory(IUniswapV2Router02(router_).factory());
        pairInitCodeHash = pairInitCodeHash_;
        feeRecipient = feeRecipient_;
        createFee = createFee_;
        tradeFeeBps = tradeFeeBps_;
        creatorFeeBps = creatorFeeBps_;
    }

    /// @dev Only WETH may send ETH here (when unwrapping in sellForEth).
    receive() external payable {
        if (msg.sender != address(weth)) revert EthNotAccepted();
    }

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------

    function setFactory(address factory_) external onlyOwner {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
        emit FactorySet(factory_);
    }

    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        feeRecipient = feeRecipient_;
        emit FeeRecipientSet(feeRecipient_);
    }

    function setCreateFee(uint256 createFee_) external onlyOwner {
        createFee = createFee_;
        emit CreateFeeSet(createFee_);
    }

    function setTradeFeeBps(uint256 tradeFeeBps_) external onlyOwner {
        if (tradeFeeBps_ > MAX_TRADE_FEE_BPS) revert FeeTooHigh();
        tradeFeeBps = tradeFeeBps_;
        emit TradeFeeBpsSet(tradeFeeBps_);
    }

    /// @notice Applies to tokens created after this call; existing curves keep their snapshot.
    function setCreatorFeeBps(uint256 creatorFeeBps_) external onlyOwner {
        if (creatorFeeBps_ > MAX_CREATOR_FEE_BPS) revert FeeTooHigh();
        creatorFeeBps = creatorFeeBps_;
        emit CreatorFeeBpsSet(creatorFeeBps_);
    }

    /// @notice Whitelists (or disables) a quote token. `graduationAmount` is in the quote's
    ///         smallest unit and applies to tokens created after this call.
    function setQuote(address quote, uint256 graduationAmount, bool enabled) external onlyOwner {
        if (quote == address(0)) revert ZeroAddress();
        if (enabled && graduationAmount < MIN_GRADUATION_AMOUNT) revert GraduationTooSmall();
        if (enabled && graduationAmount > MAX_GRADUATION_AMOUNT) revert GraduationTooLarge();
        quotes[quote] = QuoteConfig(enabled, graduationAmount);
        emit QuoteSet(quote, graduationAmount, enabled);
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ------------------------------------------------------------------
    // Pool creation
    // ------------------------------------------------------------------

    function createPool(address token, uint256 amount, address creator, address quoteToken)
        external
        payable
        nonReentrant
    {
        if (msg.sender != factory) revert NotFactory();
        if (msg.value != createFee) revert InsufficientValue();
        if (amount == 0) revert ZeroAmount();
        QuoteConfig memory config = quotes[quoteToken];
        if (!config.enabled) revert QuoteNotEnabled();
        Curve storage c = curves[token];
        if (c.tokenTotalSupply != 0) revert CurveExists();

        uint256 initialQuote = CurveMath.initialVirtualQuote(config.graduationAmount);
        address pair = PairAddress.compute(address(uniswapFactory), pairInitCodeHash, token, quoteToken);

        c.quoteToken = quoteToken;
        c.creator = creator;
        c.pair = pair;
        c.virtualTokenReserves = CurveMath.initialVirtualToken(amount);
        c.virtualQuoteReserves = initialQuote;
        c.initialVirtualQuoteReserves = initialQuote;
        c.realTokenReserves = amount;
        c.tokenTotalSupply = amount;
        c.floor = CurveMath.floorOf(amount);
        c.creatorFeeBps = creatorFeeBps;
        accruedEth += msg.value;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        ILaunchToken(token).setPair(pair);
        emit CreatePool(token, creator, quoteToken);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function getCurve(address token) external view returns (Curve memory) {
        return curves[token];
    }
}
