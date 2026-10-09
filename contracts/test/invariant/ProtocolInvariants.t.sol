// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {ProtocolDeployer} from "../../script/ProtocolDeployer.sol";
import {MockERC20, MockAggregator} from "../utils/Mocks.sol";
import {AuctionHouse} from "../../src/core/AuctionHouse.sol";
import {Liquidator} from "../../src/core/Liquidator.sol";
import {IRepoLocker} from "../../src/interfaces/IRepoLocker.sol";
import {IMarketClock} from "../../src/interfaces/IMarketClock.sol";

/// @notice Drives the whole protocol with random but phase-aware actions. A keeper sweep (`pokeAll`) runs after
///         every action, modelling a live keeper.
contract Handler is Test {
    ProtocolDeployer.Deployment internal d;
    MockERC20 internal usdc;
    MockERC20 internal stock;
    MockAggregator internal feed;
    uint32[2] internal books;
    address[2] internal lenders;
    address[2] internal borrowers;
    address internal buyer;

    struct Pending {
        uint256 id;
        uint32 rate;
        bytes32 salt;
        bool skipReveal;
    }

    Pending[] internal pending;
    uint256[] public allOrders;
    uint256 internal saltNonce;

    mapping(bytes32 => uint256) public calls;

    constructor(
        ProtocolDeployer.Deployment memory d_,
        MockERC20 usdc_,
        MockERC20 stock_,
        MockAggregator feed_,
        uint32 b0,
        uint32 b1,
        address[4] memory actors,
        address buyer_
    ) {
        d = d_;
        usdc = usdc_;
        stock = stock_;
        feed = feed_;
        books = [b0, b1];
        lenders = [actors[0], actors[1]];
        borrowers = [actors[2], actors[3]];
        buyer = buyer_;
    }

    function orderCount() external view returns (uint256) {
        return allOrders.length;
    }

    // ------------------------------------------------------------------ actions

    struct C {
        uint64 e;
        uint32 bookId;
        uint256 amount;
        uint32 rate;
        bytes32 salt;
        bool rollover;
    }

    function commit(uint256 seed, uint256 amount, uint32 rate, bool lend, bool rollover) external {
        C memory c;
        c.e = d.clock.currentEpoch();
        if (d.clock.phase(c.e) != IMarketClock.Phase.Commit) return _after();
        c.bookId = books[seed % 2];
        c.rate = uint32(bound(rate, 1, 2_000));
        c.amount = bound(amount, 100e6, 200_000e6);
        c.salt = keccak256(abi.encode(++saltNonce));
        c.rollover = rollover;
        uint256 id = lend ? _lend(c, lenders[(seed >> 8) % 2]) : _borrow(c, borrowers[(seed >> 8) % 2], seed);
        if (id == 0) return _after();
        pending.push(Pending({id: id, rate: c.rate, salt: c.salt, skipReveal: (seed >> 32) % 13 == 0}));
        allOrders.push(id);
        calls["commit"]++;
        _after();
    }

    function _lend(C memory c, address who) internal returns (uint256 id) {
        bytes32 h =
            d.auctionHouse.commitmentHash(who, c.bookId, c.e, AuctionHouse.Side.Lend, c.amount, 0, c.rate, c.salt);
        vm.prank(who);
        try d.auctionHouse.commitLend(c.bookId, c.amount, h, c.rollover) returns (uint256 x) {
            id = x;
        } catch {}
    }

    function _borrow(C memory c, address who, uint256 seed) internal returns (uint256 id) {
        (uint256 p,) = d.oracle.getPrice(address(stock));
        // collateral between 1.25x and 2.55x of the loan value (some fail the initial check at clearing)
        uint256 coll = (c.amount * 1e30 / p) * (125 + ((seed >> 16) % 130)) / 100;
        bytes32 h =
            d.auctionHouse.commitmentHash(who, c.bookId, c.e, AuctionHouse.Side.Borrow, c.amount, coll, c.rate, c.salt);
        vm.prank(who);
        try d.auctionHouse.commitBorrow(c.bookId, c.amount, coll, h, c.rollover) returns (uint256 x) {
            id = x;
        } catch {}
    }

    /// @notice Drives a complete auction: jump to the next commit phase, place 2-8 random orders on both sides,
    ///         reveal (most of) them, clear and settle.
    function auctionCycle(uint256 seed, uint8 nOrders) external {
        uint64 e = d.clock.currentEpoch() + 1;
        vm.warp(d.clock.epochStart(e));
        feed.set(feed.answer());
        _after();
        uint256 n = bound(nOrders, 2, 8);
        for (uint256 i; i < n; ++i) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            C memory c;
            c.e = e;
            c.bookId = books[h % 2];
            c.rate = uint32(200 + (h >> 8) % 800);
            c.amount = 100e6 + (h >> 24) % 100_000e6;
            c.salt = keccak256(abi.encode(++saltNonce));
            c.rollover = (h >> 64) % 3 == 0;
            uint256 id = i % 2 == 0 ? _lend(c, lenders[(h >> 72) % 2]) : _borrow(c, borrowers[(h >> 72) % 2], h);
            if (id == 0) continue;
            pending.push(Pending({id: id, rate: c.rate, salt: c.salt, skipReveal: (h >> 96) % 17 == 0}));
            allOrders.push(id);
            calls["commit"]++;
        }
        vm.warp(d.clock.commitEnd(e));
        feed.set(feed.answer());
        _after();
        this.revealAll();
        vm.warp(d.clock.revealEnd(e));
        feed.set(feed.answer());
        this.clearAll();
        this.settleAll();
    }

    function revealAll() external {
        for (uint256 i; i < pending.length; ++i) {
            Pending memory p = pending[i];
            if (p.skipReveal) continue;
            AuctionHouse.Order memory o = d.auctionHouse.getOrder(p.id);
            if (o.state != AuctionHouse.State.Committed) continue;
            if (d.clock.phase(o.epoch) != IMarketClock.Phase.Reveal) continue;
            d.auctionHouse.reveal(p.id, p.rate, p.salt);
            calls["reveal"]++;
        }
        _after();
    }

    function clearAll() external {
        uint64 cur = d.clock.currentEpoch();
        for (uint64 e = cur > 1 ? cur - 1 : 0; e <= cur; ++e) {
            if (d.clock.phase(e) != IMarketClock.Phase.Clearing) continue;
            for (uint256 b; b < 2; ++b) {
                if (d.auctionHouse.getResult(books[b], e).cleared) continue;
                d.auctionHouse.clear(books[b], e);
                calls["clear"]++;
            }
        }
        _trackNewOrders();
        _after();
    }

    function settleAll() external {
        for (uint256 i; i < allOrders.length; ++i) {
            try d.auctionHouse.settle(allOrders[i]) {
                calls["settle"]++;
            } catch {}
        }
        _after();
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 10 minutes, 30 hours);
        vm.warp(block.timestamp + secs);
        feed.set(feed.answer());
        _after();
    }

    function movePrice(int256 bps) external {
        bps = bound(bps, -1_500, 1_500);
        int256 p = feed.answer() * (10_000 + bps) / 10_000;
        if (p < 20e8) p = 20e8;
        if (p > 2_000e8) p = 2_000e8;
        feed.set(p);
        calls["price"]++;
        _after();
    }

    function repay(uint256 seed, uint256 frac) external {
        uint256 n = d.locker.nextRepoId();
        if (n == 1) return _after();
        uint256 id = 1 + seed % (n - 1);
        IRepoLocker.Repo memory r = d.locker.getRepo(id);
        if (r.status != IRepoLocker.RepoStatus.Active && r.status != IRepoLocker.RepoStatus.MarginCall) {
            return _after();
        }
        uint256 debt = d.locker.debtOf(id);
        uint256 amt = frac % 3 == 0 ? debt : (debt * bound(frac, 1, 99)) / 100;
        if (amt == 0) return _after();
        vm.prank(r.borrower);
        d.locker.repay(id, amt);
        calls["repay"]++;
        _after();
    }

    function topUp(uint256 seed, uint256 amt) external {
        uint256 n = d.locker.nextRepoId();
        if (n == 1) return _after();
        uint256 id = 1 + seed % (n - 1);
        IRepoLocker.Repo memory r = d.locker.getRepo(id);
        if (r.status != IRepoLocker.RepoStatus.Active && r.status != IRepoLocker.RepoStatus.MarginCall) {
            return _after();
        }
        amt = bound(amt, 1e15, 500e18);
        vm.prank(r.borrower);
        d.locker.addCollateral(id, amt);
        calls["topUp"]++;
        _after();
    }

    function autoRoll(uint256 seed) external {
        uint256 n = d.locker.nextRepoId();
        if (n == 1) return _after();
        uint256 id = 1 + seed % (n - 1);
        IRepoLocker.Repo memory r = d.locker.getRepo(id);
        if (r.status != IRepoLocker.RepoStatus.Active) return _after();
        if (!r.autoRoll) {
            vm.prank(r.borrower);
            d.locker.setAutoRoll(id, true, 2_000);
        }
        try d.auctionHouse.submitRepoRoll(id) returns (uint256 oid) {
            allOrders.push(oid);
            calls["roll"]++;
        } catch {}
        _after();
    }

    function buyLiquidations(uint256 seed) external {
        uint256 n = d.liquidator.nextAuctionId();
        for (uint256 i = 1; i < n; ++i) {
            Liquidator.Auction memory a = d.liquidator.getAuction(i);
            if (!a.active) continue;
            if (block.timestamp >= uint256(a.startTime) + d.liquidator.duration()) {
                try d.liquidator.restart(i) {} catch {}
            }
            uint256 maxColl = seed % 2 == 0 ? type(uint256).max : a.collateralLeft / 2 + 1;
            vm.prank(buyer);
            try d.liquidator.buy(i, maxColl, type(uint256).max, block.timestamp) {
                calls["liqBuy"]++;
            } catch {}
        }
        _after();
    }

    function redeemAll() external {
        uint256 n = d.locker.nextSeriesId();
        for (uint256 s = 1; s < n; ++s) {
            if (d.locker.getSeries(s).openRepos != 0) continue;
            for (uint256 k; k < 2; ++k) {
                uint256 bal = d.note.balanceOf(lenders[k], s);
                if (bal == 0) continue;
                vm.prank(lenders[k]);
                d.locker.redeem(s, bal);
                calls["redeem"]++;
            }
        }
        _after();
    }

    // ------------------------------------------------------------------ keeper model

    function _after() internal {
        uint256 n = d.locker.nextRepoId();
        for (uint256 i = 1; i < n; ++i) {
            try d.engine.poke(i) {} catch {}
        }
    }

    function _trackNewOrders() internal {
        uint256 next = d.auctionHouse.nextOrderId();
        uint256 known = allOrders.length == 0 ? 0 : allOrders[allOrders.length - 1];
        for (uint256 id = known + 1; id < next; ++id) {
            allOrders.push(id);
        }
    }
}

