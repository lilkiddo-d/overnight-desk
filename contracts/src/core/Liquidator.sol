// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolAccess} from "../access/ProtocolAccess.sol";
import {ILiquidator} from "../interfaces/ILiquidator.sol";
import {IRepoLocker} from "../interfaces/IRepoLocker.sol";
import {ITermRegistry} from "../interfaces/ITermRegistry.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {RepoMath} from "../libraries/RepoMath.sol";

/// @title Liquidator
/// @notice Sells seized collateral by Dutch auction: the price starts at oracle * (1 + premium) and decays
///         linearly to oracle * (1 - floorDiscount) over `duration`. Buyers specify a max price and a deadline.
///         Proceeds repay the series first, then the liquidation penalty (to the FeeCollector); any collateral left
///         once both are covered is returned to the borrower. If collateral runs out first, the shortfall is
///         written off against the series as bad debt. Expired auctions can be restarted at a fresh oracle price.
contract Liquidator is ProtocolAccess, ReentrancyGuard, ILiquidator {
    using SafeERC20 for IERC20;

    bytes32 public constant ENGINE_ROLE = keccak256("ENGINE_ROLE");

    struct Auction {
        uint256 repoId;
        address collateral;
        address borrower;
        uint8 collDecimals;
        bool active;
        uint64 startTime;
        uint128 collateralLeft;
        uint128 debtLeft;
        uint128 penaltyLeft;
        uint128 startPrice; // E18
        uint128 floorPrice; // E18
    }

    ITermRegistry public immutable registry;
    IRepoLocker public immutable locker;
    IERC20 public immutable stable;
    IOracleAdapter public oracle;
    address public feeCollector;

    uint32 public duration = 2 hours;
    uint16 public startPremiumBps = 500; // start 5% above oracle
    uint16 public floorDiscountBps = 1_500; // floor 15% below oracle

    uint256 public nextAuctionId = 1;
    mapping(uint256 => Auction) internal _auctions;
    mapping(uint256 => uint256) public auctionOfRepo;
    mapping(address => mapping(address => uint256)) public claimable;

    event ParamsSet(uint32 duration, uint16 startPremiumBps, uint16 floorDiscountBps);
    event OracleSet(address oracle);
    event FeeCollectorSet(address feeCollector);
    event AuctionStarted(
        uint256 indexed auctionId,
        uint256 indexed repoId,
        uint256 collateral,
        uint256 debt,
        uint256 penalty,
        uint256 startPrice,
        uint256 floorPrice
    );
    event AuctionRestarted(uint256 indexed auctionId, uint256 startPrice, uint256 floorPrice);
    event Bought(uint256 indexed auctionId, address indexed buyer, uint256 collateral, uint256 cost, uint256 price);
    event AuctionSettled(uint256 indexed auctionId, uint256 collateralReturned, uint256 badDebt);
    event Claimed(address indexed user, address indexed token, uint256 amount);

    error NotActive();
    error Expired();
    error PriceAboveMax(uint256 price);
    error NotExpired();
    error NothingToBuy();

    constructor(
        address admin,
        ITermRegistry registry_,
        IRepoLocker locker_,
        IOracleAdapter oracle_,
        address feeCollector_
    ) ProtocolAccess(admin) {
        if (feeCollector_ == address(0)) revert ZeroAddress();
        registry = registry_;
        locker = locker_;
        stable = IERC20(registry_.stablecoin());
        oracle = oracle_;
        feeCollector = feeCollector_;
    }

    function setParams(uint32 duration_, uint16 startPremiumBps_, uint16 floorDiscountBps_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (duration_ < 10 minutes || duration_ > 2 days || startPremiumBps_ > 2_000 || floorDiscountBps_ > 5_000) {
            revert InvalidParam();
        }
        duration = duration_;
        startPremiumBps = startPremiumBps_;
        floorDiscountBps = floorDiscountBps_;
        emit ParamsSet(duration_, startPremiumBps_, floorDiscountBps_);
    }

    function setOracle(IOracleAdapter oracle_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(oracle_) == address(0)) revert ZeroAddress();
        oracle = oracle_;
        emit OracleSet(address(oracle_));
    }

    function setFeeCollector(address fc) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (fc == address(0)) revert ZeroAddress();
        feeCollector = fc;
        emit FeeCollectorSet(fc);
    }

    function getAuction(uint256 auctionId) external view returns (Auction memory) {
        return _auctions[auctionId];
    }

    /// @notice Current Dutch-auction price (USD E18 per whole collateral token).
    function currentPrice(uint256 auctionId) public view returns (uint256) {
        Auction storage a = _auctions[auctionId];
        uint256 elapsed = block.timestamp - a.startTime;
        if (elapsed >= duration) return a.floorPrice;
        return a.startPrice - Math.mulDiv(a.startPrice - a.floorPrice, elapsed, duration);
    }

    function start(uint256 repoId) external override onlyRole(ENGINE_ROLE) returns (uint256 id) {
        (address coll, uint256 amount, uint256 debt, address borrower) = locker.seizeForLiquidation(repoId);
        ITermRegistry.CollateralConfig memory c = registry.getCollateral(coll);
        (uint256 sp, uint256 fp) = _prices(coll);
        uint256 penalty = Math.mulDiv(debt, c.liquidationPenaltyBps, RepoMath.BPS);
        id = nextAuctionId++;
        _auctions[id] = Auction({
            repoId: repoId,
            collateral: coll,
            borrower: borrower,
            collDecimals: c.decimals,
            active: true,
            startTime: uint64(block.timestamp),
            collateralLeft: uint128(amount),
            debtLeft: uint128(debt),
            penaltyLeft: uint128(penalty),
            startPrice: uint128(sp),
            floorPrice: uint128(fp)
        });
        auctionOfRepo[repoId] = id;
        emit AuctionStarted(id, repoId, amount, debt, penalty, sp, fp);
        if (amount == 0) locker.closeLiquidated(repoId, _closeAuction(id));
    }

    // exact-zero checks on amounts the contract itself tracks (not external balances)
    // slither-disable-start incorrect-equality
    /// @notice Buy up to `maxCollateral` at the current price if it is <= `maxPriceE18`, before `deadline`.
    function buy(uint256 auctionId, uint256 maxCollateral, uint256 maxPriceE18, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 take, uint256 cost)
    {
        if (block.timestamp > deadline) revert Expired();
        Auction storage a = _auctions[auctionId];
        if (!a.active) revert NotActive();
        uint256 price = currentPrice(auctionId);
        if (price > maxPriceE18) revert PriceAboveMax(price);

        (take, cost) = _quote(a, maxCollateral, price);

        uint256 toDebt = Math.min(cost, a.debtLeft);
        uint256 toPenalty = cost - toDebt;
        a.collateralLeft -= uint128(take);
        a.debtLeft -= uint128(toDebt);
        a.penaltyLeft -= uint128(toPenalty);
        uint256 repoId = a.repoId;
        address coll = a.collateral;
        // all effects (including settlement) happen before any interaction (checks-effects-interactions)
        bool done = (a.debtLeft == 0 && a.penaltyLeft == 0) || a.collateralLeft == 0;
        uint256 badDebt = done ? _closeAuction(auctionId) : 0;
        emit Bought(auctionId, msg.sender, take, cost, price);

        stable.safeTransferFrom(msg.sender, address(this), cost);
        _payout(repoId, toDebt, toPenalty);
        IERC20(coll).safeTransfer(msg.sender, take);
        if (done) locker.closeLiquidated(repoId, badDebt);
    }

    /// @dev Collateral to hand over (capped at what covers the remaining debt + penalty) and its stablecoin cost.
    function _quote(Auction storage a, uint256 maxCollateral, uint256 price)
        internal
        view
        returns (uint256 take, uint256 cost)
    {
        uint8 sd = registry.stableDecimals();
        uint256 owed = uint256(a.debtLeft) + a.penaltyLeft;
        uint256 needed = RepoMath.collateralFor(owed, a.collDecimals, price, sd);
        take = Math.min(Math.min(maxCollateral, a.collateralLeft), needed);
        if (take == 0) revert NothingToBuy();
        cost = RepoMath.value(take, a.collDecimals, price, sd, Math.Rounding.Ceil);
        if (cost > owed) cost = owed;
        if (cost == 0) revert NothingToBuy();
    }
    // slither-disable-end incorrect-equality

    function _payout(uint256 repoId, uint256 toDebt, uint256 toPenalty) internal {
        if (toDebt > 0) {
            stable.safeTransfer(address(locker), toDebt);
            locker.creditLiquidation(repoId, toDebt);
        }
        if (toPenalty > 0) stable.safeTransfer(feeCollector, toPenalty);
    }

    /// @notice Restart an auction that reached its floor without clearing, at a fresh oracle price.
    function restart(uint256 auctionId) external nonReentrant whenNotPaused {
        Auction storage a = _auctions[auctionId];
        if (!a.active) revert NotActive();
        if (block.timestamp < uint256(a.startTime) + duration) revert NotExpired();
        (uint256 sp, uint256 fp) = _prices(a.collateral);
        a.startPrice = uint128(sp);
        a.floorPrice = uint128(fp);
        a.startTime = uint64(block.timestamp);
        emit AuctionRestarted(auctionId, sp, fp);
    }

    function claim(address token) external nonReentrant returns (uint256 amount) {
        amount = claimable[msg.sender][token];
        if (amount == 0) revert NothingToBuy();
        claimable[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, token, amount);
    }

    /// @dev Marks the auction finished and books returned collateral; returns the unrecovered debt.
    function _closeAuction(uint256 auctionId) internal returns (uint256 badDebt) {
        Auction storage a = _auctions[auctionId];
        a.active = false;
        uint256 returned = a.collateralLeft;
        badDebt = a.debtLeft;
        a.collateralLeft = 0;
        a.penaltyLeft = 0;
        if (returned > 0) claimable[a.borrower][a.collateral] += returned;
        emit AuctionSettled(auctionId, returned, badDebt);
    }

    // updatedAt is validated inside the OracleAdapter
    // slither-disable-start unused-return
    function _prices(address coll) internal view returns (uint256 sp, uint256 fp) {
        (uint256 p,) = oracle.getPrice(coll);
        sp = Math.mulDiv(p, RepoMath.BPS + startPremiumBps, RepoMath.BPS);
        fp = Math.mulDiv(p, RepoMath.BPS - floorDiscountBps, RepoMath.BPS);
    }
    // slither-disable-end unused-return
}
