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
        uint256 virtualTokenReserves,
        uint256 fee
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
    error QuoteSupplyTooLarge();
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
        // A holder can donate quote to the (not yet deployed) pair; if that plus the graduation amount
        // exceeded Uniswap V2's uint112 reserves, `migrate` would revert forever and lock the curve.
        if (enabled && IERC20(quote).totalSupply() > type(uint112).max - graduationAmount) {
            revert QuoteSupplyTooLarge();
        }
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

    // ------------------------------------------------------------------
    // Buying
    // ------------------------------------------------------------------

    function buy(address token, uint256 amount, uint256 maxQuoteCost)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        Curve storage c = _activeCurve(token);
        uint256 quoteCost;
        uint256 fee;
        (amountOut, quoteCost, fee) = _quoteBuy(c, amount, maxQuoteCost);
        uint256 total = quoteCost + fee;

        IERC20 quote = IERC20(c.quoteToken);
        uint256 balanceBefore = quote.balanceOf(address(this));
        quote.safeTransferFrom(msg.sender, address(this), total);
        if (quote.balanceOf(address(this)) - balanceBefore != total) revert QuoteTransferMismatch();

        _applyBuy(c, token, amountOut, quoteCost, fee);
    }

    function buyWithEth(address token, uint256 amount, uint256 maxQuoteCost)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        Curve storage c = _activeCurve(token);
        if (c.quoteToken != address(weth)) revert QuoteNotWeth();
        uint256 quoteCost;
        uint256 fee;
        (amountOut, quoteCost, fee) = _quoteBuy(c, amount, maxQuoteCost);
        uint256 total = quoteCost + fee;
        if (msg.value < total) revert InsufficientValue();

        weth.deposit{value: total}();
        _applyBuy(c, token, amountOut, quoteCost, fee);

        uint256 refund = msg.value - total;
        if (refund != 0) _sendEth(msg.sender, refund);
    }

    /// @notice Tokens actually received (clipped at the floor), curve price and fee for a buy.
    function previewBuy(address token, uint256 amount)
        external
        view
        returns (uint256 amountOut, uint256 quoteCost, uint256 fee)
    {
        return _quoteBuy(_activeCurve(token), amount, type(uint256).max);
    }

    function _activeCurve(address token) private view returns (Curve storage c) {
        c = curves[token];
        if (c.tokenTotalSupply == 0) revert CurveNotFound();
        if (c.complete) revert CurveCompleted();
    }

    function _quoteBuy(Curve storage c, uint256 amount, uint256 maxQuoteCost)
        private
        view
        returns (uint256 amountOut, uint256 quoteCost, uint256 fee)
    {
        if (amount == 0) revert ZeroAmount();
        uint256 sellable = c.realTokenReserves - c.floor;
        amountOut = amount > sellable ? sellable : amount;
        quoteCost = CurveMath.buyCost(c.virtualTokenReserves, c.virtualQuoteReserves, amountOut);
        fee = CurveMath.feeOf(quoteCost, tradeFeeBps);
        if (quoteCost + fee > maxQuoteCost) revert SlippageExceeded();
    }

    function _applyBuy(Curve storage c, address token, uint256 amountOut, uint256 quoteCost, uint256 fee) private {
        c.virtualTokenReserves -= amountOut;
        c.virtualQuoteReserves += quoteCost;
        c.realTokenReserves -= amountOut;
        c.realQuoteReserves += quoteCost;
        _accrueFee(c, fee);
        if (c.realTokenReserves == c.floor) {
            c.complete = true;
            emit Complete(msg.sender, token, block.timestamp);
        }
        IERC20(token).safeTransfer(msg.sender, amountOut);
        emit Trade(
            token,
            quoteCost,
            amountOut,
            true,
            msg.sender,
            block.timestamp,
            c.virtualQuoteReserves,
            c.virtualTokenReserves,
            fee
        );
    }

    /// @dev Splits a trade fee between the token creator (snapshot bps) and the platform.
    function _accrueFee(Curve storage c, uint256 fee) private {
        uint256 creatorPart = CurveMath.feeOf(fee, c.creatorFeeBps);
        address quote = c.quoteToken;
        creatorFees[c.creator][quote] += creatorPart;
        totalCreatorFees[quote] += creatorPart;
        accruedQuoteFees[quote] += fee - creatorPart;
    }

    function _sendEth(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    // ------------------------------------------------------------------
    // Selling
    // ------------------------------------------------------------------

    function sell(address token, uint256 amount, uint256 minQuoteOutput)
        external
        nonReentrant
        returns (uint256 payout)
    {
        Curve storage c = _activeCurve(token);
        payout = _sell(c, token, amount, minQuoteOutput);
        IERC20(c.quoteToken).safeTransfer(msg.sender, payout);
    }

    function sellForEth(address token, uint256 amount, uint256 minQuoteOutput)
        external
        nonReentrant
        returns (uint256 payout)
    {
        Curve storage c = _activeCurve(token);
        if (c.quoteToken != address(weth)) revert QuoteNotWeth();
        payout = _sell(c, token, amount, minQuoteOutput);
        weth.withdraw(payout);
        _sendEth(msg.sender, payout);
    }

    /// @notice Gross quote released by the curve and the fee taken from it for a sell.
    function previewSell(address token, uint256 amount) external view returns (uint256 quoteOut, uint256 fee) {
        Curve storage c = _activeCurve(token);
        if (amount == 0) revert ZeroAmount();
        quoteOut = CurveMath.sellOutput(c.virtualTokenReserves, c.virtualQuoteReserves, amount);
        fee = CurveMath.feeOf(quoteOut, tradeFeeBps);
    }

    /// @dev `realQuoteReserves -= quoteOut` is checked arithmetic: selling can never release more
    ///      quote than the curve holds (unreachable in practice, see invariant tests).
    function _sell(Curve storage c, address token, uint256 amount, uint256 minQuoteOutput)
        private
        returns (uint256 payout)
    {
        if (amount == 0) revert ZeroAmount();
        uint256 quoteOut = CurveMath.sellOutput(c.virtualTokenReserves, c.virtualQuoteReserves, amount);
        uint256 fee = CurveMath.feeOf(quoteOut, tradeFeeBps);
        payout = quoteOut - fee;
        if (payout < minQuoteOutput) revert SlippageExceeded();

        c.virtualTokenReserves += amount;
        c.virtualQuoteReserves -= quoteOut;
        c.realTokenReserves += amount;
        c.realQuoteReserves -= quoteOut;
        _accrueFee(c, fee);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Trade(
            token,
            quoteOut,
            amount,
            false,
            msg.sender,
            block.timestamp,
            c.virtualQuoteReserves,
            c.virtualTokenReserves,
            fee
        );
    }

    // ------------------------------------------------------------------
    // Migration
    // ------------------------------------------------------------------

    /// @notice Moves a completed curve's liquidity into its Uniswap V2 pair. Anyone can call.
    function migrate(address token) external nonReentrant {
        Curve storage c = curves[token];
        if (c.tokenTotalSupply == 0) revert CurveNotFound();
        if (!c.complete) revert NotCompleted();
        if (c.migrated) revert AlreadyMigrated();

        c.migrated = true;
        uint256 quoteAmount = c.realQuoteReserves;
        uint256 tokenAmount = c.realTokenReserves;
        c.realQuoteReserves = 0;
        c.realTokenReserves = 0;

        address pair = _addLiquidity(token, c.quoteToken, c.pair, tokenAmount, quoteAmount);
        ILaunchToken(token).openTrading();
        emit Migrated(token, pair, quoteAmount, tokenAmount);
    }

    /// @dev DEX-specific step, kept isolated so another DEX adapter can replace it later.
    function _addLiquidity(address token, address quote, address expectedPair, uint256 tokenAmount, uint256 quoteAmount)
        private
        returns (address pair)
    {
        pair = uniswapFactory.getPair(token, quote);
        if (pair == address(0)) pair = uniswapFactory.createPair(token, quote);
        if (pair != expectedPair) revert PairMismatch();
        IERC20(quote).safeTransfer(pair, quoteAmount);
        IERC20(token).safeTransfer(pair, tokenAmount);
        // slither-disable-next-line unused-return (LP amount is not needed; all LP goes to DEAD)
        IUniswapV2Pair(pair).mint(DEAD);
    }

    // ------------------------------------------------------------------
    // Fee claims (anyone can call; funds only go to the fixed recipient)
    // ------------------------------------------------------------------

    function claimFees(address quote) external nonReentrant {
        uint256 amount = accruedQuoteFees[quote];
        if (amount == 0) revert NothingToClaim();
        accruedQuoteFees[quote] = 0;
        address recipient = feeRecipient;
        IERC20(quote).safeTransfer(recipient, amount);
        emit FeesClaimed(quote, recipient, amount);
    }

    function claimCreateFees() external nonReentrant {
        uint256 amount = accruedEth;
        if (amount == 0) revert NothingToClaim();
        accruedEth = 0;
        address recipient = feeRecipient;
        _sendEth(recipient, amount);
        emit CreateFeesClaimed(recipient, amount);
    }

    function claimCreatorFees(address creator, address quote) external nonReentrant {
        uint256 amount = creatorFees[creator][quote];
        if (amount == 0) revert NothingToClaim();
        creatorFees[creator][quote] = 0;
        totalCreatorFees[quote] -= amount;
        IERC20(quote).safeTransfer(creator, amount);
        emit CreatorFeesClaimed(creator, quote, amount);
    }
}
