// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolAccess} from "../access/ProtocolAccess.sol";
import {IMarginEngine} from "../interfaces/IMarginEngine.sol";
import {IRepoLocker} from "../interfaces/IRepoLocker.sol";
import {ITermRegistry} from "../interfaces/ITermRegistry.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {ILiquidator} from "../interfaces/ILiquidator.sol";
import {IMarketClock} from "../interfaces/IMarketClock.sol";
import {RepoMath} from "../libraries/RepoMath.sol";

/// @title MarginEngine
/// @notice Permissionless margin monitoring. `poke` moves a repo through:
///         Active --(debt > value*(1-maintenance))--> MarginCall --(cured)--> Active
///         MarginCall --(grace period elapsed, still short)--> Liquidating
///         Any --(collateral no longer covers debt + penalty, i.e. a gap)--> Liquidating immediately
///         Any --(unpaid past maturity + maturity grace)--> Liquidating
///         Liquidations only start while the reference equity market is open (if market hours are enforced), so
///         a weekend gap is priced on fresh data rather than a stale Friday close.
contract MarginEngine is ProtocolAccess, ReentrancyGuard, IMarginEngine {
    uint256 public constant MAX_BATCH = 100;

    enum Action {
        None,
        MarginCalled,
        Cured,
        Liquidated
    }

    ITermRegistry public immutable registry;
    IRepoLocker public immutable locker;
    IMarketClock public immutable clock;
    IOracleAdapter public oracle;
    ILiquidator public liquidator;

    event OracleSet(address oracle);
    event LiquidatorSet(address liquidator);
    event Poked(uint256 indexed repoId, Action action, uint256 debt, uint256 collateralValue);
    event LiquidationStarted(uint256 indexed repoId, uint256 indexed auctionId);

    error BatchTooLarge();

    constructor(
        address admin,
        ITermRegistry registry_,
        IRepoLocker locker_,
        IMarketClock clock_,
        IOracleAdapter oracle_
    ) ProtocolAccess(admin) {
        registry = registry_;
        locker = locker_;
        clock = clock_;
        oracle = oracle_;
    }

    function setOracle(IOracleAdapter oracle_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(oracle_) == address(0)) revert ZeroAddress();
        oracle = oracle_;
        emit OracleSet(address(oracle_));
    }

    function setLiquidator(ILiquidator liquidator_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(liquidator_) == address(0)) revert ZeroAddress();
        liquidator = liquidator_;
        emit LiquidatorSet(address(liquidator_));
    }

    // ------------------------------------------------------------------ views

    // updatedAt is validated inside the OracleAdapter
    // slither-disable-start unused-return
    function collateralValue(address token, uint256 amount) public view override returns (uint256) {
        if (amount == 0) return 0;
        (uint256 priceE18,) = oracle.getPrice(token);
        return RepoMath.value(
            amount, registry.getCollateral(token).decimals, priceE18, registry.stableDecimals(), Math.Rounding.Floor
        );
    }
    // slither-disable-end unused-return

    function meetsInitialMargin(address token, uint256 collateralAmount, uint256 debt)
        external
        view
        override
        returns (bool)
    {
        uint256 v = collateralValue(token, collateralAmount);
        return debt <= RepoMath.applyHaircut(v, registry.getCollateral(token).initialHaircutBps);
    }

    function isHealthy(uint256 repoId) public view override returns (bool) {
        (uint256 debt,, uint256 maintLimit,) = health(repoId);
        return debt <= maintLimit;
    }

    /// @return debt current debt, value collateral value, maintLimit max debt before a margin call,
    ///         critLimit max debt before immediate liquidation (value net of the liquidation penalty)
    function health(uint256 repoId)
        public
        view
        returns (uint256 debt, uint256 value, uint256 maintLimit, uint256 critLimit)
    {
        IRepoLocker.Repo memory r = locker.getRepo(repoId);
        ITermRegistry.CollateralConfig memory c = registry.getCollateral(r.collateral);
        debt = locker.debtOf(repoId);
        value = collateralValue(r.collateral, r.collateralAmount);
        maintLimit = RepoMath.applyHaircut(value, c.maintenanceHaircutBps);
        critLimit = RepoMath.applyHaircut(value, c.liquidationPenaltyBps);
    }

    function liquidationWindowOpen() public view returns (bool) {
        return clock.isEquityMarketOpen();
    }

    // ------------------------------------------------------------------ keeper entry points

    function poke(uint256 repoId) public nonReentrant whenNotPaused returns (Action) {
        return _poke(repoId);
    }

    /// @notice Bounded batch version for keepers. Never reverts on an individual repo failure.
    function pokeBatch(uint256[] calldata repoIds) external nonReentrant whenNotPaused returns (Action[] memory out) {
        if (repoIds.length > MAX_BATCH) revert BatchTooLarge();
        out = new Action[](repoIds.length);
        for (uint256 i; i < repoIds.length; ++i) {
            try this.pokeExternalSelf(repoIds[i]) returns (Action a) {
                out[i] = a;
            } catch {}
        }
    }

    /// @dev Only callable by this contract (from pokeBatch) to isolate per-repo failures via try/catch.
    function pokeExternalSelf(uint256 repoId) external returns (Action) {
        if (msg.sender != address(this)) revert InvalidParam();
        return _poke(repoId);
    }

    function _poke(uint256 repoId) internal returns (Action action) {
        IRepoLocker.Repo memory r = locker.getRepo(repoId);
        if (r.status != IRepoLocker.RepoStatus.Active && r.status != IRepoLocker.RepoStatus.MarginCall) {
            return Action.None;
        }
        ITermRegistry.Params memory p = registry.getParams();
        (uint256 debt, uint256 value, uint256 maintLimit, uint256 critLimit) = health(repoId);
        bool window = liquidationWindowOpen();

        if (block.timestamp > uint256(r.maturity) + p.maturityGracePeriod) {
            if (window) {
                _liquidate(repoId);
                action = Action.Liquidated;
            }
        } else if (debt <= maintLimit) {
            if (r.status == IRepoLocker.RepoStatus.MarginCall) {
                locker.clearMarginCall(repoId);
                action = Action.Cured;
            }
        } else if (debt > critLimit && window) {
            _liquidate(repoId);
            action = Action.Liquidated;
        } else if (r.status == IRepoLocker.RepoStatus.Active) {
            locker.setMarginCall(repoId, uint64(block.timestamp + p.marginCallGracePeriod));
            action = Action.MarginCalled;
        } else if (block.timestamp >= r.marginCallDeadline && window) {
            _liquidate(repoId);
            action = Action.Liquidated;
        }
        emit Poked(repoId, action, debt, value);
    }

    function _liquidate(uint256 repoId) internal {
        uint256 auctionId = liquidator.start(repoId);
        emit LiquidationStarted(repoId, auctionId);
    }
}
