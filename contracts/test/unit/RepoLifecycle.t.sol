// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {RepoLocker} from "../../src/core/RepoLocker.sol";
import {MarginEngine} from "../../src/core/MarginEngine.sol";
import {Liquidator} from "../../src/core/Liquidator.sol";
import {IRepoLocker} from "../../src/interfaces/IRepoLocker.sol";
import {IMarginEngine} from "../../src/interfaces/IMarginEngine.sol";
import {IOracleAdapter} from "../../src/interfaces/IOracleAdapter.sol";
import {ILiquidator} from "../../src/interfaces/ILiquidator.sol";
import {ProtocolAccess} from "../../src/access/ProtocolAccess.sol";
import {RepoMath} from "../../src/libraries/RepoMath.sol";

contract RepoLockerTest is BaseTest {
    uint256 internal repoId;
    uint256 internal seriesId;

    function setUp() public override {
        super.setUp();
        (repoId, seriesId,,) = openSimpleRepo(book7, 10_000e6, 100e18, 400, 600); // 5% for 7d
    }

    function test_debtAccrual() public {
        IRepoLocker.Repo memory r = repo(repoId);
        assertEq(d.locker.debtOf(repoId), 10_000e6);
        vm.warp(r.start + 7 days);
        uint256 full = 10_000e6 + RepoMath.interest(10_000e6, 500, 7 days);
        assertEq(d.locker.debtOf(repoId), full);
        vm.warp(r.start + 30 days); // capped at maturity
        assertEq(d.locker.debtOf(repoId), full);
        assertEq(d.locker.debtAt(repoId, r.start + 1 days), 10_000e6 + RepoMath.interest(10_000e6, 500, 1 days));
        assertEq(d.locker.debtOf(999), 0);
    }

    function test_fullRepayAtMaturity_redeemWithInterest() public {
        IRepoLocker.Repo memory r = repo(repoId);
        vm.warp(r.maturity);
        uint256 debt = d.locker.debtOf(repoId);
        uint256 s0 = stock.balanceOf(bob);
        vm.prank(bob);
        uint256 paid = d.locker.repay(repoId, type(uint256).max);
        assertEq(paid, debt);
        assertEq(stock.balanceOf(bob), s0 + 100e18);
        assertEq(uint8(repo(repoId).status), uint8(IRepoLocker.RepoStatus.Closed));

        uint256 a0 = usdc.balanceOf(alice);
        assertEq(d.locker.previewRedeem(seriesId, 10_000e6), debt);
        vm.prank(alice);
        d.locker.redeem(seriesId, 10_000e6);
        assertEq(usdc.balanceOf(alice), a0 + debt);
        assertEq(d.note.balanceOf(alice, seriesId), 0);
        assertEq(d.locker.totalStableLiabilities(), 0);
    }

    function test_earlyRepay_interestToDate() public {
        IRepoLocker.Repo memory r = repo(repoId);
        vm.warp(r.start + 2 days);
        uint256 debt = d.locker.debtOf(repoId);
        assertEq(debt, 10_000e6 + RepoMath.interest(10_000e6, 500, 2 days));
        vm.prank(bob);
        d.locker.repay(repoId, debt);
        IRepoLocker.Series memory s = d.locker.getSeries(seriesId);
        assertEq(s.cash, debt);
        assertEq(s.openRepos, 0);
    }

    function test_partialRepay_thenFull() public {
        IRepoLocker.Repo memory r = repo(repoId);
        vm.warp(r.start + 3 days);
        uint256 debt = d.locker.debtOf(repoId);
        vm.prank(bob);
        d.locker.repay(repoId, debt / 2);
        uint256 rem = d.locker.debtOf(repoId);
        assertApproxEqAbs(rem, debt - debt / 2, 2);
        assertGe(rem, debt - debt / 2);
        vm.prank(carol); // third-party repay allowed
        d.locker.repay(repoId, rem);
        assertEq(uint8(repo(repoId).status), uint8(IRepoLocker.RepoStatus.Closed));
    }

    function test_repayValidation() public {
        vm.prank(bob);
        vm.expectRevert(RepoLocker.ZeroAmount.selector);
        d.locker.repay(repoId, 0);
        vm.expectRevert(RepoLocker.BadStatus.selector);
        d.locker.repay(999, 1);
    }

    function test_redeemBeforeSettledReverts() public {
        vm.prank(alice);
        vm.expectRevert(RepoLocker.SeriesNotSettled.selector);
        d.locker.redeem(seriesId, 1);
        vm.expectRevert(RepoLocker.UnknownSeries.selector);
        d.locker.redeem(999, 1);
        vm.prank(bob);
        d.locker.repay(repoId, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(RepoLocker.ZeroAmount.selector);
        d.locker.redeem(seriesId, 0);
    }

    function test_redeemAfterTransfer_partial() public {
        vm.prank(alice);
        d.note.safeTransferFrom(alice, carol, seriesId, 4_000e6, "");
        vm.warp(repo(repoId).maturity);
        uint256 debt = d.locker.debtOf(repoId);
        vm.prank(bob);
        d.locker.repay(repoId, debt);
        vm.prank(carol);
        uint256 p1 = d.locker.redeem(seriesId, 4_000e6);
        vm.prank(alice);
        uint256 p2 = d.locker.redeem(seriesId, 6_000e6);
        assertEq(p1 + p2, debt);
        assertEq(d.locker.previewRedeem(seriesId, 1), 0);
    }

    function test_addCollateral_and_withdraw() public {
        vm.prank(carol);
        d.locker.addCollateral(repoId, 10e18);
        assertEq(repo(repoId).collateralAmount, 110e18);
        vm.expectRevert(RepoLocker.ZeroAmount.selector);
        d.locker.addCollateral(repoId, 0);

        vm.prank(carol);
        vm.expectRevert(RepoLocker.NotBorrower.selector);
        d.locker.withdrawCollateral(repoId, 1e18);
        // 10k debt at 80% of $200 needs 62.5 shares
        vm.prank(bob);
        vm.expectRevert(RepoLocker.InitialMarginBreached.selector);
        d.locker.withdrawCollateral(repoId, 50e18);
        vm.prank(bob);
        vm.expectRevert(RepoLocker.ZeroAmount.selector);
        d.locker.withdrawCollateral(repoId, 0);
        uint256 s0 = stock.balanceOf(bob);
        vm.prank(bob);
        d.locker.withdrawCollateral(repoId, 40e18);
        assertEq(stock.balanceOf(bob), s0 + 40e18);
        assertEq(d.locker.lockedCollateral(address(stock)), 70e18);
    }

    function test_setAutoRoll() public {
        vm.prank(carol);
        vm.expectRevert(RepoLocker.NotBorrower.selector);
        d.locker.setAutoRoll(repoId, true, 1_000);
        vm.prank(bob);
        vm.expectRevert(RepoLocker.RateTooHigh.selector);
        d.locker.setAutoRoll(repoId, true, 9_000);
        vm.prank(bob);
        d.locker.setAutoRoll(repoId, true, 1_000);
        assertTrue(repo(repoId).autoRoll);
        assertEq(d.locker.reposOf(bob).length, 1);
    }

    function test_hooksAccessControl() public {
        vm.startPrank(carol);
        vm.expectRevert();
        d.locker.createSeries(0, 0, 1, 1, 1);
        vm.expectRevert();
        d.locker.openRepo(1, carol, address(stock), 1, 1);
        vm.expectRevert();
        d.locker.setMarginCall(repoId, 1);
        vm.expectRevert();
        d.locker.seizeForLiquidation(repoId);
        vm.expectRevert();
        d.locker.creditLiquidation(repoId, 1);
        vm.expectRevert();
        d.locker.closeLiquidated(repoId, 0);
        vm.expectRevert();
        d.locker.setMarginEngine(IMarginEngine(address(1)));
        vm.stopPrank();
        vm.expectRevert(ProtocolAccess.ZeroAddress.selector);
        d.locker.setMarginEngine(IMarginEngine(address(0)));
    }

    function test_claimNothingReverts() public {
        vm.expectRevert(RepoLocker.ZeroAmount.selector);
        d.locker.claim(address(usdc));
    }

    function test_badStatusGuards() public {
        vm.prank(bob);
        d.locker.repay(repoId, type(uint256).max);
        vm.expectRevert(RepoLocker.BadStatus.selector);
        d.locker.addCollateral(repoId, 1);
        vm.prank(bob);
        vm.expectRevert(RepoLocker.BadStatus.selector);
        d.locker.withdrawCollateral(repoId, 1);
        vm.prank(bob);
        vm.expectRevert(RepoLocker.BadStatus.selector);
        d.locker.setAutoRoll(repoId, true, 1);
        vm.prank(address(d.engine));
        vm.expectRevert(RepoLocker.BadStatus.selector);
        d.locker.setMarginCall(repoId, 1);
        vm.prank(address(d.engine));
        vm.expectRevert(RepoLocker.BadStatus.selector);
        d.locker.clearMarginCall(repoId);
        vm.prank(address(d.liquidator));
        vm.expectRevert(RepoLocker.BadStatus.selector);
        d.locker.seizeForLiquidation(repoId);
        vm.prank(address(d.liquidator));
        vm.expectRevert(RepoLocker.BadStatus.selector);
        d.locker.creditLiquidation(repoId, 1);
        vm.prank(address(d.liquidator));
        vm.expectRevert(RepoLocker.BadStatus.selector);
        d.locker.closeLiquidated(repoId, 0);
        vm.prank(address(d.auctionHouse));
        vm.expectRevert(RepoLocker.BadStatus.selector);
        d.locker.executeRoll(repoId, seriesId, 1, 1, 0);
        vm.prank(address(d.auctionHouse));
        vm.expectRevert(RepoLocker.UnknownSeries.selector);
        d.locker.openRepo(999, bob, address(stock), 0, 1);
    }

    function test_withdrawWhileRollingReverts() public {
        vm.prank(address(d.auctionHouse));
        d.locker.setRolling(repoId, true);
        vm.prank(bob);
        vm.expectRevert(RepoLocker.RepoRolling.selector);
        d.locker.withdrawCollateral(repoId, 1e18);
    }
}

contract MarginAndLiquidationTest is BaseTest {
    uint256 internal repoId;
    uint256 internal seriesId;

    function setUp() public override {
        super.setUp();
        // 10k borrowed against 100 shares @ $200 = $20k
        (repoId, seriesId,,) = openSimpleRepo(book30, 10_000e6, 100e18, 400, 600);
    }

    function test_views() public view {
        (uint256 debt, uint256 value, uint256 maint, uint256 crit) = d.engine.health(repoId);
        assertEq(debt, 10_000e6);
        assertEq(value, 20_000e6);
        assertEq(maint, 17_600e6);
        assertEq(crit, 19_000e6);
        assertTrue(d.engine.isHealthy(repoId));
        assertEq(d.engine.collateralValue(address(stock), 0), 0);
        assertTrue(d.engine.meetsInitialMargin(address(stock), 100e18, 16_000e6));
        assertFalse(d.engine.meetsInitialMargin(address(stock), 100e18, 16_000e6 + 1));
    }

    function test_healthyPokeNoop() public {
        assertEq(uint8(d.engine.poke(repoId)), uint8(MarginEngine.Action.None));
        assertEq(uint8(d.engine.poke(999)), uint8(MarginEngine.Action.None));
    }

    function test_marginCall_cureByTopUp() public {
        setPrice(110e8); // value 11k, maint limit 9.68k < 10k
        assertEq(uint8(d.engine.poke(repoId)), uint8(MarginEngine.Action.MarginCalled));
        IRepoLocker.Repo memory r = repo(repoId);
        assertEq(uint8(r.status), uint8(IRepoLocker.RepoStatus.MarginCall));
        assertEq(r.marginCallDeadline, block.timestamp + 4 hours);
        // poking again inside the grace period does nothing
        assertEq(uint8(d.engine.poke(repoId)), uint8(MarginEngine.Action.None));
        vm.prank(bob);
        d.locker.addCollateral(repoId, 20e18);
        assertEq(uint8(repo(repoId).status), uint8(IRepoLocker.RepoStatus.Active));
    }

    function test_marginCall_cureByPriceRecovery() public {
        setPrice(110e8);
        d.engine.poke(repoId);
        setPrice(200e8);
        assertEq(uint8(d.engine.poke(repoId)), uint8(MarginEngine.Action.Cured));
    }

    function test_marginCall_cureByPartialRepay() public {
        setPrice(110e8);
        d.engine.poke(repoId);
        vm.prank(bob);
        d.locker.repay(repoId, 2_000e6);
        assertEq(uint8(repo(repoId).status), uint8(IRepoLocker.RepoStatus.Active));
    }

    function test_cureAttempt_survivesOracleOutage() public {
        setPrice(110e8);
        d.engine.poke(repoId);
        vm.warp(block.timestamp + 2 days); // feed stale
        vm.prank(bob);
        d.locker.addCollateral(repoId, 50e18); // does not revert, stays in call until a fresh poke
        assertEq(uint8(repo(repoId).status), uint8(IRepoLocker.RepoStatus.MarginCall));
    }

    function test_liquidationAfterGrace_fullRecovery_surplusToBorrower() public {
        setPrice(110e8);
        d.engine.poke(repoId);
        vm.warp(block.timestamp + 4 hours);
        refreshFeeds();
        uint256 debt = d.locker.debtOf(repoId);
        assertEq(uint8(d.engine.poke(repoId)), uint8(MarginEngine.Action.Liquidated));
        assertEq(uint8(repo(repoId).status), uint8(IRepoLocker.RepoStatus.Liquidating));
        uint256 aId = d.liquidator.auctionOfRepo(repoId);
        Liquidator.Auction memory a = d.liquidator.getAuction(aId);
        assertEq(a.collateralLeft, 100e18);
        assertEq(a.debtLeft, debt);
        assertEq(a.penaltyLeft, debt * 500 / 10_000);
        assertEq(a.startPrice, 115.5e18);
        assertEq(a.floorPrice, 93.5e18);
        assertEq(d.liquidator.currentPrice(aId), 115.5e18);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 hours);
        assertEq(d.liquidator.currentPrice(aId), 104.5e18); // linear decay
        vm.warp(t0);
        uint256 price = d.liquidator.currentPrice(aId);

        uint256 fc0 = usdc.balanceOf(address(d.feeCollector));
        vm.prank(carol);
        (uint256 take, uint256 cost) = d.liquidator.buy(aId, type(uint256).max, price, block.timestamp);
        assertEq(cost, debt + debt * 500 / 10_000);
        assertLt(take, 100e18);
        assertEq(stock.balanceOf(carol), 1_000_000e18 + take);
        assertEq(usdc.balanceOf(address(d.feeCollector)) - fc0, debt * 500 / 10_000);
        assertEq(uint8(repo(repoId).status), uint8(IRepoLocker.RepoStatus.Closed));
        assertEq(d.liquidator.claimable(bob, address(stock)), 100e18 - take);
        uint256 s0 = stock.balanceOf(bob);
        vm.prank(bob);
        d.liquidator.claim(address(stock));
        assertEq(stock.balanceOf(bob), s0 + 100e18 - take);

        // lenders are made whole (principal + interest to liquidation)
        IRepoLocker.Series memory s = d.locker.getSeries(seriesId);
        assertEq(s.cash, debt);
        assertEq(s.badDebt, 0);
        assertEq(s.openRepos, 0);
    }

    function test_gap_immediateLiquidation_withBadDebt() public {
        setPrice(80e8); // value 8k < 10k debt: critical gap
        assertEq(uint8(d.engine.poke(repoId)), uint8(MarginEngine.Action.Liquidated));
        uint256 aId = d.liquidator.auctionOfRepo(repoId);
        vm.warp(block.timestamp + 3 hours); // floor price
        refreshFeeds();
        uint256 price = d.liquidator.currentPrice(aId);
        assertEq(price, 68e18);
        vm.prank(carol);
        (uint256 take, uint256 cost) = d.liquidator.buy(aId, type(uint256).max, price, block.timestamp);
        assertEq(take, 100e18);
        assertEq(cost, 6_800e6);
        IRepoLocker.Series memory s = d.locker.getSeries(seriesId);
        assertEq(s.cash, 6_800e6);
        assertEq(s.badDebt, 10_000e6 - 6_800e6);
        assertEq(s.openRepos, 0);
        // lenders redeem the recovered amount pro-rata
        vm.prank(alice);
        assertEq(d.locker.redeem(seriesId, 10_000e6), 6_800e6);
    }

    function test_partialBuys_slippageDeadline_restart() public {
        setPrice(80e8);
        d.engine.poke(repoId);
        uint256 aId = d.liquidator.auctionOfRepo(repoId);
        uint256 p = d.liquidator.currentPrice(aId);
        vm.startPrank(carol);
        vm.expectRevert(Liquidator.Expired.selector);
        d.liquidator.buy(aId, 1e18, p, block.timestamp - 1);
        vm.expectRevert(abi.encodeWithSelector(Liquidator.PriceAboveMax.selector, p));
        d.liquidator.buy(aId, 1e18, p - 1, block.timestamp);
        vm.expectRevert(Liquidator.NothingToBuy.selector);
        d.liquidator.buy(aId, 0, p, block.timestamp);
        d.liquidator.buy(aId, 10e18, p, block.timestamp);
        vm.expectRevert(Liquidator.NotExpired.selector);
        d.liquidator.restart(aId);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 hours);
        setPrice(90e8);
        d.liquidator.restart(aId);
        assertEq(d.liquidator.currentPrice(aId), 94.5e18);
        vm.prank(carol);
        d.liquidator.buy(aId, type(uint256).max, type(uint256).max, block.timestamp);
        assertFalse(d.liquidator.getAuction(aId).active);
        vm.expectRevert(Liquidator.NotActive.selector);
        d.liquidator.restart(aId);
        vm.expectRevert(Liquidator.NotActive.selector);
        d.liquidator.buy(aId, 1, type(uint256).max, block.timestamp);
        vm.expectRevert(Liquidator.NothingToBuy.selector);
        d.liquidator.claim(address(stock));
    }

    function test_overdueLiquidation() public {
        IRepoLocker.Repo memory r = repo(repoId);
        vm.warp(r.maturity + 4 hours);
        refreshFeeds();
        assertEq(uint8(d.engine.poke(repoId)), uint8(MarginEngine.Action.None));
        vm.warp(r.maturity + 4 hours + 1);
        refreshFeeds();
        assertEq(uint8(d.engine.poke(repoId)), uint8(MarginEngine.Action.Liquidated));
    }

    function test_marketHoursGateLiquidations() public {
        d.clock.setMarketHours(13 hours + 30 minutes, 20 hours, 0x1F, true);
        // find a Saturday 12:00 UTC after now
        uint256 t = block.timestamp;
        while (((t / 1 days) + 3) % 7 != 5) t += 1 days;
        t = (t / 1 days) * 1 days + 12 hours;
        vm.warp(t);
        refreshFeeds();
        assertFalse(d.clock.isEquityMarketOpen());
        setPrice(80e8); // critical, but market closed -> margin call only
        assertEq(uint8(d.engine.poke(repoId)), uint8(MarginEngine.Action.MarginCalled));
        vm.warp(t + 1 days); // Sunday, grace over, still closed
        refreshFeeds();
        assertEq(uint8(d.engine.poke(repoId)), uint8(MarginEngine.Action.None));
        vm.warp(t + 2 days + 2 hours); // Monday 14:00 UTC open
        refreshFeeds();
        assertTrue(d.clock.isEquityMarketOpen());
        assertEq(uint8(d.engine.poke(repoId)), uint8(MarginEngine.Action.Liquidated));
    }

    function test_pokeBatch_isolatesFailures() public {
        setPrice(110e8);
        uint256[] memory ids = new uint256[](3);
        ids[0] = repoId;
        ids[1] = 12345;
        ids[2] = repoId;
        MarginEngine.Action[] memory out = d.engine.pokeBatch(ids);
        assertEq(uint8(out[0]), uint8(MarginEngine.Action.MarginCalled));
        assertEq(uint8(out[1]), uint8(MarginEngine.Action.None));
        uint256[] memory big = new uint256[](101);
        vm.expectRevert(MarginEngine.BatchTooLarge.selector);
        d.engine.pokeBatch(big);
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.engine.pokeExternalSelf(repoId);
    }

    function test_engineAdmin() public {
        vm.expectRevert(ProtocolAccess.ZeroAddress.selector);
        d.engine.setOracle(IOracleAdapter(address(0)));
        vm.expectRevert(ProtocolAccess.ZeroAddress.selector);
        d.engine.setLiquidator(ILiquidator(address(0)));
        d.engine.setOracle(IOracleAdapter(address(d.oracle)));
        d.engine.setLiquidator(ILiquidator(address(d.liquidator)));
        vm.prank(guardian);
        d.engine.pause();
        vm.expectRevert();
        d.engine.poke(repoId);
    }

    function test_liquidatorAdmin() public {
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.liquidator.setParams(1, 0, 0);
        d.liquidator.setParams(1 hours, 100, 1_000);
        assertEq(d.liquidator.duration(), 1 hours);
        vm.expectRevert(ProtocolAccess.ZeroAddress.selector);
        d.liquidator.setOracle(IOracleAdapter(address(0)));
        vm.expectRevert(ProtocolAccess.ZeroAddress.selector);
        d.liquidator.setFeeCollector(address(0));
        d.liquidator.setOracle(IOracleAdapter(address(d.oracle)));
        d.liquidator.setFeeCollector(treasury);
        vm.expectRevert();
        d.liquidator.start(repoId);
    }

    function test_startWithZeroCollateral_settlesImmediately() public {
        // drain collateral via the locker's withdraw path is impossible; simulate a zero-collateral repo through a
        // fresh repo that is fully covered, then seized: use direct role calls
        vm.prank(address(d.auctionHouse));
        uint256 sid = d.locker.createSeries(book30, 0, 500, uint64(block.timestamp + 30 days), 1_000e6);
        vm.prank(address(d.auctionHouse));
        uint256 rid = d.locker.openRepo(sid, bob, address(stock), 0, 1_000e6);
        vm.prank(address(d.engine));
        uint256 aId = d.liquidator.start(rid);
        assertFalse(d.liquidator.getAuction(aId).active);
        assertEq(d.locker.getSeries(sid).badDebt, 1_000e6);
    }
}
