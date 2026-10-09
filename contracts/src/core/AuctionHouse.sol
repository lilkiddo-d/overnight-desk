// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolAccess} from "../access/ProtocolAccess.sol";
import {ITermRegistry} from "../interfaces/ITermRegistry.sol";
import {IMarketClock} from "../interfaces/IMarketClock.sol";
import {IRepoLocker} from "../interfaces/IRepoLocker.sol";
import {IRepoNote} from "../interfaces/IRepoNote.sol";
import {IMarginEngine} from "../interfaces/IMarginEngine.sol";
import {IProjectTokenHooks} from "../interfaces/IProjectTokenHooks.sol";
import {IComplianceRegistry} from "../interfaces/IComplianceRegistry.sol";
import {ClearingLib} from "../libraries/ClearingLib.sol";
import {RepoMath} from "../libraries/RepoMath.sol";

/// @title AuctionHouse
/// @notice Periodic sealed-bid (commit/reveal) uniform-price batch auctions, one per book (term x collateral)
///         per MarketClock epoch.
///         - Commit: amounts are public and fully escrowed (lenders: stablecoin, borrowers: collateral); only the
///           rate limit is sealed as keccak256(owner, book, epoch, side, amount, collateral, rate, salt).
///         - Reveal: anyone holding the preimage may reveal (allows delegated reveal services). Unrevealed
///           commitments forfeit `noRevealPenaltyBps` of their escrow.
///         - Clear: permissionless after the reveal window; bounded by `maxOrdersPerSide`; one clearing rate.
///         - Settle: pull-based, per order, never paused. Lenders receive ERC-1155 repo notes, borrowers their
///           net proceeds; unfilled escrow is refunded or rolled into the next auction if the order opted in.
///         - Repo auto-roll: maturing repos that opted in enter the next auction as revealed price-taking bids
///           (up to the borrower's max rate) whose proceeds repay the old repo.
contract AuctionHouse is ProtocolAccess, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Side {
        Lend,
        Borrow
    }

    enum State {
        None,
        Committed,
        Revealed,
        Settled,
        Cancelled
    }

    struct Order {
        address owner;
        uint32 bookId;
        uint64 epoch;
        Side side;
        State state;
        bool rollover;
        bool isRepoRoll;
        uint32 rateBps;
        uint128 amount; // principal offered (lend) or requested (borrow)
        uint128 collateral; // escrowed collateral (borrow)
        uint128 filled;
        uint128 proceeds; // borrower net stablecoin owed at settlement
        uint128 lockedCollateral; // collateral moved into a repo
        bytes32 commitment;
        uint256 repoId; // repo opened (borrow) or repo being rolled (repo roll)
        uint256 seriesId;
        uint256 rolledInto;
    }

    struct AuctionResult {
        bool cleared;
        uint32 clearingRateBps;
        uint64 clearedAt;
        uint128 volume;
        uint256 seriesId;
    }

    struct Ctx {
        uint32 bookId;
        uint64 epoch;
        uint64 rollTarget;
        uint32 rate;
        uint32 duration;
        uint16 feeBps;
        address collateral;
        uint256 seriesId;
        uint256 feeTotal;
        uint128 minOrder;
        uint16 maxOrders;
        uint128 collCap;
    }

    ITermRegistry public immutable registry;
    IMarketClock public immutable clock;
    IRepoLocker public immutable locker;
    IRepoNote public immutable note;
    IERC20 public immutable stable;

    IMarginEngine public marginEngine;
    address public feeCollector;
    IProjectTokenHooks public hooks;
    IComplianceRegistry public compliance;

    uint256 public nextOrderId = 1;
    mapping(uint256 => Order) internal _orders;
    // written through storage pointers in _pushToBook / _removeFromBook / _roll (false positive)
    // slither-disable-start uninitialized-state
    mapping(uint32 => mapping(uint64 => uint256[])) internal _lendBook;
    mapping(uint32 => mapping(uint64 => uint256[])) internal _borrowBook;
    // slither-disable-end uninitialized-state
    mapping(uint256 => uint256) internal _bookIndex; // orderId => index + 1
    mapping(uint32 => mapping(uint64 => AuctionResult)) internal _results;
    mapping(uint32 => mapping(uint64 => uint256)) public committedCollateral;
    mapping(address => uint256[]) internal _ordersOf;

    event MarginEngineSet(address engine);
    event FeeCollectorSet(address feeCollector);
    event HooksSet(address hooks);
    event ComplianceSet(address compliance);
    event OrderCommitted(
        uint256 indexed orderId,
        address indexed owner,
        uint32 indexed bookId,
        uint64 epoch,
        Side side,
        uint256 amount,
        uint256 collateral,
        bool rollover
    );
    event OrderRevealed(uint256 indexed orderId, uint32 rateBps);
    event OrderCancelled(uint256 indexed orderId);
    event RepoRollSubmitted(
        uint256 indexed orderId, uint256 indexed repoId, uint64 epoch, uint256 amount, uint32 maxRateBps
    );
    event OrderFilled(uint256 indexed orderId, uint256 filled, uint256 fee, uint256 repoId);
    event OrderRolled(uint256 indexed fromOrderId, uint256 indexed toOrderId, uint64 toEpoch);
    event OrderSettled(
        uint256 indexed orderId, uint256 notes, uint256 stableOut, uint256 collateralOut, uint256 penalty
    );
    event AuctionCleared(
        uint32 indexed bookId,
        uint64 indexed epoch,
        uint32 clearingRateBps,
        uint256 volume,
        uint256 seriesId,
        uint256 fees
    );

    error NotAllowed();
    error BookInactive();
    error WrongPhase();
    error OrderTooSmall();
    error BookFull();
    error BadCommitment();
    error RateOutOfRange();
    error NotOwner();
    error BadState();
    error AlreadyCleared();
    error CollateralCapExceeded();
    error RollNotEligible();
    error ZeroAmount();

    constructor(
        address admin,
        ITermRegistry registry_,
        IMarketClock clock_,
        IRepoLocker locker_,
        IRepoNote note_,
        IMarginEngine engine_,
        address feeCollector_
    ) ProtocolAccess(admin) {
        if (feeCollector_ == address(0) || address(engine_) == address(0)) revert ZeroAddress();
        registry = registry_;
        clock = clock_;
        locker = locker_;
        note = note_;
        stable = IERC20(registry_.stablecoin());
        marginEngine = engine_;
        feeCollector = feeCollector_;
    }

    // ------------------------------------------------------------------ admin

    function setMarginEngine(IMarginEngine engine) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(engine) == address(0)) revert ZeroAddress();
        marginEngine = engine;
        emit MarginEngineSet(address(engine));
    }

    function setFeeCollector(address fc) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (fc == address(0)) revert ZeroAddress();
        feeCollector = fc;
        emit FeeCollectorSet(fc);
    }

    function setHooks(IProjectTokenHooks hooks_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        hooks = hooks_;
        emit HooksSet(address(hooks_));
    }

    function setCompliance(IComplianceRegistry c) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = c;
        emit ComplianceSet(address(c));
    }

    // ------------------------------------------------------------------ views

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    function bookOrders(uint32 bookId, uint64 epoch)
        external
        view
        returns (uint256[] memory lends, uint256[] memory borrows)
    {
        return (_lendBook[bookId][epoch], _borrowBook[bookId][epoch]);
    }

    function getResult(uint32 bookId, uint64 epoch) external view returns (AuctionResult memory) {
        return _results[bookId][epoch];
    }

    function ordersOf(address owner) external view returns (uint256[] memory) {
        return _ordersOf[owner];
    }

    /// @notice Commitment preimage hash. Frontends MUST compute this locally (never via an RPC call, which would
    ///         leak the sealed rate to the RPC provider).
    function commitmentHash(
        address owner,
        uint32 bookId,
        uint64 epoch,
        Side side,
        uint256 amount,
        uint256 collateral,
        uint32 rateBps,
        bytes32 salt
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(owner, bookId, epoch, side, amount, collateral, rateBps, salt));
    }

    // ------------------------------------------------------------------ commit / reveal / cancel

    function commitLend(uint32 bookId, uint256 amount, bytes32 commitment, bool rollover)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 id)
    {
        id = _commit(bookId, Side.Lend, amount, 0, commitment, rollover);
        stable.safeTransferFrom(msg.sender, address(this), amount);
    }

    function commitBorrow(uint32 bookId, uint256 amount, uint256 collateralAmount, bytes32 commitment, bool rollover)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 id)
    {
        if (collateralAmount == 0 || collateralAmount > type(uint128).max) revert ZeroAmount();
        id = _commit(bookId, Side.Borrow, amount, collateralAmount, commitment, rollover);
        address coll = registry.getBook(bookId).collateral;
        IERC20(coll).safeTransferFrom(msg.sender, address(this), collateralAmount);
    }

    /// @notice Reveal a sealed order. Not pausable, so a pause can never force a no-reveal penalty.
    function reveal(uint256 orderId, uint32 rateBps, bytes32 salt) external {
        Order storage o = _orders[orderId];
        if (o.state != State.Committed) revert BadState();
        if (clock.phase(o.epoch) != IMarketClock.Phase.Reveal) revert WrongPhase();
        if (rateBps == 0 || rateBps > registry.getParams().maxRateBps) revert RateOutOfRange();
        bytes32 h = commitmentHash(o.owner, o.bookId, o.epoch, o.side, o.amount, o.collateral, rateBps, salt);
        if (h != o.commitment) revert BadCommitment();
        o.state = State.Revealed;
        o.rateBps = rateBps;
        emit OrderRevealed(orderId, rateBps);
    }

    /// @notice Cancel during the commit phase (also used to opt out of a rolled order). Full refund.
    function cancel(uint256 orderId) external nonReentrant {
        Order storage o = _orders[orderId];
        if (o.owner != msg.sender) revert NotOwner();
        if (o.state != State.Committed && o.state != State.Revealed) revert BadState();
        if (block.timestamp >= clock.commitEnd(o.epoch)) revert WrongPhase();
        _removeFromBook(orderId, o);
        o.state = State.Cancelled;
        emit OrderCancelled(orderId);
        if (o.isRepoRoll) {
            locker.setRolling(o.repoId, false);
        } else if (o.side == Side.Lend) {
            stable.safeTransfer(o.owner, o.amount);
        } else {
            committedCollateral[o.bookId][o.epoch] -= o.collateral;
            IERC20(registry.getBook(o.bookId).collateral).safeTransfer(o.owner, o.collateral);
        }
    }

    /// @notice Enter an opted-in maturing repo into the current auction as a price-taking borrow bid. Permissionless
    ///         (keepers call it); the bid size covers the full debt at maturity plus the auction fee.
    function submitRepoRoll(uint256 repoId) external nonReentrant whenNotPaused returns (uint256 id) {
        IRepoLocker.Repo memory r = locker.getRepo(repoId);
        if (!r.autoRoll || r.rolling || r.status != IRepoLocker.RepoStatus.Active) revert RollNotEligible();
        _checkCompliance(r.borrower);
        if (!registry.isBookActive(r.bookId)) revert BookInactive();
        uint64 epoch = clock.currentEpoch();
        if (clock.phase(epoch) != IMarketClock.Phase.Commit) revert WrongPhase();
        ITermRegistry.Params memory p = registry.getParams();
        uint256 re = clock.revealEnd(epoch);
        if (re > uint256(r.maturity) + p.maturityGracePeriod || r.maturity >= re + clock.interval()) {
            revert RollNotEligible();
        }
        if (_borrowBook[r.bookId][epoch].length >= p.maxOrdersPerSide) revert BookFull();

        uint256 k = RepoMath.BPS * RepoMath.YEAR;
        uint256 dueAtMaturity = locker.debtAt(repoId, r.maturity);
        uint256 gross = Math.mulDiv(
            dueAtMaturity, k, k - uint256(p.auctionFeeBpsPerYear) * registry.bookDuration(r.bookId), Math.Rounding.Ceil
        );

        id = nextOrderId++;
        Order storage o = _orders[id];
        o.owner = r.borrower;
        o.bookId = r.bookId;
        o.epoch = epoch;
        o.side = Side.Borrow;
        o.state = State.Revealed;
        o.isRepoRoll = true;
        o.rateBps = r.autoRollMaxRateBps;
        o.amount = uint128(gross);
        o.repoId = repoId;
        _pushToBook(id, o);
        locker.setRolling(repoId, true);
        emit RepoRollSubmitted(id, repoId, epoch, gross, r.autoRollMaxRateBps);
    }

    // ------------------------------------------------------------------ clearing

    /// @notice Clear one book's auction. Permissionless; callable during the clearing window.
    /// @dev External calls go only to the role-gated RepoLocker / MarginEngine / hooks (trusted protocol contracts)
    ///      and the function is nonReentrant; the series id returned by the locker is needed before order writes.
    // callees are the role-gated RepoLocker / MarginEngine / hooks (trusted protocol contracts); nonReentrant
    // slither-disable-start reentrancy-no-eth
    function clear(uint32 bookId, uint64 epoch) external nonReentrant whenNotPaused returns (AuctionResult memory res) {
        if (_results[bookId][epoch].cleared) revert AlreadyCleared();
        if (clock.phase(epoch) != IMarketClock.Phase.Clearing) revert WrongPhase();

        Ctx memory ctx = _context(bookId, epoch);
        uint256[] storage lIds = _lendBook[bookId][epoch];
        uint256[] storage bIds = _borrowBook[bookId][epoch];
        (uint256[] memory lR, uint256[] memory lA) = _loadLenders(lIds);
        (uint256[] memory bR, uint256[] memory bA) = _loadBorrowers(bIds, ctx.collateral);

        ClearingLib.Result memory cr = ClearingLib.clear(lR, lA, bR, bA);
        ctx.rate = uint32(cr.rateBps);

        if (cr.volume > 0) {
            ctx.seriesId =
                locker.createSeries(bookId, epoch, ctx.rate, uint64(block.timestamp + ctx.duration), cr.volume);
        }
        for (uint256 i; i < lIds.length; ++i) {
            _settleLender(ctx, lIds[i], cr.lendFills[i]);
        }
        for (uint256 j; j < bIds.length; ++j) {
            _settleBorrower(ctx, bIds[j], cr.borrowFills[j], bA[j] > 0);
        }

        res = AuctionResult({
            cleared: true,
            clearingRateBps: cr.volume > 0 ? ctx.rate : 0,
            clearedAt: uint64(block.timestamp),
            volume: uint128(cr.volume),
            seriesId: ctx.seriesId
        });
        _results[bookId][epoch] = res;
        if (ctx.feeTotal > 0) stable.safeTransfer(feeCollector, ctx.feeTotal);
        emit AuctionCleared(bookId, epoch, res.clearingRateBps, cr.volume, ctx.seriesId, ctx.feeTotal);
    }
    // slither-disable-end reentrancy-no-eth

    // ------------------------------------------------------------------ settlement (pull, never paused)

    function settle(uint256 orderId) external nonReentrant {
        Order storage o = _orders[orderId];
        uint256 notes = 0;
        uint256 stableOut = 0;
        uint256 collOut = 0;
        uint256 penalty = 0;
        address coll = registry.getBook(o.bookId).collateral;

        if (o.state == State.Committed) {
            // never revealed: refundable after the reveal window, minus the no-reveal penalty
            if (block.timestamp < clock.revealEnd(o.epoch)) revert WrongPhase();
            uint256 pBps = registry.getParams().noRevealPenaltyBps;
            o.state = State.Settled;
            if (o.side == Side.Lend) {
                penalty = (uint256(o.amount) * pBps) / RepoMath.BPS;
                stableOut = o.amount - penalty;
                if (penalty > 0) stable.safeTransfer(feeCollector, penalty);
            } else {
                penalty = (uint256(o.collateral) * pBps) / RepoMath.BPS;
                collOut = o.collateral - penalty;
                if (penalty > 0) IERC20(coll).safeTransfer(feeCollector, penalty);
            }
        } else if (o.state == State.Revealed) {
            AuctionResult storage res = _results[o.bookId][o.epoch];
            if (!res.cleared) {
                // keeper failure fallback: uncleared auctions become fully refundable at expiry
                if (block.timestamp < clock.expiry(o.epoch)) revert WrongPhase();
                o.state = State.Settled;
                if (o.isRepoRoll) locker.setRolling(o.repoId, false);
                else if (o.side == Side.Lend) stableOut = o.amount;
                else collOut = o.collateral;
            } else {
                o.state = State.Settled;
                bool rolled = o.rolledInto != 0;
                if (o.side == Side.Lend) {
                    notes = o.filled;
                    if (!rolled) stableOut = o.amount - o.filled;
                } else if (!o.isRepoRoll) {
                    stableOut = o.proceeds;
                    if (!rolled) collOut = o.collateral - o.lockedCollateral;
                }
            }
        } else {
            revert BadState();
        }

        emit OrderSettled(orderId, notes, stableOut, collOut, penalty);
        if (notes > 0) note.mint(o.owner, o.seriesId, notes);
        if (stableOut > 0) stable.safeTransfer(o.owner, stableOut);
        if (collOut > 0) IERC20(coll).safeTransfer(o.owner, collOut);
    }

    // ------------------------------------------------------------------ internal: commit

    function _commit(
        uint32 bookId,
        Side side,
        uint256 amount,
        uint256 collateralAmount,
        bytes32 commitment,
        bool rollover
    ) internal returns (uint256 id) {
        _checkCompliance(msg.sender);
        if (!registry.isBookActive(bookId)) revert BookInactive();
        uint64 epoch = clock.currentEpoch();
        if (clock.phase(epoch) != IMarketClock.Phase.Commit) revert WrongPhase();
        ITermRegistry.Params memory p = registry.getParams();
        if (amount < p.minOrderSize || amount > type(uint128).max) revert OrderTooSmall();
        if (commitment == bytes32(0)) revert BadCommitment();
        uint256[] storage bookSide = side == Side.Lend ? _lendBook[bookId][epoch] : _borrowBook[bookId][epoch];
        if (bookSide.length >= p.maxOrdersPerSide) revert BookFull();
        if (side == Side.Borrow) {
            uint256 cap = registry.getCollateral(registry.getBook(bookId).collateral).maxCollateralPerAuction;
            uint256 newTotal = committedCollateral[bookId][epoch] + collateralAmount;
            if (cap != 0 && newTotal > cap) revert CollateralCapExceeded();
            committedCollateral[bookId][epoch] = newTotal;
        }

        id = nextOrderId++;
        Order storage o = _orders[id];
        o.owner = msg.sender;
        o.bookId = bookId;
        o.epoch = epoch;
        o.side = side;
        o.state = State.Committed;
        o.rollover = rollover;
        o.amount = uint128(amount);
        o.collateral = uint128(collateralAmount);
        o.commitment = commitment;
        _pushToBook(id, o);
        emit OrderCommitted(id, msg.sender, bookId, epoch, side, amount, collateralAmount, rollover);
    }

    function _pushToBook(uint256 id, Order storage o) internal {
        uint256[] storage bookSide = o.side == Side.Lend ? _lendBook[o.bookId][o.epoch] : _borrowBook[o.bookId][o.epoch];
        bookSide.push(id);
        _bookIndex[id] = bookSide.length;
        _ordersOf[o.owner].push(id);
    }

    function _removeFromBook(uint256 id, Order storage o) internal {
        uint256[] storage bookSide = o.side == Side.Lend ? _lendBook[o.bookId][o.epoch] : _borrowBook[o.bookId][o.epoch];
        uint256 idx = _bookIndex[id] - 1;
        uint256 lastId = bookSide[bookSide.length - 1];
        bookSide[idx] = lastId;
        _bookIndex[lastId] = idx + 1;
        bookSide.pop();
        delete _bookIndex[id];
    }

    function _checkCompliance(address account) internal view {
        if (address(compliance) != address(0) && !compliance.isAllowed(account)) revert NotAllowed();
    }

    // ------------------------------------------------------------------ internal: clearing

    function _context(uint32 bookId, uint64 epoch) internal view returns (Ctx memory ctx) {
        ITermRegistry.Params memory p = registry.getParams();
        ITermRegistry.Book memory b = registry.getBook(bookId);
        ctx.bookId = bookId;
        ctx.epoch = epoch;
        ctx.collateral = b.collateral;
        ctx.duration = registry.bookDuration(bookId);
        ctx.feeBps = p.auctionFeeBpsPerYear;
        ctx.minOrder = p.minOrderSize;
        ctx.maxOrders = p.maxOrdersPerSide;
        ctx.collCap = registry.getCollateral(b.collateral).maxCollateralPerAuction;
        uint64 cur = clock.currentEpoch();
        ctx.rollTarget = block.timestamp < clock.revealEnd(cur) ? cur : cur + 1;
        if (!registry.isBookActive(bookId)) ctx.rollTarget = 0; // never roll into a disabled book
    }

    function _loadLenders(uint256[] storage ids) internal view returns (uint256[] memory r, uint256[] memory a) {
        uint256 n = ids.length;
        r = new uint256[](n);
        a = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            Order storage o = _orders[ids[i]];
            if (o.state == State.Revealed) {
                r[i] = o.rateBps;
                a[i] = o.amount;
            }
        }
    }

    /// @dev Borrow bids that fail the initial-margin check at the current oracle price are excluded (amount 0).
    function _loadBorrowers(uint256[] storage ids, address coll)
        internal
        view
        returns (uint256[] memory r, uint256[] memory a)
    {
        uint256 n = ids.length;
        r = new uint256[](n);
        a = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            Order storage o = _orders[ids[i]];
            if (o.state != State.Revealed) continue;
            bool ok;
            if (o.isRepoRoll) {
                IRepoLocker.Repo memory rp = locker.getRepo(o.repoId);
                ok = rp.status == IRepoLocker.RepoStatus.Active && rp.rolling
                    && marginEngine.meetsInitialMargin(rp.collateral, rp.collateralAmount, o.amount);
            } else {
                ok = marginEngine.meetsInitialMargin(coll, o.collateral, o.amount);
            }
            if (ok) {
                r[i] = o.rateBps;
                a[i] = o.amount;
            }
        }
    }

    function _settleLender(Ctx memory ctx, uint256 id, uint256 fill) internal {
        Order storage o = _orders[id];
        if (o.state != State.Revealed) return;
        o.filled = uint128(fill);
        o.seriesId = ctx.seriesId;
        if (fill > 0) emit OrderFilled(id, fill, 0, 0);
        uint256 rest = o.amount - fill;
        if (o.rollover && rest > 0) _roll(ctx, id, o, rest, 0);
    }

    // trusted role-gated callees under clear()'s nonReentrant; fill == amount is an exact full-fill check
    // slither-disable-start reentrancy-no-eth,incorrect-equality
    function _settleBorrower(Ctx memory ctx, uint256 id, uint256 fill, bool valid) internal {
        Order storage o = _orders[id];
        if (o.state != State.Revealed) return;
        o.seriesId = ctx.seriesId;
        if (fill == 0) {
            if (o.isRepoRoll) {
                if (locker.getRepo(o.repoId).rolling) locker.setRolling(o.repoId, false);
            } else if (o.rollover && valid) {
                _roll(ctx, id, o, o.amount, o.collateral);
            }
            return;
        }

        uint256 discount = address(hooks) == address(0) ? 0 : hooks.feeDiscountBps(o.owner);
        uint256 fee = RepoMath.fee(fill, ctx.feeBps, ctx.duration, discount);
        uint256 net = fill - fee;
        o.filled = uint128(fill);
        ctx.feeTotal += fee;

        if (o.isRepoRoll) {
            uint256 repoColl = locker.getRepo(o.repoId).collateralAmount;
            uint256 move = fill == o.amount ? repoColl : Math.mulDiv(repoColl, fill, o.amount);
            o.lockedCollateral = uint128(move);
            stable.safeTransfer(address(locker), net);
            o.repoId = locker.executeRoll(o.repoId, ctx.seriesId, fill, net, move);
        } else {
            uint256 locked =
                fill == o.amount ? o.collateral : Math.mulDiv(o.collateral, fill, o.amount, Math.Rounding.Ceil);
            o.lockedCollateral = uint128(locked);
            o.proceeds = uint128(net);
            IERC20(ctx.collateral).safeTransfer(address(locker), locked);
            o.repoId = locker.openRepo(ctx.seriesId, o.owner, ctx.collateral, locked, fill);
            uint256 rest = o.amount - fill;
            if (o.rollover && rest > 0) _roll(ctx, id, o, rest, o.collateral - locked);
        }
        emit OrderFilled(id, fill, fee, o.repoId);
    }

    // slither-disable-end reentrancy-no-eth,incorrect-equality

    /// @dev Carry an unfilled remainder into the next open auction as an already-revealed order (same rate).
    ///      Silently skipped (=> refunded at settlement) if the target book is full, the remainder is below the
    ///      minimum size, or the collateral cap would be exceeded.
    // target == 0 is a sentinel for 'rolling disabled', not a balance check
    // slither-disable-start incorrect-equality
    function _roll(Ctx memory ctx, uint256 fromId, Order storage o, uint256 amount, uint256 coll) internal {
        uint64 target = ctx.rollTarget;
        if (target == 0 || amount < ctx.minOrder) return;
        uint256[] storage dest = o.side == Side.Lend ? _lendBook[ctx.bookId][target] : _borrowBook[ctx.bookId][target];
        if (dest.length >= ctx.maxOrders) return;
        if (o.side == Side.Borrow) {
            uint256 newTotal = committedCollateral[ctx.bookId][target] + coll;
            if (ctx.collCap != 0 && newTotal > ctx.collCap) return;
            committedCollateral[ctx.bookId][target] = newTotal;
        }
        uint256 id = nextOrderId++;
        Order storage n = _orders[id];
        n.owner = o.owner;
        n.bookId = ctx.bookId;
        n.epoch = target;
        n.side = o.side;
        n.state = State.Revealed;
        n.rollover = true;
        n.rateBps = o.rateBps;
        n.amount = uint128(amount);
        n.collateral = uint128(coll);
        _pushToBook(id, n);
        o.rolledInto = id;
        emit OrderRolled(fromId, id, target);
    }
    // slither-disable-end incorrect-equality
}