/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 40
contract ProtocolInvariantTest is BaseTest {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(d, usdc, stock, feed, bookON, book7, [alice, carol, bob, dave], keeper);
        targetContract(address(handler));
    }

    /// @notice Every open repo (and therefore every outstanding repo note) is backed by collateral above the
    ///         maintenance margin, or is already in margin call / liquidation.
    function invariant_reposHealthyOrFlagged() public view {
        uint256 n = d.locker.nextRepoId();
        for (uint256 i = 1; i < n; ++i) {
            IRepoLocker.Repo memory r = d.locker.getRepo(i);
            if (r.status == IRepoLocker.RepoStatus.Active) {
                assertTrue(d.engine.isHealthy(i), "active repo below maintenance margin");
            }
        }
    }

    /// @notice Outstanding note principal of every series is covered by cash + principal of repos that are open or
    ///         in liquidation + written-off debt, i.e. losses are only ever realised through the liquidation path.
    function invariant_seriesBacking() public view {
        uint256 ns = d.locker.nextSeriesId();
        uint256 nr = d.locker.nextRepoId();
        for (uint256 s = 1; s < ns; ++s) {
            IRepoLocker.Series memory se = d.locker.getSeries(s);
            uint256 openPrincipal;
            for (uint256 i = 1; i < nr; ++i) {
                IRepoLocker.Repo memory r = d.locker.getRepo(i);
                if (
                    r.seriesId == s
                        && (r.status == IRepoLocker.RepoStatus.Active
                            || r.status == IRepoLocker.RepoStatus.MarginCall
                            || r.status == IRepoLocker.RepoStatus.Liquidating)
                ) {
                    openPrincipal += r.principal;
                }
            }
            uint256 outstanding = se.principal - se.redeemed;
            assertLe(outstanding, uint256(se.cash) + openPrincipal + se.badDebt + 1, "series under-backed");
            assertGe(se.principal, d.note.totalSupply(s), "notes exceed series principal");
        }
    }

    /// @notice Collateral and stablecoin custody always match the books.
    function invariant_custody() public view {
        assertEq(stock.balanceOf(address(d.locker)), d.locker.lockedCollateral(address(stock)), "locker collateral");
        assertGe(usdc.balanceOf(address(d.locker)), d.locker.totalStableLiabilities(), "locker stable");

        uint256 ahStable;
        uint256 ahColl;
        uint256 n = handler.orderCount();
        for (uint256 i; i < n; ++i) {
            AuctionHouse.Order memory o = d.auctionHouse.getOrder(handler.allOrders(i));
            if (o.state != AuctionHouse.State.Committed && o.state != AuctionHouse.State.Revealed) continue;
            if (o.isRepoRoll) continue;
            bool cleared = d.auctionHouse.getResult(o.bookId, o.epoch).cleared && o.state == AuctionHouse.State.Revealed;
            bool rolled = o.rolledInto != 0;
            if (o.side == AuctionHouse.Side.Lend) {
                ahStable += cleared ? (rolled ? 0 : o.amount - o.filled) : o.amount;
            } else {
                ahStable += cleared ? o.proceeds : 0;
                ahColl += cleared ? (rolled ? 0 : o.collateral - o.lockedCollateral) : o.collateral;
            }
        }
        assertGe(usdc.balanceOf(address(d.auctionHouse)), ahStable, "auction house stable");
        assertGe(stock.balanceOf(address(d.auctionHouse)), ahColl, "auction house collateral");
    }

    /// @notice The clearing rate satisfies every matched order's limit.
    function invariant_clearingRespectsLimits() public view {
        uint256 n = handler.orderCount();
        for (uint256 i; i < n; ++i) {
            AuctionHouse.Order memory o = d.auctionHouse.getOrder(handler.allOrders(i));
            if (o.filled == 0) continue;
            AuctionHouse.AuctionResult memory r = d.auctionHouse.getResult(o.bookId, o.epoch);
            assertTrue(r.cleared, "filled but not cleared");
            if (o.side == AuctionHouse.Side.Lend) assertLe(o.rateBps, r.clearingRateBps, "lender limit");
            else assertGe(o.rateBps, r.clearingRateBps, "borrower limit");
        }
    }

    /// @dev Depth check: logs how far each run got (repos opened, liquidations, redemptions).
    function afterInvariant() public view {
        console2.log("repos", d.locker.nextRepoId() - 1, "series", d.locker.nextSeriesId() - 1);
        console2.log("liq auctions", d.liquidator.nextAuctionId() - 1, "liqBuys", handler.calls("liqBuy"));
        console2.log("rolls", handler.calls("roll"), "redeems", handler.calls("redeem"));
    }
}
