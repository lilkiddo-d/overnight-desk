// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolAccess} from "../access/ProtocolAccess.sol";
import {IRepoLocker} from "../interfaces/IRepoLocker.sol";
import {IRepoNote} from "../interfaces/IRepoNote.sol";
import {ITermRegistry} from "../interfaces/ITermRegistry.sol";
import {IMarginEngine} from "../interfaces/IMarginEngine.sol";
import {RepoMath} from "../libraries/RepoMath.sol";

/// @title RepoLocker
/// @notice Custodies collateral for every open repo and the stablecoin cash owed to each note series.
///         - Borrowers repay (fully or early, with interest to date), top up or withdraw excess collateral.
///         - Noteholders redeem pro-rata once every repo of their series is closed.
///         - The AuctionHouse opens repos, the MarginEngine flags margin calls, the Liquidator seizes collateral.
///         Repayment and top-ups are deliberately NOT pausable so borrowers can always cure.
contract RepoLocker is ProtocolAccess, ReentrancyGuard, IRepoLocker {
    using SafeERC20 for IERC20;

    bytes32 public constant AUCTION_ROLE = keccak256("AUCTION_ROLE");
    bytes32 public constant MARGIN_ROLE = keccak256("MARGIN_ROLE");
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");

    ITermRegistry public immutable registry;
    IRepoNote public immutable note;
    IERC20 public immutable stable;
    IMarginEngine public marginEngine;

    uint256 public nextSeriesId = 1;
    uint256 public nextRepoId = 1;
    mapping(uint256 => Series) internal _series;
    mapping(uint256 => Repo) internal _repos;
    mapping(address => uint256[]) internal _borrowerRepos;
    /// @notice Pull-payment balances (stablecoin surpluses) per user and token.
    mapping(address => mapping(address => uint256)) public claimable;
    /// @notice Collateral held per token for open repos (accounting mirror used by invariants and monitoring).
    mapping(address => uint256) public lockedCollateral;
    /// @notice Stablecoin owed to series and claimants.
    uint256 public totalStableLiabilities;

    event MarginEngineSet(address engine);
    event SeriesCreated(
        uint256 indexed seriesId,
        uint32 indexed bookId,
        uint64 epoch,
        uint32 rateBps,
        uint64 maturity,
        uint256 principal
    );
    event RepoOpened(
        uint256 indexed repoId,
        uint256 indexed seriesId,
        address indexed borrower,
        address collateral,
        uint256 collateralAmount,
        uint256 principal
    );
    event Repaid(uint256 indexed repoId, address indexed payer, uint256 amount, uint256 remainingPrincipal);
    event RepoClosed(uint256 indexed repoId, uint256 collateralReturned);
    event CollateralAdded(uint256 indexed repoId, address indexed from, uint256 amount);
    event CollateralWithdrawn(uint256 indexed repoId, uint256 amount);
    event AutoRollSet(uint256 indexed repoId, bool enabled, uint32 maxRateBps);
    event RollingSet(uint256 indexed repoId, bool rolling);
    event Rolled(uint256 indexed oldRepoId, uint256 indexed newRepoId, uint256 net, uint256 collateralMoved);
    event MarginCallSet(uint256 indexed repoId, uint64 deadline);
    event MarginCallCleared(uint256 indexed repoId);
    event Seized(uint256 indexed repoId, uint256 collateralAmount, uint256 debt);
    event LiquidationCredited(uint256 indexed repoId, uint256 amount);
    event LiquidationClosed(uint256 indexed repoId, uint256 badDebt);
    event Redeemed(uint256 indexed seriesId, address indexed holder, uint256 units, uint256 payout);
    event Claimed(address indexed user, address indexed token, uint256 amount);

    error NotBorrower();
    error BadStatus();
    error SeriesNotSettled();
    error UnknownSeries();
    error ZeroAmount();
    error InitialMarginBreached();
    error RepoRolling();
    error RateTooHigh();

    constructor(address admin, ITermRegistry registry_, IRepoNote note_) ProtocolAccess(admin) {
        registry = registry_;
        note = note_;
        stable = IERC20(registry_.stablecoin());
    }

    function setMarginEngine(IMarginEngine engine) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(engine) == address(0)) revert ZeroAddress();
        marginEngine = engine;
        emit MarginEngineSet(address(engine));
    }

    // ------------------------------------------------------------------ views

    function getSeries(uint256 seriesId) external view override returns (Series memory) {
        return _series[seriesId];
    }

    function getRepo(uint256 repoId) external view override returns (Repo memory) {
        return _repos[repoId];
    }

    function reposOf(address borrower) external view returns (uint256[] memory) {
        return _borrowerRepos[borrower];
    }

    function debtOf(uint256 repoId) public view override returns (uint256) {
        return debtAt(repoId, block.timestamp);
    }

    /// @notice Principal plus simple interest accrued up to `timestamp` (capped at maturity).
    function debtAt(uint256 repoId, uint256 timestamp) public view override returns (uint256) {
        Repo storage r = _repos[repoId];
        if (r.principal == 0) return 0;
        uint256 end = timestamp < r.maturity ? timestamp : r.maturity;
        uint256 elapsed = end > r.start ? end - r.start : 0;
        return r.principal + RepoMath.interest(r.principal, r.rateBps, elapsed);
    }

    /// @notice Stablecoin a noteholder would receive for `units` of `seriesId` at the current pool size.
    function previewRedeem(uint256 seriesId, uint256 units) public view returns (uint256) {
        Series storage s = _series[seriesId];
        uint256 outstanding = s.principal - s.redeemed;
        if (outstanding == 0) return 0;
        return Math.mulDiv(units, s.cash, outstanding);
    }

    // ------------------------------------------------------------------ auction house hooks

    function createSeries(uint32 bookId, uint64 epoch, uint32 rateBps, uint64 maturity, uint256 principal)
        external
        override
        onlyRole(AUCTION_ROLE)
        returns (uint256 id)
    {
        id = nextSeriesId++;
        _series[id] = Series({
            bookId: bookId,
            epoch: epoch,
            rateBps: rateBps,
            start: uint64(block.timestamp),
            maturity: maturity,
            openRepos: 0,
            principal: uint128(principal),
            cash: 0,
            badDebt: 0,
            redeemed: 0
        });
        emit SeriesCreated(id, bookId, epoch, rateBps, maturity, principal);
    }

    /// @dev Caller must have transferred `collateralAmount` of `collateral` to this contract beforehand.
    function openRepo(
        uint256 seriesId,
        address borrower,
        address collateral,
        uint256 collateralAmount,
        uint256 principal
    ) external override onlyRole(AUCTION_ROLE) returns (uint256) {
        lockedCollateral[collateral] += collateralAmount;
        return _open(seriesId, borrower, collateral, collateralAmount, principal);
    }

    /// @notice Rolls (part of) a maturing repo into a new series. `net` stablecoin must already be in this contract.
    function executeRoll(uint256 oldRepoId, uint256 newSeriesId, uint256 grossPrincipal, uint256 net, uint256 collMove)
        external
        override
        onlyRole(AUCTION_ROLE)
        returns (uint256 newRepoId)
    {
        Repo storage o = _repos[oldRepoId];
        if (o.status != RepoStatus.Active) revert BadStatus();
        o.collateralAmount -= uint128(collMove);
        o.rolling = false;
        newRepoId = _open(newSeriesId, o.borrower, o.collateral, collMove, grossPrincipal);

        uint256 debt = debtOf(oldRepoId);
        uint256 pay = net;
        if (net > debt) {
            pay = debt;
            claimable[o.borrower][address(stable)] += net - debt;
            totalStableLiabilities += net - debt;
        }
        _applyRepayment(oldRepoId, pay, debt, false);
        emit Rolled(oldRepoId, newRepoId, net, collMove);
    }

    function setRolling(uint256 repoId, bool rolling) external override onlyRole(AUCTION_ROLE) {
        _repos[repoId].rolling = rolling;
        emit RollingSet(repoId, rolling);
    }

    // ------------------------------------------------------------------ borrower actions (not pausable)

    /// @notice Repay `amount` (capped at current debt) of a repo. Anyone may repay on behalf of a borrower.
    function repay(uint256 repoId, uint256 amount) external nonReentrant returns (uint256 paid) {
        Repo storage r = _repos[repoId];
        if (r.status != RepoStatus.Active && r.status != RepoStatus.MarginCall) revert BadStatus();
        if (amount == 0) revert ZeroAmount();
        uint256 debt = debtOf(repoId);
        paid = amount < debt ? amount : debt;
        stable.safeTransferFrom(msg.sender, address(this), paid);
        _applyRepayment(repoId, paid, debt, true);
        _tryCure(repoId);
    }

    function addCollateral(uint256 repoId, uint256 amount) external nonReentrant {
        Repo storage r = _repos[repoId];
        if (r.status != RepoStatus.Active && r.status != RepoStatus.MarginCall) revert BadStatus();
        if (amount == 0) revert ZeroAmount();
        IERC20(r.collateral).safeTransferFrom(msg.sender, address(this), amount);
        r.collateralAmount += uint128(amount);
        lockedCollateral[r.collateral] += amount;
        emit CollateralAdded(repoId, msg.sender, amount);
        _tryCure(repoId);
    }

    /// @notice Withdraw collateral in excess of the INITIAL margin requirement.
    function withdrawCollateral(uint256 repoId, uint256 amount) external nonReentrant whenNotPaused {
        Repo storage r = _repos[repoId];
        if (msg.sender != r.borrower) revert NotBorrower();
        if (r.status != RepoStatus.Active) revert BadStatus();
        if (r.rolling) revert RepoRolling();
        if (amount == 0 || amount > r.collateralAmount) revert ZeroAmount();
        uint256 remaining = r.collateralAmount - amount;
        if (!marginEngine.meetsInitialMargin(r.collateral, remaining, debtOf(repoId))) revert InitialMarginBreached();
        r.collateralAmount = uint128(remaining);
        lockedCollateral[r.collateral] -= amount;
        IERC20(r.collateral).safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(repoId, amount);
    }

    /// @notice Opt in/out of auto-rollover into the next auction for the same book, at any rate up to `maxRateBps`.
    function setAutoRoll(uint256 repoId, bool enabled, uint32 maxRateBps) external {
        Repo storage r = _repos[repoId];
        if (msg.sender != r.borrower) revert NotBorrower();
        if (r.status != RepoStatus.Active && r.status != RepoStatus.MarginCall) revert BadStatus();
        if (maxRateBps > registry.getParams().maxRateBps) revert RateTooHigh();
        r.autoRoll = enabled;
        r.autoRollMaxRateBps = maxRateBps;
        emit AutoRollSet(repoId, enabled, maxRateBps);
    }

    function claim(address token) external nonReentrant returns (uint256 amount) {
        amount = claimable[msg.sender][token];
        if (amount == 0) revert ZeroAmount();
        claimable[msg.sender][token] = 0;
        if (token == address(stable)) totalStableLiabilities -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, token, amount);
    }

    // ------------------------------------------------------------------ noteholders

    /// @notice Burn `units` notes of a fully settled series for a pro-rata share of its cash.
    function redeem(uint256 seriesId, uint256 units) external nonReentrant returns (uint256 payout) {
        Series storage s = _series[seriesId];
        if (s.principal == 0) revert UnknownSeries();
        if (s.openRepos != 0) revert SeriesNotSettled();
        if (units == 0) revert ZeroAmount();
        payout = previewRedeem(seriesId, units);
        s.redeemed += uint128(units);
        s.cash -= uint128(payout);
        totalStableLiabilities -= payout;
        note.burn(msg.sender, seriesId, units);
        stable.safeTransfer(msg.sender, payout);
        emit Redeemed(seriesId, msg.sender, units, payout);
    }

    // ------------------------------------------------------------------ margin engine hooks

    function setMarginCall(uint256 repoId, uint64 deadline) external override onlyRole(MARGIN_ROLE) {
        Repo storage r = _repos[repoId];
        if (r.status != RepoStatus.Active) revert BadStatus();
        r.status = RepoStatus.MarginCall;
        r.marginCallDeadline = deadline;
        emit MarginCallSet(repoId, deadline);
    }

    function clearMarginCall(uint256 repoId) external override onlyRole(MARGIN_ROLE) {
        _clearCall(repoId);
    }

    // ------------------------------------------------------------------ liquidator hooks

    function seizeForLiquidation(uint256 repoId)
        external
        override
        onlyRole(LIQUIDATOR_ROLE)
        returns (address collateral, uint256 collateralAmount, uint256 debt, address borrower)
    {
        Repo storage r = _repos[repoId];
        if (r.status != RepoStatus.Active && r.status != RepoStatus.MarginCall) revert BadStatus();
        debt = debtOf(repoId);
        collateral = r.collateral;
        collateralAmount = r.collateralAmount;
        borrower = r.borrower;
        r.status = RepoStatus.Liquidating;
        r.rolling = false;
        r.collateralAmount = 0;
        lockedCollateral[collateral] -= collateralAmount;
        IERC20(collateral).safeTransfer(msg.sender, collateralAmount);
        emit Seized(repoId, collateralAmount, debt);
    }

    /// @dev Caller must have transferred `amount` stablecoin to this contract beforehand.
    function creditLiquidation(uint256 repoId, uint256 amount) external override onlyRole(LIQUIDATOR_ROLE) {
        Repo storage r = _repos[repoId];
        if (r.status != RepoStatus.Liquidating) revert BadStatus();
        _series[r.seriesId].cash += uint128(amount);
        totalStableLiabilities += amount;
        emit LiquidationCredited(repoId, amount);
    }

    function closeLiquidated(uint256 repoId, uint256 badDebt) external override onlyRole(LIQUIDATOR_ROLE) {
        Repo storage r = _repos[repoId];
        if (r.status != RepoStatus.Liquidating) revert BadStatus();
        Series storage s = _series[r.seriesId];
        r.status = RepoStatus.Closed;
        r.principal = 0;
        s.openRepos -= 1;
        s.badDebt += uint128(badDebt);
        emit LiquidationClosed(repoId, badDebt);
    }

    // ------------------------------------------------------------------ internal

    function _open(uint256 seriesId, address borrower, address collateral, uint256 collateralAmount, uint256 principal)
        internal
        returns (uint256 id)
    {
        Series storage s = _series[seriesId];
        if (s.principal == 0) revert UnknownSeries();
        id = nextRepoId++;
        _repos[id] = Repo({
            borrower: borrower,
            bookId: s.bookId,
            status: RepoStatus.Active,
            autoRoll: false,
            rolling: false,
            rateBps: s.rateBps,
            autoRollMaxRateBps: 0,
            start: s.start,
            maturity: s.maturity,
            marginCallDeadline: 0,
            collateral: collateral,
            collateralAmount: uint128(collateralAmount),
            principal: uint128(principal),
            seriesId: seriesId
        });
        s.openRepos += 1;
        _borrowerRepos[borrower].push(id);
        emit RepoOpened(id, seriesId, borrower, collateral, collateralAmount, principal);
    }

    /// @dev `pay` stablecoin is already held by this contract. Pays down debt proportionally across principal
    ///      and accrued interest; a full payment closes the repo and returns all collateral to the borrower
    ///      (pushed directly, or credited as a pull balance when called from inside auction clearing).
    function _applyRepayment(uint256 repoId, uint256 pay, uint256 debt, bool push) internal {
        Repo storage r = _repos[repoId];
        _series[r.seriesId].cash += uint128(pay);
        totalStableLiabilities += pay;
        if (pay >= debt) {
            r.principal = 0;
            r.status = RepoStatus.Closed;
            r.rolling = false;
            _series[r.seriesId].openRepos -= 1;
            uint256 coll = r.collateralAmount;
            r.collateralAmount = 0;
            emit Repaid(repoId, msg.sender, pay, 0);
            if (coll > 0) {
                lockedCollateral[r.collateral] -= coll;
                if (push) IERC20(r.collateral).safeTransfer(r.borrower, coll);
                else claimable[r.borrower][r.collateral] += coll;
            }
            emit RepoClosed(repoId, coll);
        } else {
            uint256 reduce = Math.mulDiv(r.principal, pay, debt);
            r.principal -= uint128(reduce);
            emit Repaid(repoId, msg.sender, pay, r.principal);
        }
    }

    function _tryCure(uint256 repoId) internal {
        Repo storage r = _repos[repoId];
        if (r.status != RepoStatus.MarginCall) return;
        // never let an oracle outage block a cure attempt from completing the repayment / top-up itself
        try marginEngine.isHealthy(repoId) returns (bool healthy) {
            if (healthy) _clearCall(repoId);
        } catch {}
    }

    function _clearCall(uint256 repoId) internal {
        Repo storage r = _repos[repoId];
        if (r.status != RepoStatus.MarginCall) revert BadStatus();
        r.status = RepoStatus.Active;
        r.marginCallDeadline = 0;
        emit MarginCallCleared(repoId);
    }
}
